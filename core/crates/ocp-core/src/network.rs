//! Core-owned executors and connection pools; no process-global runtime survives
//! the C ABI handle or keeps executing code after the host unloads the library.

use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ocp_http::HttpClient;
use serde_json::{json, Value};

use crate::CommandError;

const MAX_MOVIEPILOT_SESSIONS: usize = 16;

#[derive(Clone)]
pub(crate) struct MoviePilotPool {
    pub(crate) http: HttpClient,
    pub(crate) stream: HttpClient,
}

impl MoviePilotPool {
    fn new() -> Result<Self, CommandError> {
        let jar = Arc::new(reqwest::cookie::Jar::default());
        let build = |idle, total| {
            reqwest::Client::builder()
                .cookie_provider(jar.clone())
                .pool_max_idle_per_host(2)
                .connect_timeout(Duration::from_secs(idle))
                .read_timeout(Duration::from_secs(idle))
                .timeout(Duration::from_secs(total))
                .build()
                .map(HttpClient::with_transport)
                .map_err(|error| CommandError(1500, false, error.without_url().to_string()))
        };
        Ok(Self {
            http: build(15, 30)?,
            stream: build(30, 300)?,
        })
    }
}

#[derive(Default)]
pub(crate) struct MoviePilotSessions {
    generation: u64,
    // Never serialize credentials, cookie contents or the cache keys.
    entries: VecDeque<(String, Option<String>, MoviePilotPool)>,
}

impl MoviePilotSessions {
    fn get(
        &mut self,
        base: &str,
        token: Option<&str>,
        login: bool,
    ) -> Result<(MoviePilotPool, u64), CommandError> {
        if !login {
            if let Some(index) = self
                .entries
                .iter()
                .position(|(url, key, _)| url == base && key.as_deref() == token)
            {
                let entry = self.entries.remove(index).expect("located session");
                let pool = entry.2.clone();
                self.entries.push_back(entry);
                return Ok((pool, self.generation));
            }
        }
        let pool = MoviePilotPool::new()?;
        // Each login starts with a clean jar. Publishing it under an anonymous
        // key would let unauthenticated commands inherit the logged-in cookie.
        if !login {
            self.insert(base.into(), token.map(str::to_owned), pool.clone());
        }
        Ok((pool, self.generation))
    }

    fn insert(&mut self, base: String, token: Option<String>, pool: MoviePilotPool) {
        self.entries
            .retain(|(url, key, _)| *url != base || *key != token);
        while self.entries.len() >= MAX_MOVIEPILOT_SESSIONS {
            self.entries.pop_front();
        }
        self.entries.push_back((base, token, pool));
    }

    pub(crate) fn publish_login(
        &mut self,
        generation: u64,
        base: String,
        token: String,
        pool: MoviePilotPool,
    ) {
        if generation == self.generation {
            self.insert(base, Some(token), pool);
        }
    }

    pub(crate) fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.entries.clear();
    }
}

pub(crate) struct NetworkService {
    runtime: Option<tokio::runtime::Runtime>,
    pub(crate) client: reqwest::Client,
    pub(crate) moviepilot: Arc<Mutex<MoviePilotSessions>>,
}

impl NetworkService {
    pub(crate) fn new() -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .pool_max_idle_per_host(2)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|error| error.without_url().to_string())?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(8)
            .thread_name("ocp-network")
            .enable_all()
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            runtime: Some(runtime),
            client,
            moviepilot: Default::default(),
        })
    }

    pub(crate) fn http(&self) -> HttpClient {
        HttpClient::with_transport(self.client.clone())
    }

    pub(crate) fn moviepilot_pool(
        &self,
        base: &str,
        token: Option<&str>,
        login: bool,
    ) -> Result<(MoviePilotPool, u64), CommandError> {
        self.moviepilot
            .lock()
            .map_err(|_| CommandError(1500, false, "session pool unavailable".into()))?
            .get(base, token, login)
    }

    pub(crate) fn run<T: Send + 'static>(
        &self,
        operation: impl Future<Output = Result<T, CommandError>> + Send + 'static,
    ) -> Result<T, CommandError> {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        // The future must not capture this service: its last owner could then
        // shut down and join the runtime from one of that runtime's own workers.
        self.runtime
            .as_ref()
            .expect("live network executor")
            .spawn(async move {
                let _ = sender.send(operation.await);
            });
        receiver
            .recv()
            .map_err(|_| CommandError(1500, false, "network command worker panicked".into()))?
    }

    pub(crate) fn diagnostics(&self) -> Value {
        json!({"executorThreads": 2, "moviepilotSessionLimit": MAX_MOVIEPILOT_SESSIONS,
               "moviepilotSessions": self.moviepilot.lock().map(|cache| cache.entries.len()).unwrap_or(0)})
    }
}

impl Drop for NetworkService {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            // Joined shutdown permits destruction from an async host and is
            // complete before OcpNativeAPI releases the dynamic library.
            let _ = std::thread::spawn(move || drop(runtime)).join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn owned_executor_runs_and_destroys_inside_async_host() {
        let service = NetworkService::new().unwrap();
        assert_eq!(service.run(async { Ok(7) }).unwrap_or_default(), 7);
        drop(service);
    }

    #[test]
    fn retired_login_cannot_repopulate_cookie_cache() {
        let service = NetworkService::new().unwrap();
        let (pool, generation) = service
            .moviepilot_pool("http://example.test/", None, true)
            .unwrap_or_else(|_| panic!("valid pool"));
        let mut cache = service.moviepilot.lock().unwrap();
        cache.clear();
        cache.publish_login(
            generation,
            "http://example.test/".into(),
            "secret".into(),
            pool,
        );
        assert!(cache.entries.is_empty());
    }
}
