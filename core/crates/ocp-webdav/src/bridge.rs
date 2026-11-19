//! One capability URL per playback lease, bound to 127.0.0.1. Streaming and
//! backpressure keep video size independent of memory use. All upstream requests
//! are bounded single ranges; a bridge never relays caller headers or redirects.
use crate::{Error, Provider};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::JoinHandle,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinSet,
};

const WINDOW: u64 = 4 * 1024 * 1024;

pub struct Lease {
    pub id: String,
    pub uri: String,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Lease {
    pub fn start(provider: Provider, relative: String, size: u64) -> Result<Self, Error> {
        let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .map_err(|_| Error::Bridge)?;
        listener.set_nonblocking(true).map_err(|_| Error::Bridge)?;
        let address = listener.local_addr().map_err(|_| Error::Bridge)?;
        let id = uuid::Uuid::new_v4().to_string();
        let path = format!("/{}/media", uuid::Uuid::new_v4());
        let uri = format!("http://{address}{path}");
        let stop = Arc::new(AtomicBool::new(false));
        let control = stop.clone();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| Error::Bridge)?;
        let handle = std::thread::Builder::new().name("ocp-dav-resource".into()).spawn(move || {
            runtime.block_on(async move {
                let Ok(listener) = TcpListener::from_std(listener) else { return; };
                let mut tasks = JoinSet::new();
                loop {
                    if control.load(Ordering::Acquire) { break; }
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_millis(20)) => {},
                        _ = tasks.join_next(), if !tasks.is_empty() => {},
                        accepted = listener.accept() => {
                            let Ok((socket, _)) = accepted else { break; };
                            if tasks.len() >= 8 { drop(socket); continue; }
                            let (provider, relative, path) = (provider.clone(), relative.clone(), path.clone());
                            tasks.spawn(async move { let _ = serve(socket, provider, relative, size, path, address.to_string()).await; });
                        }
                    }
                }
                tasks.abort_all();
                while tasks.join_next().await.is_some() {}
            });
        }).map_err(|_| Error::Bridge)?;
        Ok(Self {
            id,
            uri,
            stop,
            handle: Some(handle),
        })
    }
}

async fn send(socket: &mut TcpStream, bytes: &[u8]) -> Result<(), Error> {
    tokio::time::timeout(Duration::from_secs(30), socket.write_all(bytes))
        .await
        .map_err(|_| Error::Bridge)?
        .map_err(|_| Error::Bridge)
}
async fn reject(socket: &mut TcpStream, status: &str) -> Result<(), Error> {
    send(
        socket,
        format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes(),
    )
    .await
}
fn interval(value: Option<&str>, size: u64) -> Result<(u64, u64), Error> {
    if size == 0 {
        return Err(Error::Range);
    }
    let Some(value) = value else {
        return Ok((0, size - 1));
    };
    let (start, end) = value
        .strip_prefix("bytes=")
        .and_then(|s| s.split_once('-'))
        .ok_or(Error::Range)?;
    if start.is_empty() {
        let suffix = end.parse::<u64>().map_err(|_| Error::Range)?;
        if suffix == 0 {
            return Err(Error::Range);
        }
        return Ok((size.saturating_sub(suffix), size - 1));
    }
    let start = start.parse::<u64>().map_err(|_| Error::Range)?;
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().map_err(|_| Error::Range)?.min(size - 1)
    };
    if start > end || start >= size {
        return Err(Error::Range);
    }
    Ok((start, end))
}

async fn serve(
    mut socket: TcpStream,
    provider: Provider,
    relative: String,
    size: u64,
    path: String,
    host: String,
) -> Result<(), Error> {
    let mut header = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !header.ends_with(b"\r\n\r\n") {
            if header.len() >= 8192 {
                return Err(Error::Bridge);
            }
            header.push(socket.read_u8().await.map_err(|_| Error::Bridge)?);
        }
        Ok(())
    })
    .await
    .map_err(|_| Error::Bridge)??;
    let Ok(header) = std::str::from_utf8(&header) else {
        return reject(&mut socket, "400 Bad Request").await;
    };
    let mut lines = header.split("\r\n");
    let parts: Vec<_> = lines.next().unwrap_or("").split_whitespace().collect();
    if parts.len() != 3
        || parts[1] != path
        || !matches!(parts[0], "HEAD" | "GET")
        || !matches!(parts[2], "HTTP/1.0" | "HTTP/1.1")
    {
        return reject(&mut socket, "404 Not Found").await;
    }
    let mut request_headers = std::collections::HashMap::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let Some((name, value)) = line.split_once(':') else {
            return reject(&mut socket, "400 Bad Request").await;
        };
        if request_headers
            .insert(name.to_ascii_lowercase(), value.trim())
            .is_some()
        {
            return reject(&mut socket, "400 Bad Request").await;
        }
    }
    if request_headers.get("host").copied() != Some(host.as_str())
        || request_headers.contains_key("origin")
        || request_headers.contains_key("transfer-encoding")
        || request_headers
            .get("content-length")
            .is_some_and(|v| *v != "0")
    {
        return reject(&mut socket, "403 Forbidden").await;
    }
    let range = request_headers.get("range").copied();
    let Ok((start, end)) = interval(range, size) else {
        return send(&mut socket, format!("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await;
    };
    let head = parts[0] == "HEAD";
    // Validate the first upstream response before announcing success locally.
    let mut response = if head {
        None
    } else {
        match provider
            .range(&relative, start, end.min(start + WINDOW - 1), Some(size))
            .await
        {
            Ok(response) => Some(response),
            Err(_) => return reject(&mut socket, "502 Bad Gateway").await,
        }
    };
    let content_range = if range.is_some() {
        format!("Content-Range: bytes {start}-{end}/{size}\r\n")
    } else {
        String::new()
    };
    let status = if range.is_some() {
        "206 Partial Content"
    } else {
        "200 OK"
    };
    send(&mut socket, format!("HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\n{content_range}Cache-Control: no-store\r\nConnection: close\r\n\r\n", end-start+1).as_bytes()).await?;
    if head {
        return Ok(());
    }
    let mut cursor = start;
    loop {
        let window_end = end.min(cursor + WINDOW - 1);
        let mut upstream = match response.take() {
            Some(response) => response,
            None => {
                provider
                    .range(&relative, cursor, window_end, Some(size))
                    .await?
            }
        };
        let mut received = 0;
        while let Some(chunk) = upstream.chunk().await.map_err(|_| Error::Network)? {
            received += chunk.len() as u64;
            if received > window_end - cursor + 1 {
                return Err(Error::Range);
            }
            send(&mut socket, &chunk).await?;
        }
        if received != window_end - cursor + 1 {
            return Err(Error::Range);
        }
        if window_end == end {
            break;
        }
        cursor = window_end + 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn range_forms_and_overflow() {
        assert_eq!(interval(Some("bytes=10-"), 100).unwrap(), (10, 99));
        assert_eq!(interval(Some("bytes=-10"), 100).unwrap(), (90, 99));
        assert_eq!(interval(Some("bytes=0-1000"), 100).unwrap(), (0, 99));
        for value in [
            "bytes=100-",
            "bytes=-0",
            "bytes=2-1",
            "bytes=0-1,4-5",
            "bytes=18446744073709551616-",
        ] {
            assert!(interval(Some(value), 100).is_err());
        }
    }
}
