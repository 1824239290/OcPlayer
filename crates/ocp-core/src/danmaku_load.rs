//! Executes the shared state machine for a data consumer, using the same caches
//! and provider policies as the native player without renderer-side effects.
use super::{CommandError, State};
use ocp_danmaku::{
    cache::{EpisodeMatch, IntroHint, IntroSource},
    identity, intro, load_wire, providers, render, DanmakuComment, DanmakuGateway, GatewayConfig,
    MatchRequest,
};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};

fn invalid(message: impl Into<String>) -> CommandError {
    CommandError::invalid(message)
}
fn unpack(value: Value) -> Result<Value, CommandError> {
    serde_json::from_str(
        value["payloadJSON"]
            .as_str()
            .ok_or_else(|| invalid("missing payloadJSON"))?,
    )
    .map_err(|e| invalid(e.to_string()))
}
fn read_payload(value: Option<&Value>) -> Result<Value, CommandError> {
    match value {
        None => Ok(json!({})),
        Some(Value::String(value)) => {
            serde_json::from_str(value).map_err(|e| invalid(e.to_string()))
        }
        Some(value) => Ok(value.clone()),
    }
}
struct Session {
    state: Arc<Mutex<State>>,
    id: String,
    key: Option<String>,
    revision: Option<u64>,
    cancelled: Option<Arc<AtomicBool>>,
    registered: bool,
}
impl Drop for Session {
    fn drop(&mut self) {
        if self.registered {
            if let Ok(mut state) = self.state.lock() {
                let _ = state.danmaku_flow.call("close", &json!({"flowID":self.id}));
            }
        }
    }
}
impl Session {
    fn check(&self) -> Result<(), CommandError> {
        if self
            .cancelled
            .as_ref()
            .is_some_and(|v| v.load(Ordering::Acquire))
        {
            Err(CommandError(1003, false, "request cancelled".into()))
        } else {
            Ok(())
        }
    }
    fn locked<R>(
        &self,
        operation: impl FnOnce(&mut State) -> Result<R, CommandError>,
    ) -> Result<R, CommandError> {
        self.check()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| invalid("state unavailable"))?;
        self.check()?;
        operation(&mut state)
    }
    fn cache(&self, method: &str, mut args: Value) -> Result<Value, CommandError> {
        if let Some(key) = &self.key {
            args["mediaID"] = json!(key);
        }
        if let Some(revision) = self.revision {
            args["revision"] = json!(revision);
        }
        self.locked(|state| {
            let Some(cache) = state.danmaku_cache.as_mut() else {
                return Ok(Value::Null);
            };
            unpack(
                cache
                    .call(method, &args)
                    .map_err(|e| invalid(e.to_string()))?,
            )
        })
    }
    fn current(&self) -> Result<bool, CommandError> {
        if let (Some(_), Some(revision)) = (&self.key, self.revision) {
            Ok(self.cache("claimedRevision", json!({}))?.as_u64() == Some(revision))
        } else {
            Ok(true)
        }
    }
    fn flow(
        &self,
        method: &str,
        config: Value,
        step: Option<&Value>,
    ) -> Result<Value, CommandError> {
        let mut args = json!({"flowID":self.id,"payloadJSON":config.to_string()});
        if let Some(step) = step {
            args["step"] = step.clone();
        }
        self.locked(|state| {
            state
                .danmaku_flow
                .call(method, &args)
                .map_err(|e| invalid(e.to_string()))
        })
    }
    fn intro(&self, episode: i64) -> Result<Value, CommandError> {
        self.cache("introHint", json!({"episodeID":episode}))
    }
    fn write(&self, method: &str, value: &Value, args: Value) -> Result<(), CommandError> {
        if !self.current()? {
            return Ok(());
        }
        let mut args = args;
        args["payloadJSON"] = json!(value.to_string());
        // Recheck the revision under the same lock as the mutation.
        self.locked(|state| {
            let Some(cache) = state.danmaku_cache.as_mut() else {
                return Ok(());
            };
            if let (Some(key), Some(revision)) = (&self.key, self.revision) {
                let current = unpack(
                    cache
                        .call("claimedRevision", &json!({"mediaID":key}))
                        .map_err(|e| invalid(e.to_string()))?,
                )?;
                if current.as_u64() != Some(revision) {
                    return Ok(());
                }
            }
            if let Some(key) = &self.key {
                args["mediaID"] = json!(key);
            }
            if let Some(revision) = self.revision {
                args["revision"] = json!(revision);
            }
            cache
                .call(method, &args)
                .map_err(|e| invalid(e.to_string()))?;
            Ok(())
        })
    }
}
fn options(args: &Value, request: &MatchRequest) -> Result<Value, CommandError> {
    let mut config = read_payload(args.get("configuration"))?;
    if !config.is_object() {
        return Err(invalid("configuration must be an object"));
    }
    config["delivery"] = json!("data");
    if config.get("mode").is_none() {
        config["mode"] = json!("automatic");
    }
    if config.get("context").is_none() {
        config["context"] = json!({});
    }
    let context = config["context"]
        .as_object_mut()
        .ok_or_else(|| invalid("context must be an object"))?;
    for (key, value) in [
        (
            "fileName",
            json!(request.file_name.clone().unwrap_or_default()),
        ),
        ("fileSize", json!(request.file_size)),
        ("durationSeconds", json!(request.video_duration)),
    ] {
        context.entry(key).or_insert(value);
    }
    Ok(config)
}
fn setting(args: &Value, name: &str) -> Value {
    args.get("providers")
        .and_then(|v| v.get(name))
        .filter(|v| v.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}))
}
async fn resolve_ids(
    session: &Session,
    http: &ocp_http::HttpClient,
    args: &Value,
    effect: &Value,
) -> Result<Value, CommandError> {
    let identity: identity::Identity =
        serde_json::from_value(effect["identity"].clone()).map_err(|e| invalid(e.to_string()))?;
    let force = effect["forceRefresh"] == true;
    let store = session.locked(|state| Ok(state.intro_ids.clone()))?;
    let plan = if let Some(store) = &store {
        store
            .lock()
            .map_err(|_| invalid("intro ID store unavailable"))?
            .prepare(&identity, force, identity::reference_now())
    } else {
        identity::plan(&identity, None, force, identity::reference_now())
    };
    if let Some(ids) = plan.ready {
        return Ok(json!(ids));
    }
    let mut config = setting(args, "aniList");
    if config["enabled"] == false {
        return Ok(json!(identity::IDs::default()));
    }
    config["anilistID"] = json!(plan.anilist_id);
    config["searchTitles"] = json!(plan.search_titles);
    let resolution = identity::resolve_ids(http, &config).await?;
    session.check()?;
    if !session.current()? {
        return Ok(json!(resolution.ids));
    }
    if let (Some(store), Some(key)) = (store, plan.cache_key) {
        session.locked(|state| {
            if !state
                .intro_ids
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &store))
            {
                return Ok(());
            }
            if let (Some(media), Some(revision)) = (&session.key, session.revision) {
                let Some(cache) = state.danmaku_cache.as_mut() else {
                    return Ok(());
                };
                let current = unpack(
                    cache
                        .call("claimedRevision", &json!({"mediaID":media}))
                        .map_err(|e| invalid(e.to_string()))?,
                )?;
                if current.as_u64() != Some(revision) {
                    return Ok(());
                }
            }
            let mut store = store
                .lock()
                .map_err(|_| invalid("intro ID store unavailable"))?;
            session.check()?;
            store.write(
                &key,
                identity::Record {
                    mal_id: resolution.ids.mal_id,
                    anilist_id: resolution.ids.anilist_id,
                    resolved_at: identity::reference_now(),
                },
            )?;
            Ok(())
        })?;
    }
    Ok(json!(resolution.ids))
}
async fn sources(http: &ocp_http::HttpClient, args: &Value, effects: &Value) -> Value {
    let mut tasks = tokio::task::JoinSet::new();
    for source in effects["sources"].as_array().into_iter().flatten() {
        let Some(name) = source["provider"].as_str() else {
            continue;
        };
        let mut config = setting(args, name);
        if config["enabled"] == false
            || (name == "animeSkip" && config["clientID"].as_str().is_none_or(|v| v.is_empty()))
        {
            continue;
        }
        config["episodeNumber"] = source["episodeNumber"].clone();
        config["seasonNumber"] = source["seasonNumber"].clone();
        let (method, source_kind, key) = match name {
            "aniSkip" => ("aniskip", IntroSource::Aniskip, "malID"),
            "animeSkip" => ("animeSkip", IntroSource::AnimeSkip, "anilistID"),
            "theIntroDB" => ("theIntroDB", IntroSource::TheIntroDB, "tmdbID"),
            _ => continue,
        };
        config[key] = source["id"].clone();
        config["episodeLengthSeconds"] = source["durationSeconds"].clone();
        let http = http.clone();
        tasks.spawn(async move {
            let value = unpack(providers::fetch(&http, method, &config).await.ok()?).ok()?;
            if method == "aniskip" {
                let intervals: Option<Vec<providers::AniSkipInterval>> =
                    serde_json::from_value(value).ok()?;
                let hint = providers::aniskip_hint(&intervals?)?;
                Some(intro::Interval {
                    source: source_kind,
                    start: hint.start_seconds,
                    end: hint.end_seconds,
                })
            } else {
                let interval: Option<providers::ExternalInterval> =
                    serde_json::from_value(value).ok()?;
                let interval = interval?;
                Some(intro::Interval {
                    source: source_kind,
                    start: interval.start_seconds,
                    end: interval.end_seconds,
                })
            }
        });
    }
    let mut result = Vec::new();
    while let Some(value) = tasks.join_next().await {
        if let Ok(Some(value)) = value {
            result.push(value);
        }
    }
    json!(result)
}
pub(super) async fn run(
    state: Arc<Mutex<State>>,
    http: ocp_http::HttpClient,
    args: &Value,
    cancelled: Option<Arc<AtomicBool>>,
) -> Result<Value, CommandError> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let gateway_config: GatewayConfig =
        serde_json::from_value(args.get("gateway").cloned().unwrap_or(Value::Null))
            .map_err(|e| invalid(format!("invalid gateway config: {e}")))?;
    let request: MatchRequest =
        serde_json::from_value(args.get("matchRequest").cloned().unwrap_or(json!({})))
            .map_err(|e| invalid(format!("invalid matchRequest: {e}")))?;
    let mut config = options(args, &request)?;
    let key: Option<String> =
        serde_json::from_value(args.get("cacheKey").cloned().unwrap_or(Value::Null))
            .map_err(|e| invalid(e.to_string()))?;
    let revision: Option<u64> =
        serde_json::from_value(args.get("revision").cloned().unwrap_or(Value::Null))
            .map_err(|e| invalid(e.to_string()))?;
    if revision.is_some() && key.is_none() {
        return Err(invalid("revision requires cacheKey"));
    }
    let timeout = args.get("timeoutSeconds").map_or(Ok(30.0), |v| {
        v.as_f64()
            .filter(|v| v.is_finite() && *v > 0.0 && *v <= 300.0)
            .ok_or_else(|| invalid("invalid timeoutSeconds"))
    })?;
    let attempts = args.get("retryAttempts").map_or(Ok(3), |v| {
        v.as_u64()
            .filter(|v| (1..=20).contains(v))
            .ok_or_else(|| invalid("retryAttempts must be in 1...20"))
    })?;
    let mut session = Session {
        state,
        id: format!(
            "__ocp_data_load_{}_{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ),
        key,
        revision,
        cancelled,
        registered: false,
    };
    session.locked(|state| {
        if session.key.is_some() && state.danmaku_cache.is_none() {
            return Err(CommandError(
                1401,
                false,
                "danmaku cache is not configured".into(),
            ));
        }
        config["hasLearning"] = json!(state.intro_learning.is_some());
        if !session.key.is_some() {
            config["context"]["allowsCachedMatchReuse"] = json!(false);
        }
        Ok(())
    })?;
    let aliases: Vec<String> =
        serde_json::from_value(args.get("aliases").cloned().unwrap_or(json!([])))
            .map_err(|e| invalid(e.to_string()))?;
    config["hasAliases"] = json!(!aliases.is_empty());
    let format = args.get("format").and_then(Value::as_str).unwrap_or("both");
    // Keep the legacy comments field available even for a kernel-track consumer.
    render::render(&[], format, false)?;
    let gateway = load_wire::Gateway::new(
        DanmakuGateway::with_http(gateway_config, http.clone()),
        timeout,
        attempts as usize,
    );
    let mut response = session.flow("begin", config, None)?;
    session.registered = true;
    let mut comments: Vec<DanmakuComment> = vec![];
    let mut payload: Option<render::Payload> = None;
    let mut last_error: Option<load_wire::Failure> = None;
    loop {
        session.check()?;
        if !response["outcome"].is_null() {
            break;
        }
        let effect = &response["effect"];
        let kind = effect["kind"]
            .as_str()
            .ok_or_else(|| invalid("missing load effect"))?;
        let effect_args = &effect["arguments"];
        let matched: Option<EpisodeMatch> = serde_json::from_value(response["match"].clone())
            .map_err(|e| invalid(e.to_string()))?;
        let episode = matched.as_ref().map(|v| v.episode_id).unwrap_or(0);
        let mut error = Value::Null;
        let value = match kind {
            "clearForce" => Value::Null,
            "claim" => {
                if session.revision.is_some() {
                    session.cache("claimRevision", json!({}))?;
                }
                Value::Null
            }
            "cachedMatch" => session.cache("episodeMatch", json!({}))?,
            "fingerprint" => {
                if let Some(path) = args.get("filePath").and_then(Value::as_str) {
                    let path = path.to_owned();
                    let hash = tokio::task::spawn_blocking(move || ocp_danmaku::head16m_md5(path))
                        .await
                        .map_err(|e| invalid(e.to_string()))?
                        .ok();
                    json!(hash)
                } else {
                    json!(request.file_hash)
                }
            }
            "match" | "search" | "comments" => {
                let result = if kind == "match" {
                    let mut effect_args = effect_args.clone();
                    if effect_args["fileName"]
                        .as_str()
                        .is_none_or(|v| v.is_empty())
                    {
                        effect_args["matchMode"] = json!("hashOnly");
                    }
                    gateway.matches(&effect_args).await
                } else if kind == "search" {
                    gateway.search(effect_args).await
                } else {
                    gateway.comments(episode).await.map(|value| {
                        comments = value;
                        Value::Null
                    })
                };
                match result {
                    Ok(value) => value,
                    Err(failure) => {
                        error = failure.reply();
                        last_error = Some(failure);
                        Value::Null
                    }
                }
            }
            "remember" => {
                if session.key.is_some() {
                    session.write("setEpisodeMatch", &response["match"], json!({}))?;
                }
                Value::Null
            }
            "forget" => {
                if session.key.is_some() {
                    session.cache("removeEpisodeMatch", json!({}))?;
                }
                Value::Null
            }
            "detectIntro" | "cachedIntro" => session.intro(episode)?,
            "cachedComments" => {
                let value = session.cache("comments", json!({"episodeID":episode}))?;
                let hit = !value.is_null();
                if hit {
                    comments = serde_json::from_value(value).map_err(|e| invalid(e.to_string()))?;
                }
                json!({"hit":hit})
            }
            "persistComments" => {
                session.write(
                    "setComments",
                    &json!(comments),
                    json!({"episodeID":episode}),
                )?;
                Value::Null
            }
            "render" => {
                let value =
                    render::render(&comments, format, effect_args["detectingIntro"] == true)?;
                let summary = json!({"hasEntries":value.entries.is_some(),"hasJSON":value.json.is_some(),"commentCount":value.comment_count,"detectedIntroHint":value.detected_intro_hint});
                payload = Some(value);
                summary
            }
            "aliases" => json!(aliases),
            "resolveIDs" => resolve_ids(&session, &http, args, effect_args).await?,
            "sources" => sources(&http, args, effect_args).await,
            "promoted" => session.locked(|state| {
                state
                    .intro_learning
                    .as_mut()
                    .map(|store| {
                        store
                            .call("promotedHint", effect_args)
                            .map_err(invalid)
                            .and_then(unpack)
                    })
                    .unwrap_or(Ok(Value::Null))
            })?,
            "siblings" => session.locked(|state| {
                let Some(cache) = state.danmaku_cache.as_mut() else {
                    return Ok(json!([]));
                };
                let id = effect_args["animeID"].as_i64().unwrap();
                let mut ids = cache.episode_ids(id);
                ids.sort_unstable();
                ids.dedup();
                let hints: Vec<IntroHint> = ids
                    .into_iter()
                    .filter(|id| *id != episode)
                    .filter_map(|id| cache.intro_hint(id))
                    .filter(|hint| matches!(hint.source, IntroSource::Danmaku))
                    .collect();
                Ok(json!(hints))
            })?,
            "persistIntro" => {
                session.write(
                    "setIntroHint",
                    &effect_args["hint"],
                    json!({"episodeID":episode}),
                )?;
                Value::Null
            }
            _ => return Err(invalid(format!("unexpected data delivery effect: {kind}"))),
        };
        response = session.flow(
            "advance",
            json!({"value":value,"error":error,"current":session.current()?}),
            Some(&response["step"]),
        )?;
    }
    let outcome = &response["outcome"];
    if outcome["kind"] == "failed" {
        let message = outcome["message"]
            .as_str()
            .unwrap_or("弹幕加载失败")
            .to_owned();
        if message == "播放已切换" {
            return Err(CommandError(1003, false, message));
        }
        return Err(if let Some(error) = last_error {
            CommandError(error.code, error.retryable, message)
        } else {
            CommandError(
                if response["diagnostics"]["budgetDidCut"] == true {
                    1503
                } else {
                    1502
                },
                response["diagnostics"]["budgetDidCut"] == true,
                message,
            )
        });
    }
    let mut episodes = Vec::new();
    let mut candidates = Vec::new();
    if let Some(payload) = payload {
        let matched: EpisodeMatch = serde_json::from_value(response["match"].clone())
            .map_err(|e| invalid(e.to_string()))?;
        let candidate = json!({"episodeId":matched.episode_id,"animeId":matched.anime_id,"shift":matched.shift_seconds,"animeTitle":matched.anime_title,"episodeTitle":matched.episode_title});
        candidates.push(candidate.clone());
        let overlay = render::render(&comments, "overlay", false)?
            .entries
            .unwrap_or_default();
        episodes.push(json!({"candidate":candidate,"count":overlay.len(),"comments":overlay,"entries":payload.entries,"json":payload.json,
            "rawCommentCount":payload.comment_count,"introHint":outcome["introHint"]}));
    }
    let result = json!({"match":{"success":true,"matches":candidates},"episodes":episodes,"outcome":outcome,"selectedMatch":response["match"],"diagnostics":response["diagnostics"]});
    let mut data = result.clone();
    data["payloadJSON"] = json!(result.to_string());
    Ok(data)
}
