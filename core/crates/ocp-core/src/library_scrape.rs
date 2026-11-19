//! One durable queue worker per category. No playback lock or transaction is
//! held across a network request; dropping the runtime cancels requests first.
use ocp_library::{
    scrape::{ScrapeRun, Target},
    ItemKind, Store,
};
use ocp_tmdb::{matcher, MediaType, TmdbClient, TmdbError};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicU8, Ordering},
    Arc, Mutex,
};

#[derive(Default)]
pub(crate) struct Epoch {
    pub generation: u64,
    pub valid: bool,
}
pub(crate) type Gate = Arc<Mutex<Epoch>>;

#[derive(Clone)]
pub(crate) struct Credentials {
    pub key: String,
    pub api_base: String,
    pub language: String,
    pub generation: u64,
}

pub(crate) fn valid(gate: &Gate, generation: u64) -> bool {
    gate.lock()
        .is_ok_and(|e| e.valid && e.generation == generation)
}

pub(crate) fn candidates(
    item: &ocp_library::Item,
    results: Vec<ocp_tmdb::TmdbSearchResult>,
) -> Vec<matcher::Candidate> {
    let media_type = if item.kind == ItemKind::Movie {
        "movie"
    } else {
        "tv"
    };
    results
        .into_iter()
        .filter(|r| r.id > 0)
        .map(|r| matcher::Candidate {
            id: r.id,
            media_type: media_type.into(),
            title: r.title.or(r.name),
            original_title: r.original_title.or(r.original_name),
            year: r
                .release_date
                .or(r.first_air_date)
                .and_then(|date| date.get(..4)?.parse().ok()),
            overview: r.overview,
            poster_path: r.poster_path,
            popularity: r.popularity,
            extra: Default::default(),
        })
        .collect()
}

pub(crate) fn matcher_item(item: &ocp_library::Item) -> matcher::Item {
    matcher::Item {
        name: item.title.clone(),
        kind: if item.kind == ItemKind::Movie {
            "movie"
        } else {
            "series"
        }
        .into(),
        year: item.year,
        original_title: None,
        tmdb_id: None,
        season_number: None,
        series_name: None,
    }
}

pub(crate) async fn download(
    client: &TmdbClient,
    target: &Target,
    language: &str,
) -> Result<Option<Value>, TmdbError> {
    if target.item.kind == ItemKind::Season {
        let id = target
            .tmdb_id
            .ok_or_else(|| TmdbError::Response("series is not matched".into()))?;
        return Ok(Some(serde_json::to_value(
            client
                .season_checked(id, target.item.season_number.unwrap_or(0), language)
                .await?,
        )?));
    }
    let typ = if target.item.kind == ItemKind::Movie {
        MediaType::Movie
    } else {
        MediaType::Tv
    };
    let id = if let Some(id) = target.tmdb_id {
        id
    } else {
        let results = client
            .search_checked(&target.item.title, typ, target.item.year, language)
            .await?;
        let item = matcher_item(&target.item);
        let candidates = candidates(&target.item, results);
        let Some(ranked) = matcher::rank(&item, &candidates) else {
            return Ok(None);
        };
        // A tie/near tie remains a manual choice even above the old threshold.
        if !ranked.should_apply_automatically
            || ranked
                .alternatives
                .iter()
                .filter(|second| {
                    format!("{}/{}", second.media_type, second.id) != ranked.entity_key
                })
                .any(|second| ranked.confidence - matcher::score(second, &item) < 0.1)
        {
            return Ok(None);
        }
        ranked
            .entity_key
            .split('/')
            .nth(1)
            .and_then(|id| id.parse::<i64>().ok())
            .ok_or_else(|| TmdbError::Response("matcher returned no entity".into()))?
    };
    let entity = client.entity_checked(id, typ, language).await?;
    if entity.id != id || entity.media_type != typ {
        return Err(TmdbError::Response("TMDB entity identity mismatch".into()));
    }
    Ok(Some(serde_json::to_value(entity)?))
}

/// Error text is deliberately classified: transport URLs may contain a v3 key.
pub(crate) fn failure(
    error: &TmdbError,
    attempt: i64,
) -> (&'static str, &'static str, Option<f64>) {
    match error {
        TmdbError::NotConfigured => ("credentials", "请配置并验证 TMDB 凭据", None),
        TmdbError::Http(ocp_http::HttpError::Request {
            status: Some(401 | 403),
            ..
        }) => ("credentials", "TMDB 凭据被拒绝，请重新配置并验证", None),
        TmdbError::Http(http)
            if http.retryable()
                || matches!(
                    http,
                    ocp_http::HttpError::Request {
                        status: Some(429 | 500..=599),
                        ..
                    }
                )
                || matches!(
                    http.category(),
                    Some(ocp_http::ErrorCategory::Timeout | ocp_http::ErrorCategory::Transport)
                ) =>
        {
            let delay = http
                .retry_after()
                .map(|d| d.as_secs_f64())
                .unwrap_or((2.0_f64.powi(attempt.min(6) as i32)).min(60.0));
            (
                "network",
                if attempt < 3 {
                    "TMDB 网络请求失败或被限流，将按计划重试"
                } else {
                    "TMDB 网络重试仍未成功，请稍后重试"
                },
                (attempt < 3).then(|| ocp_library::now() + delay),
            )
        }
        TmdbError::Http(_) => ("http", "TMDB 请求失败，可稍后重试或手动匹配", None),
        _ => ("response", "TMDB 返回了无法使用的元数据", None),
    }
}

pub(crate) fn run(
    store: Store,
    run: ScrapeRun,
    credentials: Credentials,
    gate: Gate,
    control: Arc<AtomicU8>,
) -> Result<(), ocp_library::Error> {
    let executor = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    executor.block_on(async {
        let client = TmdbClient::with_endpoint(&credentials.key,&credentials.api_base);
        store.set_scrape_status(&run.run_id,"running")?;
        loop {
            if control.load(Ordering::Acquire)!=ocp_library::scan::RUN || !valid(&gate,credentials.generation) {
                let status = if control.load(Ordering::Acquire)==ocp_library::scan::CANCEL {"cancelled"} else if !valid(&gate,credentials.generation) {"waitingCredentials"} else {"paused"};
                store.set_scrape_status(&run.run_id,status)?;
                return Ok(());
            }
            // Initial metadata work starts after enumeration finishes, so all
            // local seasons are known and a paused scan remains resumable.
            if store.scan_in_progress(&run)? {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                continue;
            }
            store.seed_scrape(&run)?;
            let Some(target) = store.claim_scrape(&run)? else {
                let summary = store.scrape_run(&run.source_id,&run.run_id)?;
                if summary.next_retry_at.is_some() {
                    store.set_scrape_status(&run.run_id,"waitingNetwork")?;
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
                store.set_scrape_status(&run.run_id,if summary.failed>0 {"partialFailure"} else if summary.unmatched>0 {"needsMatch"} else {"completed"})?;
                return Ok(());
            };
            store.set_scrape_status(&run.run_id,"running")?;
            if target.cached {
                store.finish_target_checked(&run,&target,"completed",None,None,None)?;
                continue;
            }
            let request = download(&client,&target,&run.language);
            tokio::pin!(request);
            let outcome = loop {
                tokio::select! {
                    value = &mut request => break Some(value),
                    _ = tokio::time::sleep(std::time::Duration::from_millis(50)) => {
                        if control.load(Ordering::Acquire)!=ocp_library::scan::RUN || !valid(&gate,credentials.generation) { break None; }
                    }
                }
            };
            // Final writes are serialized with synchronous credential changes.
            let mut epoch = gate.lock().map_err(|_|ocp_library::Error::Invalid("TMDB credential service unavailable".into()))?;
            if outcome.is_none() || !epoch.valid || epoch.generation!=credentials.generation || control.load(Ordering::Acquire)!=ocp_library::scan::RUN {
                store.finish_target(&run,&target,"queued",None,None,None)?;
                continue;
            }
            match outcome.unwrap() {
                Ok(Some(payload)) => { store.commit_scrape(&run,&target,&payload)?; }
                Ok(None) => store.finish_target_checked(&run,&target,"unmatched",Some("match"),Some("候选置信度不足或存在歧义，请手动匹配"),None)?,
                Err(error) => {
                    let (kind,message,retry) = failure(&error,target.attempts);
                    store.finish_target_checked(&run,&target,if kind=="credentials" {"queued"} else if retry.is_some() {"retryScheduled"} else {"failed"},Some(kind),Some(message),retry)?;
                    if kind=="credentials" { epoch.valid=false; }
                }
            }
        }
    })
}
