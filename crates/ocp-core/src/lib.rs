//! Composition root for the platform-neutral OcPlayer business core.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ocp_model::{
    ApiResponse, CoreConfig, CoreSnapshot, PlaybackSnapshot, PlaybackState, ABI_VERSION,
    CORE_VERSION,
};
use ocp_session::{PlaybackCandidate, PlaybackFailure, PlaybackFailureCategory, PlaybackSession};
use serde_json::{json, Value};
use thiserror::Error;

mod events;
mod network;
mod probe;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("invalid JSON: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("unknown method: {0}")]
    UnknownMethod(String),
    #[error("unknown snapshot kind: {0}")]
    UnknownSnapshot(String),
    #[error("core state is unavailable")]
    StateUnavailable,
    #[error("session: {0}")]
    Session(String),
    #[error("store: {0}")]
    Store(#[from] ocp_store::StoreError),
    #[error("store configuration: {0}")]
    StoreConfig(String),
}

struct State {
    config: CoreConfig,
    ready: bool,
    surface_attached: bool,
    active_method: Option<String>,
    events: events::EventQueue,
    playback: PlaybackSnapshot,
    session: PlaybackSession,
    playback_flow: ocp_session::flow::PlaybackFlow,
    engine_events: ocp_session::engine::EngineEvents,
    store: Option<ocp_store::Store>,
    bangumi_store: Option<ocp_store::BangumiStore>,
    endpoint: Option<ocp_jellyfin::endpoint::EndpointDirectory>,
}

pub struct Core {
    state: Arc<Mutex<State>>,
    requests: Arc<Mutex<HashMap<String, RequestControl>>>,
    network_service: Mutex<Option<Arc<network::NetworkService>>>,
}

struct RequestControl {
    cancelled: Arc<AtomicBool>,
    running: bool,
}

struct RequestGuard {
    id: String,
    requests: Arc<Mutex<HashMap<String, RequestControl>>>,
    cancelled: Arc<AtomicBool>,
}

impl Drop for RequestGuard {
    fn drop(&mut self) {
        if let Ok(mut requests) = self.requests.lock() {
            requests.remove(&self.id);
        }
    }
}

async fn cancellable<T>(
    cancelled: Option<Arc<AtomicBool>>,
    operation: impl std::future::Future<Output = Result<T, CommandError>>,
) -> Result<T, CommandError> {
    let Some(cancelled) = cancelled else {
        return operation.await;
    };
    let cancellation = async {
        loop {
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    };
    tokio::select! {
        biased;
        _ = cancellation => Err(CommandError(1003, false, "request cancelled".into())),
        result = operation => result,
    }
}

impl Core {
    pub fn new(config_json: &str) -> Result<Self, CoreError> {
        let mut config = if config_json.trim().is_empty() {
            CoreConfig::default()
        } else {
            serde_json::from_str(config_json)?
        };
        if config.locale.is_none() {
            config.locale = CoreConfig::default().locale;
        }
        let store = if let Some(path) = config.media_database_path.as_deref() {
            Some(ocp_store::Store::open(path)?)
        } else {
            config
                .data_directory
                .as_deref()
                .map(open_store)
                .transpose()?
        };

        let core = Self {
            requests: Arc::new(Mutex::new(HashMap::new())),
            network_service: Mutex::new(None),
            state: Arc::new(Mutex::new(State {
                config,
                ready: true,
                surface_attached: false,
                active_method: None,
                events: events::EventQueue::default(),
                playback: PlaybackSnapshot::default(),
                session: PlaybackSession::new(2),
                playback_flow: Default::default(),
                engine_events: Default::default(),
                store,
                bangumi_store: None,
                endpoint: None,
            })),
        };
        if let Ok(mut state) = core.state.lock() {
            state.push_event("core.ready", json!({ "abiVersion": ABI_VERSION }));
        }
        Ok(core)
    }

    fn network(&self) -> Result<Arc<network::NetworkService>, String> {
        let mut service = self
            .network_service
            .lock()
            .map_err(|_| "network service unavailable".to_owned())?;
        if service.is_none() {
            *service = Some(Arc::new(network::NetworkService::new()?));
        }
        Ok(service
            .as_ref()
            .expect("initialized network service")
            .clone())
    }

    pub fn call(&self, method: &str, arguments_json: &str) -> Result<String, CoreError> {
        let arguments: Value = if arguments_json.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(arguments_json)?
        };
        if matches!(method, "request.prepare" | "request.cancel") {
            let id = required_arg(&arguments, "requestId")?;
            let mut requests = self
                .requests
                .lock()
                .map_err(|_| CoreError::StateUnavailable)?;
            let data = if method == "request.prepare" {
                if requests.contains_key(id) {
                    return Ok(error_response(1002, false, "requestId is already in use"));
                }
                requests.insert(
                    id.into(),
                    RequestControl {
                        cancelled: Arc::new(AtomicBool::new(false)),
                        running: false,
                    },
                );
                json!({"requestId": id})
            } else {
                let found = if let Some(control) = requests.get(id) {
                    control.cancelled.store(true, Ordering::Release);
                    true
                } else {
                    false
                };
                json!({"requestId": id, "cancelled": found})
            };
            return serde_json::to_string(&ApiResponse::ok(data)).map_err(CoreError::InvalidJson);
        }
        let request = if let Some(id) = arguments.get("requestId").and_then(Value::as_str) {
            if id.is_empty() {
                return Ok(error_response(1002, false, "requestId must not be empty"));
            }
            let mut requests = self
                .requests
                .lock()
                .map_err(|_| CoreError::StateUnavailable)?;
            let control = requests.entry(id.into()).or_insert_with(|| RequestControl {
                cancelled: Arc::new(AtomicBool::new(false)),
                running: false,
            });
            if control.running {
                return Ok(error_response(1002, false, "requestId is already running"));
            }
            control.running = true;
            Some(RequestGuard {
                id: id.into(),
                requests: self.requests.clone(),
                cancelled: control.cancelled.clone(),
            })
        } else {
            None
        };
        let cancelled = request.as_ref().map(|r| r.cancelled.clone());
        if cancelled
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Acquire))
        {
            return Ok(error_response(1003, false, "request cancelled"));
        }
        if method == "endpoint.probe" {
            let service = match self.network() {
                Ok(service) => service,
                Err(error) => return Ok(error_response(1500, false, error)),
            };
            let client = service.client.clone();
            let response = match service.run(cancellable(cancelled, probe::run(client, arguments)))
            {
                Ok(data) => ApiResponse::ok(data),
                Err(CommandError(code, retryable, message)) => {
                    ApiResponse::error(code, retryable, message, Value::Null)
                }
            };
            return serde_json::to_string(&response).map_err(CoreError::InvalidJson);
        }
        if method == "moviepilot.clearSessions" {
            if let Some(service) = self
                .network_service
                .lock()
                .map_err(|_| CoreError::StateUnavailable)?
                .as_ref()
            {
                service
                    .moviepilot
                    .lock()
                    .map_err(|_| CoreError::StateUnavailable)?
                    .clear();
            }
            return Ok(serde_json::to_string(&ApiResponse::ok(
                json!({"cleared": true}),
            ))?);
        }
        if is_server_command(method) || is_domain_command(method) || is_moviepilot_command(method) {
            {
                let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
                state.active_method = Some(method.to_string());
            }
            let service = match self.network() {
                Ok(service) => service,
                Err(error) => return Ok(error_response(1500, false, error)),
            };
            let result = if is_server_command(method) {
                run_server_command(&service, method, &arguments, cancelled.clone())
            } else if is_moviepilot_command(method) {
                run_moviepilot_command(
                    &service,
                    method,
                    &arguments,
                    self.state.clone(),
                    cancelled.clone(),
                )
            } else {
                run_domain_command(&service, method, &arguments, cancelled.clone())
            };
            let response = match result {
                Ok(data) => ApiResponse::ok(data),
                Err((code, retryable, message)) => {
                    ApiResponse::error(code, retryable, message, Value::Null)
                }
            };
            return serde_json::to_string(&response).map_err(CoreError::InvalidJson);
        }
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        state.active_method = Some(method.to_string());

        if matches!(
            method,
            "playback.ready" | "playback.seek" | "playback.position"
        ) && arguments
            .get("durationSeconds")
            .is_some_and(|value| !value.is_null())
            && !number_arg(&arguments, "durationSeconds").is_some_and(|duration| duration >= 0.0)
        {
            return Ok(error_response(
                1002,
                false,
                "durationSeconds must be a finite non-negative number",
            ));
        }

        let response = match method {
            method if method.starts_with("playbackEvents.") => {
                match call_playback_events(&mut state, method, &arguments) {
                    Ok(data) => ApiResponse::ok(data),
                    Err(message) => ApiResponse::error(1002, false, message, Value::Null),
                }
            }
            method if method.starts_with("playbackFlow.") => {
                match call_playback_flow(&mut state, method, &arguments) {
                    Ok(data) => ApiResponse::ok(data),
                    Err(message) => ApiResponse::error(1002, false, message, Value::Null),
                }
            }
            method if method.starts_with("endpoint.") => {
                match call_endpoint_policy(&mut state, method, &arguments) {
                    Ok(data) => ApiResponse::ok(data),
                    Err(message) => ApiResponse::error(1002, false, message, Value::Null),
                }
            }
            method if method.starts_with("bangumiStore.") => {
                if state.bangumi_store.is_none() {
                    state.bangumi_store = match open_bangumi_store(&state.config) {
                        Ok(store) => store,
                        Err(error) => return Ok(error_response(1402, false, error.to_string())),
                    };
                }
                let Some(store) = state.bangumi_store.as_ref() else {
                    return Ok(error_response(
                        1401,
                        false,
                        "Bangumi persistence is not configured",
                    ));
                };
                match store.call(method.trim_start_matches("bangumiStore."), &arguments) {
                    Ok(data) => ApiResponse::ok(data),
                    Err(ocp_store::StoreError::InvalidRequest(message)) => {
                        ApiResponse::error(1002, false, message, Value::Null)
                    }
                    Err(error) => ApiResponse::error(1402, false, error.to_string(), Value::Null),
                }
            }
            method if method.starts_with("cache.") => {
                let Some(store) = state.store.as_ref() else {
                    return Ok(error_response(1401, false, "persistence is not configured"));
                };
                match store.cache_call(method, &arguments) {
                    Ok(data) => ApiResponse::ok(data),
                    Err(ocp_store::StoreError::InvalidRequest(message)) => {
                        ApiResponse::error(1002, false, message, Value::Null)
                    }
                    Err(error) => ApiResponse::error(1402, false, error.to_string(), Value::Null),
                }
            }
            "ping" => ApiResponse::ok(json!({
                "abiVersion": ABI_VERSION,
                "coreVersion": CORE_VERSION,
                "pong": true,
            })),
            "core.getVersion" => ApiResponse::ok(json!({
                "abiVersion": ABI_VERSION,
                "coreVersion": CORE_VERSION,
            })),
            "settings.schema" => ApiResponse::ok(json!({
                "schemaVersion": 1,
                "config": state.config.clone(),
            })),
            "config.export" => ApiResponse::ok(json!({
                "schemaVersion": 1,
                "config": state.config.clone(),
            })),
            "config.validate" => {
                let config_value = arguments.get("config").cloned().unwrap_or(Value::Null);
                match serde_json::from_value::<CoreConfig>(config_value) {
                    Ok(config) => ApiResponse::ok(json!({
                        "valid": true,
                        "schemaVersion": 1,
                        "config": config,
                    })),
                    Err(error) => ApiResponse::error(
                        1002,
                        false,
                        format!("invalid config: {error}"),
                        json!({"valid": false}),
                    ),
                }
            }
            "config.import" => {
                let config_value = arguments
                    .get("config")
                    .cloned()
                    .or_else(|| {
                        arguments
                            .get("backup")
                            .and_then(|v| v.get("config"))
                            .cloned()
                    })
                    .unwrap_or(Value::Null);
                let mut config: CoreConfig = match serde_json::from_value(config_value.clone()) {
                    Ok(config) => config,
                    Err(error) => {
                        return Ok(error_response(
                            1002,
                            false,
                            format!("invalid config: {error}"),
                        ))
                    }
                };
                if config.locale.is_none() {
                    config.locale = CoreConfig::default().locale;
                }
                if config.data_directory.is_none() {
                    config.data_directory = state.config.data_directory.clone();
                }
                if !config_value
                    .as_object()
                    .is_some_and(|o| o.contains_key("mediaDatabasePath"))
                {
                    config.media_database_path = state.config.media_database_path.clone();
                }
                if !config_value
                    .as_object()
                    .is_some_and(|o| o.contains_key("bangumiDatabasePath"))
                {
                    config.bangumi_database_path = state.config.bangumi_database_path.clone();
                }
                if config.bangumi_database_path != state.config.bangumi_database_path
                    || (config.bangumi_database_path.is_none()
                        && config.data_directory != state.config.data_directory)
                {
                    state.bangumi_store = None;
                }
                if config.data_directory != state.config.data_directory
                    || config.media_database_path != state.config.media_database_path
                {
                    state.store = open_config_store(&config)?;
                }
                state.config = config.clone();
                state.push_event("settings.changed", json!({ "config": config }));
                ApiResponse::ok(json!({ "schemaVersion": 1, "config": state.config.clone() }))
            }
            "diag.snapshot" | "diag.export" => {
                let include_config = arguments
                    .get("includeConfig")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let mut config = if include_config {
                    serde_json::to_value(&state.config)?
                } else {
                    Value::Null
                };
                if arguments
                    .get("redact")
                    .and_then(Value::as_bool)
                    .unwrap_or(true)
                {
                    redact_config(&mut config);
                }
                ApiResponse::ok(json!({
                    "schemaVersion": 1,
                    "generatedAt": ocp_store::now_seconds(),
                    "core": {
                        "abiVersion": ABI_VERSION,
                        "coreVersion": CORE_VERSION,
                        "ready": state.ready,
                        "surfaceAttached": state.surface_attached,
                        "activeMethod": state.active_method,
                        "eventQueueDepth": state.events.len(),
                        "eventQueue": state.events.diagnostics(),
                        "network": self.network_service.lock().ok().and_then(|service| service.as_ref().map(|service| service.diagnostics())),
                    },
                    "playback": state.playback.clone(),
                    "playbackFlow": state.playback_flow.snapshot(),
                    "playbackEvents": state.engine_events.snapshot(),
                    "config": config,
                }))
            }
            "progress.save" => {
                let Some(store) = state.store.as_mut() else {
                    return Ok(error_response(1401, false, "persistence is not configured"));
                };
                let tenant_id = required_arg(&arguments, "tenantId")?;
                let item_id = required_arg(&arguments, "itemId")?;
                let position = number_arg(&arguments, "positionSeconds")
                    .filter(|value| *value >= 0.0)
                    .ok_or_else(|| {
                        CoreError::StoreConfig("positionSeconds must be non-negative".into())
                    })?;
                let progress = ocp_store::ProgressRecord {
                    tenant_id: tenant_id.to_string(),
                    item_id: item_id.to_string(),
                    position_seconds: position,
                    duration_seconds: number_arg(&arguments, "durationSeconds"),
                    played: arguments
                        .get("played")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    recorded_at: arguments
                        .get("recordedAt")
                        .and_then(Value::as_f64)
                        .unwrap_or_else(ocp_store::now_seconds),
                    confirmed_at: arguments.get("confirmedAt").and_then(Value::as_f64),
                    completed: arguments
                        .get("completed")
                        .and_then(Value::as_bool)
                        .unwrap_or_else(|| {
                            number_arg(&arguments, "durationSeconds")
                                .is_some_and(|d| d > 0.0 && position >= (d - 2.0).max(0.0))
                        }),
                    item: arguments.get("item").cloned(),
                };
                store.save_progress(&progress)?;
                let saved_progress = store.progress(tenant_id, item_id)?;
                state.push_event(
                    "progress.saved",
                    json!({ "tenantId": tenant_id, "itemId": item_id }),
                );
                ApiResponse::ok(json!({ "progress": saved_progress }))
            }
            "progress.get" => {
                let Some(store) = state.store.as_ref() else {
                    return Ok(error_response(1401, false, "persistence is not configured"));
                };
                let tenant_id = required_arg(&arguments, "tenantId")?;
                let item_id = required_arg(&arguments, "itemId")?;
                ApiResponse::ok(json!({ "progress": store.progress(tenant_id, item_id)? }))
            }
            "danmaku.parseFilename" => {
                let Some(file_name) = arguments.get("fileName").and_then(Value::as_str) else {
                    return Ok(error_response(1002, false, "fileName is required"));
                };
                ApiResponse::ok(serde_json::to_value(ocp_danmaku::parse_filename(
                    file_name,
                ))?)
            }
            "danmaku.canonicalMatchName" => {
                let Some(file_name) = arguments.get("rawFileName").and_then(Value::as_str) else {
                    return Ok(error_response(1002, false, "rawFileName is required"));
                };
                let episode = arguments
                    .get("episode")
                    .cloned()
                    .and_then(|value| serde_json::from_value(value).ok());
                ApiResponse::ok(json!({
                    "fileName": ocp_danmaku::canonical_match_name(
                        arguments.get("seriesTitle").and_then(Value::as_str),
                        arguments.get("season").and_then(Value::as_u64).map(|value| value as u32),
                        episode,
                        file_name,
                    )
                }))
            }
            "tmdb.match" => {
                let Some(query) = arguments.get("query").and_then(Value::as_str) else {
                    return Ok(error_response(1002, false, "query is required"));
                };
                let Some(candidates) = arguments.get("candidates").cloned() else {
                    return Ok(error_response(1002, false, "candidates is required"));
                };
                let candidates: Vec<ocp_tmdb::TmdbEntity> = match serde_json::from_value(candidates)
                {
                    Ok(value) => value,
                    Err(error) => return Ok(error_response(1002, false, error.to_string())),
                };
                let matched = ocp_tmdb::match_candidates(
                    query,
                    arguments
                        .get("year")
                        .and_then(Value::as_i64)
                        .map(|value| value as i32),
                    &candidates,
                );
                ApiResponse::ok(json!({ "match": matched }))
            }
            "server.imageURL" | "server.streamURL" => {
                let profile: ocp_jellyfin::ServerProfile = match serde_json::from_value(
                    arguments.get("profile").cloned().unwrap_or(Value::Null),
                ) {
                    Ok(value) => value,
                    Err(error) => return Ok(error_response(1002, false, error.to_string())),
                };
                let Some(item_id) = arguments.get("itemId").and_then(Value::as_str) else {
                    return Ok(error_response(1002, false, "itemId is required"));
                };
                let result = if method == "server.imageURL" {
                    ocp_jellyfin::image_url(
                        &profile,
                        item_id,
                        arguments
                            .get("imageType")
                            .and_then(Value::as_str)
                            .unwrap_or("Primary"),
                        arguments.get("tag").and_then(Value::as_str),
                        arguments
                            .get("maxWidth")
                            .and_then(Value::as_u64)
                            .map(|value| value as u32),
                    )
                    .map(|url| url.to_string())
                } else {
                    ocp_jellyfin::stream_url(
                        &profile,
                        item_id,
                        arguments.get("mediaSourceId").and_then(Value::as_str),
                        arguments.get("playSessionId").and_then(Value::as_str),
                    )
                    .map(|url| url.to_string())
                };
                match result {
                    Ok(url) => ApiResponse::ok(json!({ "url": url })),
                    Err(error) => ApiResponse::error(1002, false, error.to_string(), Value::Null),
                }
            }
            "settings.get" => ApiResponse::ok(json!({ "config": state.config })),
            "settings.set" => {
                let config_value = arguments.get("config").cloned().unwrap_or(arguments);
                let config: CoreConfig = match serde_json::from_value(config_value.clone()) {
                    Ok(config) => config,
                    Err(error) => return Ok(error_response(1002, false, error.to_string())),
                };
                let mut config = config;
                if config.locale.is_none() {
                    config.locale = CoreConfig::default().locale;
                }
                if config.data_directory.is_none()
                    && config_value.as_object().is_some_and(|object| {
                        !object.contains_key("dataDirectory")
                            && !object.contains_key("data_directory")
                    })
                {
                    config.data_directory = state.config.data_directory.clone();
                }
                if !config_value
                    .as_object()
                    .is_some_and(|o| o.contains_key("mediaDatabasePath"))
                {
                    config.media_database_path = state.config.media_database_path.clone();
                }
                if !config_value
                    .as_object()
                    .is_some_and(|o| o.contains_key("bangumiDatabasePath"))
                {
                    config.bangumi_database_path = state.config.bangumi_database_path.clone();
                }
                if config.bangumi_database_path != state.config.bangumi_database_path
                    || (config.bangumi_database_path.is_none()
                        && config.data_directory != state.config.data_directory)
                {
                    state.bangumi_store = None;
                }
                if config.data_directory != state.config.data_directory
                    || config.media_database_path != state.config.media_database_path
                {
                    state.store = open_config_store(&config)?;
                }
                state.config = config.clone();
                state.push_event("settings.changed", json!({ "config": config }));
                ApiResponse::ok(json!({ "config": state.config }))
            }
            "playback.open" => {
                let Some(source) = arguments.get("source").filter(|value| !value.is_null()) else {
                    return Ok(error_response(1002, false, "source is required"));
                };
                let candidate_id = arguments
                    .get("sourceId")
                    .and_then(Value::as_str)
                    .unwrap_or("primary")
                    .to_string();
                let candidates = arguments
                    .get("candidates")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .enumerate()
                            .map(|(index, value)| PlaybackCandidate {
                                id: value
                                    .get("id")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned)
                                    .unwrap_or_else(|| format!("candidate-{index}")),
                                source: value
                                    .get("source")
                                    .cloned()
                                    .unwrap_or_else(|| value.clone()),
                                display_name: value
                                    .get("displayName")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned),
                            })
                            .collect()
                    })
                    .unwrap_or_else(|| {
                        vec![PlaybackCandidate {
                            id: candidate_id.clone(),
                            source: source.clone(),
                            display_name: None,
                        }]
                    });
                if let Err(error) = state.session.open(candidates, Some(&candidate_id)) {
                    return Ok(error_response(1002, false, error.to_string()));
                }
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.opened", json!({ "source": source }));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.play" => {
                if let Err(error) = state.session.play() {
                    return Ok(error_response(1101, false, error.to_string()));
                }
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.play", json!({}));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.pause" => {
                if let Err(error) = state.session.pause() {
                    return Ok(error_response(1101, false, error.to_string()));
                }
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.pause", json!({}));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.stop" => {
                if state.playback.state == PlaybackState::Idle {
                    return Ok(error_response(1101, false, "there is no playback session"));
                }
                state.session.stop();
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.stop", json!({}));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.ready" => {
                if state.playback.source.is_none() {
                    return Ok(error_response(1101, false, "there is no playback session"));
                }
                state
                    .session
                    .ready(number_arg(&arguments, "durationSeconds"));
                state.playback = state.session.snapshot().playback.clone();
                let duration_seconds = state.playback.duration_seconds;
                state.push_event(
                    "playback.ready",
                    json!({ "durationSeconds": duration_seconds }),
                );
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.ended" => {
                if state.playback.source.is_none() {
                    return Ok(error_response(1101, false, "there is no playback session"));
                }
                state.session.ended();
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.ended", json!({}));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.failed" => {
                let category = match arguments
                    .get("category")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                {
                    "network" => PlaybackFailureCategory::Network,
                    "timeout" => PlaybackFailureCategory::Timeout,
                    "unauthorized" => PlaybackFailureCategory::Unauthorized,
                    "unsupported" => PlaybackFailureCategory::Unsupported,
                    "decode" => PlaybackFailureCategory::Decode,
                    "missing" => PlaybackFailureCategory::Missing,
                    "cancelled" => PlaybackFailureCategory::Cancelled,
                    _ => PlaybackFailureCategory::Unknown,
                };
                let failure = PlaybackFailure {
                    category,
                    message: arguments
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("playback failed")
                        .to_owned(),
                    retryable: arguments
                        .get("retryable")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    stops_automatic_recovery: arguments
                        .get("stopsAutomaticRecovery")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                };
                if arguments.get("recordOnly").and_then(Value::as_bool) == Some(true) {
                    state.session.record_failure(&failure);
                    state.playback = state.session.snapshot().playback.clone();
                    state.push_event("playback.failed", json!({"failure":failure}));
                    return serde_json::to_string(&ApiResponse::ok(
                        json!({"playback":state.playback.clone()}),
                    ))
                    .map_err(CoreError::InvalidJson);
                }
                let recovery = state
                    .session
                    .fail(failure.clone())
                    .map(|candidate| candidate.cloned());
                match recovery {
                    Ok(Some(candidate)) => {
                        let snapshot = state.session.snapshot();
                        let playback = snapshot.playback.clone();
                        let generation = snapshot.generation;
                        state.playback = playback;
                        state.push_event(
                            "playback.recoveryRequested",
                            json!({ "candidate": candidate, "failure": failure, "generation": generation }),
                        );
                        ApiResponse::ok(
                            json!({ "accepted": true, "playback": state.playback.clone() }),
                        )
                    }
                    Ok(None) => ApiResponse::ok(json!({ "accepted": false })),
                    Err(error) => {
                        state.playback = state.session.snapshot().playback.clone();
                        state.push_event(
                            "playback.failed",
                            json!({"failure":failure,"error":error.to_string()}),
                        );
                        ApiResponse::error(
                            1102,
                            false,
                            error.to_string(),
                            json!({"playback":state.playback.clone()}),
                        )
                    }
                }
            }
            "playback.seek" | "playback.position" => {
                let Some(position) = number_arg(&arguments, "positionSeconds") else {
                    return Ok(error_response(
                        1002,
                        false,
                        "positionSeconds must be a finite number",
                    ));
                };
                if position < 0.0 || state.playback.source.is_none() {
                    return Ok(error_response(
                        1002,
                        false,
                        "seek requires a session and non-negative position",
                    ));
                }
                let duration =
                    number_arg(&arguments, "durationSeconds").or(state.playback.duration_seconds);
                state.session.update_position(position, duration);
                state.playback = state.session.snapshot().playback.clone();
                let position_seconds = state.playback.position_seconds;
                state.push_event(
                    if method == "playback.position" {
                        "playback.position"
                    } else {
                        "playback.seek"
                    },
                    json!({ "positionSeconds": position_seconds }),
                );
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.setRate" => {
                let Some(rate) = number_arg(&arguments, "rate") else {
                    return Ok(error_response(1002, false, "rate must be a finite number"));
                };
                if !(0.25..=4.0).contains(&rate) {
                    return Ok(error_response(
                        1002,
                        false,
                        "rate must be between 0.25 and 4.0",
                    ));
                }
                state.session.set_rate(rate);
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.rateChanged", json!({ "rate": rate }));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.setVolume" => {
                let Some(volume) = number_arg(&arguments, "volume") else {
                    return Ok(error_response(
                        1002,
                        false,
                        "volume must be a finite number",
                    ));
                };
                if !(0.0..=1.0).contains(&volume) {
                    return Ok(error_response(
                        1002,
                        false,
                        "volume must be between 0.0 and 1.0",
                    ));
                }
                state.session.set_volume(volume);
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.volumeChanged", json!({ "volume": volume }));
                ApiResponse::ok(json!({ "playback": state.playback.clone() }))
            }
            "playback.setMuted" => {
                let Some(muted) = arguments.get("muted").and_then(Value::as_bool) else {
                    return Ok(error_response(1002, false, "muted must be a boolean"));
                };
                state.session.set_muted(muted);
                state.playback = state.session.snapshot().playback.clone();
                state.push_event("playback.muteChanged", json!({"muted":muted}));
                ApiResponse::ok(json!({"playback":state.playback.clone()}))
            }
            "playback.selectAudio" | "playback.selectSubtitle" => {
                if state.playback.source.is_none() {
                    return Ok(error_response(1101, false, "there is no playback session"));
                }
                if arguments
                    .get("trackId")
                    .is_some_and(|value| !value.is_null() && !value.is_string())
                {
                    return Ok(error_response(
                        1002,
                        false,
                        "trackId must be a string or null",
                    ));
                }
                let track = arguments.get("trackId").and_then(Value::as_str);
                if method == "playback.selectAudio" {
                    state.session.select_audio(track);
                } else {
                    state.session.select_subtitle(track);
                }
                state.playback = state.session.snapshot().playback.clone();
                state.push_event(method, json!({ "trackId": track }));
                ApiResponse::ok(json!({ "playback": state.playback }))
            }
            _ => ApiResponse::error(
                1001,
                false,
                format!("unknown method: {method}"),
                Value::Null,
            ),
        };
        serde_json::to_string(&response).map_err(CoreError::InvalidJson)
    }

    pub fn snapshot(&self, kind: &str) -> Result<String, CoreError> {
        let state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        let value = match kind {
            "core" | "" => serde_json::to_value(CoreSnapshot {
                abi_version: ABI_VERSION,
                core_version: CORE_VERSION.to_string(),
                ready: state.ready,
                config: state.config.clone(),
                surface_attached: state.surface_attached,
                active_method: state.active_method.clone(),
                playback: state.playback.clone(),
            })?,
            "playback" => serde_json::to_value(&state.playback)?,
            _ => return Err(CoreError::UnknownSnapshot(kind.to_string())),
        };
        serde_json::to_string(&value).map_err(CoreError::InvalidJson)
    }

    pub fn poll_event(&self) -> Result<Option<String>, CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        Ok(state.events.pop_front())
    }

    pub fn attach_surface(
        &self,
        native_handle: u64,
        width: u32,
        height: u32,
        scale: f64,
        kind: u32,
    ) -> Result<(), CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        state.surface_attached = true;
        state.push_event("surface.attached", json!({ "nativeHandle": native_handle, "width": width, "height": height, "scale": scale, "kind": kind }));
        Ok(())
    }

    pub fn resize_surface(&self, width: u32, height: u32, scale: f64) -> Result<(), CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        if state.surface_attached {
            state.push_event(
                "surface.resized",
                json!({ "width": width, "height": height, "scale": scale }),
            );
        }
        Ok(())
    }

    pub fn detach_surface(&self) -> Result<(), CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        if state.surface_attached {
            state.surface_attached = false;
            state.push_event("surface.detached", json!({}));
        }
        Ok(())
    }

    pub fn render_tick(&self, time_seconds: f64) -> Result<(), CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        if state.surface_attached {
            state.push_event("render.tick", json!({ "timeSeconds": time_seconds }));
        }
        Ok(())
    }
}

fn call_playback_events(state: &mut State, method: &str, args: &Value) -> Result<Value, String> {
    use ocp_session::engine::{Event, State as EngineState};
    match method {
        "playbackEvents.begin" => Ok(json!(state.engine_events.begin())),
        "playbackEvents.snapshot" => Ok(json!(state.engine_events.snapshot())),
        "playbackEvents.apply" => {
            let generation = args
                .get("generation")
                .and_then(Value::as_u64)
                .ok_or("generation is required")?;
            let event: Event =
                serde_json::from_value(args.get("event").cloned().ok_or("event is required")?)
                    .map_err(|e| e.to_string())?;
            if !event.valid() {
                return Err("invalid engine position or duration".into());
            }
            let previous = state.engine_events.snapshot().clone();
            let previous_playback_state = state.playback.state;
            let lifecycle = matches!(&event, Event::StateChanged { .. } | Event::Failed { .. });
            let decision = state.engine_events.apply(generation, event);
            if decision.accepted {
                if lifecycle {
                    state.session.observe_engine(&decision.snapshot);
                } else {
                    state.session.observe_engine_timeline(&decision.snapshot);
                }
                state.playback = state.session.snapshot().playback.clone();
                if decision.snapshot.position_seconds != previous.position_seconds {
                    let position = state.playback.position_seconds;
                    state.push_event(
                        "playback.position",
                        json!({"positionSeconds":position,"generation":generation}),
                    );
                }
                if decision.snapshot.duration_seconds != previous.duration_seconds {
                    state.push_event("playback.durationChanged", json!({"durationSeconds":decision.snapshot.duration_seconds,"generation":generation}));
                }
                if decision.snapshot.state != previous.state
                    || state.playback.state != previous_playback_state
                {
                    let playback_state = state.playback.state;
                    state.push_event("playback.stateChanged", json!({"state":playback_state,"nativeState":decision.snapshot.state,"generation":generation}));
                    if playback_state == PlaybackState::Ended {
                        state.push_event("playback.ended", json!({"generation":generation}));
                    }
                }
                if decision.reported_failure {
                    state.push_event(
                        "playback.failed",
                        json!({"failure":decision.snapshot.failure,"generation":generation}),
                    );
                }
                if decision.folded_tail_failure {
                    state.push_event("playback.tailErrorFolded", json!({"generation":generation}));
                }
            }
            Ok(json!(decision))
        }
        "playbackEvents.staleTailIO" => {
            let position = args
                .get("positionSeconds")
                .and_then(Value::as_f64)
                .ok_or("positionSeconds is required")?;
            let duration = args
                .get("durationSeconds")
                .and_then(Value::as_f64)
                .ok_or("durationSeconds is required")?;
            let message = match args.get("message") {
                None | Some(Value::Null) => None,
                Some(Value::String(s)) => Some(s.as_str()),
                _ => return Err("message must be a string or null".into()),
            };
            Ok(json!({"matches":ocp_session::engine::stale_tail_io(message, position, duration)}))
        }
        "playbackEvents.foreground" => {
            let intent = args
                .get("intentToResume")
                .and_then(Value::as_bool)
                .ok_or("intentToResume is required")?;
            let has_error = args
                .get("hasSetupError")
                .and_then(Value::as_bool)
                .ok_or("hasSetupError is required")?;
            let engine_state: Option<EngineState> =
                serde_json::from_value(args.get("state").cloned().unwrap_or(Value::Null))
                    .map_err(|e| e.to_string())?;
            Ok(
                json!({"action":ocp_session::engine::foreground_action(intent, engine_state, has_error)}),
            )
        }
        _ => Err(format!("unknown method: {method}")),
    }
}

fn call_playback_flow(state: &mut State, method: &str, args: &Value) -> Result<Value, String> {
    use ocp_session::flow::{Alternate, OpenFailureKind};
    let request_id = || {
        args.get("playbackRequestId")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| "playbackRequestId is required".to_owned())
    };
    match method {
        "playbackFlow.reportStep" => {
            use ocp_session::report::{Mode, Snapshot};
            let snapshot: Snapshot = serde_json::from_value(
                args.get("snapshot")
                    .cloned()
                    .ok_or("snapshot is required")?,
            )
            .map_err(|e| e.to_string())?;
            if !snapshot.valid() {
                return Err("invalid report position or duration".into());
            }
            let mode: Mode =
                serde_json::from_value(args.get("mode").cloned().ok_or("mode is required")?)
                    .map_err(|e| e.to_string())?;
            let ticks = args
                .get("ticks")
                .and_then(Value::as_u64)
                .ok_or("ticks is required")?;
            let reported_pause = args
                .get("reportedPause")
                .and_then(Value::as_bool)
                .ok_or("reportedPause is required")?;
            let every_ticks = args
                .get("everyTicks")
                .and_then(Value::as_u64)
                .filter(|v| *v > 0)
                .ok_or("everyTicks must be positive")?;
            Ok(json!(ocp_session::report::step(
                snapshot,
                mode,
                ticks,
                reported_pause,
                every_ticks
            )))
        }
        "playbackFlow.classify" => {
            let message = args
                .get("message")
                .and_then(Value::as_str)
                .ok_or("message is required")?;
            let kind = OpenFailureKind::classify(message);
            Ok(
                json!({"kind":kind,"isRetryable":kind.is_retryable(),"allowsSourceFailover":kind.allows_source_failover()}),
            )
        }
        "playbackFlow.capabilities" => {
            let kind: OpenFailureKind =
                serde_json::from_value(args.get("kind").cloned().ok_or("kind is required")?)
                    .map_err(|e| e.to_string())?;
            Ok(
                json!({"isRetryable":kind.is_retryable(),"allowsSourceFailover":kind.allows_source_failover(),"maximumSourceFailovers":ocp_session::flow::MAXIMUM_SOURCE_FAILOVERS}),
            )
        }
        "playbackFlow.begin" => {
            let id = request_id()?.to_owned();
            let source_id = match args.get("sourceId") {
                None | Some(Value::Null) => None,
                Some(Value::String(id)) => Some(id.clone()),
                _ => return Err("sourceId must be a string or null".into()),
            };
            let alternates: Vec<Alternate> =
                serde_json::from_value(args.get("alternates").cloned().unwrap_or(json!([])))
                    .map_err(|e| e.to_string())?;
            if alternates
                .iter()
                .any(|alternate| alternate.id.trim().is_empty())
            {
                return Err("alternate id must not be empty".into());
            }
            state.playback_flow.begin(id, source_id, alternates);
            Ok(json!(state.playback_flow.snapshot()))
        }
        "playbackFlow.snapshot" => Ok(json!(state.playback_flow.snapshot())),
        "playbackFlow.invalidate" => {
            state.playback_flow.invalidate();
            Ok(json!(state.playback_flow.snapshot()))
        }
        "playbackFlow.failed" => {
            let id = request_id()?;
            let kind: OpenFailureKind =
                serde_json::from_value(args.get("kind").cloned().ok_or("kind is required")?)
                    .map_err(|e| e.to_string())?;
            let has_item = args
                .get("hasItem")
                .and_then(Value::as_bool)
                .ok_or("hasItem is required")?;
            Ok(json!(state.playback_flow.fail(id, kind, has_item)))
        }
        "playbackFlow.adopt" => {
            let id = request_id()?.to_owned();
            let from = args
                .get("fromPlaybackRequestId")
                .and_then(Value::as_str)
                .ok_or("fromPlaybackRequestId is required")?;
            let generation = args
                .get("generation")
                .and_then(Value::as_u64)
                .ok_or("generation is required")?;
            let source = args
                .get("sourceId")
                .and_then(Value::as_str)
                .ok_or("sourceId is required")?;
            let accepted = state.playback_flow.adopt(from, generation, id, source);
            Ok(json!({"accepted":accepted,"snapshot":state.playback_flow.snapshot()}))
        }
        _ => Err(format!("unknown method: {method}")),
    }
}

fn call_endpoint_policy(
    state: &mut State,
    method: &str,
    arguments: &Value,
) -> Result<Value, String> {
    use ocp_jellyfin::endpoint::{
        EndpointConfig, EndpointDirectory, EndpointOptions, EndpointProbeResult,
    };
    let options: EndpointOptions = arguments
        .get("options")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| format!("invalid endpoint options: {error}"))?
        .unwrap_or_default();
    options.validate()?;
    let now = match arguments.get("now") {
        Some(value) => value
            .as_f64()
            .filter(|now| now.is_finite() && *now >= 0.0)
            .ok_or("invalid endpoint time")?,
        None => ocp_store::now_seconds(),
    };
    if method == "endpoint.initialize" {
        let config: EndpointConfig =
            serde_json::from_value(arguments.get("config").cloned().unwrap_or(Value::Null))
                .map_err(|error| format!("invalid endpoint config: {error}"))?;
        let directory = EndpointDirectory::new(config)?;
        let snapshot = json!(directory.snapshot());
        state.endpoint = Some(directory);
        return Ok(snapshot);
    }
    let directory = state
        .endpoint
        .as_mut()
        .ok_or("endpoint directory is not initialized")?;
    Ok(match method {
        "endpoint.current" => json!(directory.snapshot()),
        "endpoint.decision" => json!({"decision":directory.decision(now, &options)}),
        "endpoint.begin" => json!(directory.begin()),
        "endpoint.invalidate" => {
            directory.invalidate();
            json!(directory.snapshot())
        }
        "endpoint.sync" => {
            let config =
                serde_json::from_value(arguments.get("config").cloned().unwrap_or(Value::Null))
                    .map_err(|error| format!("invalid endpoint config: {error}"))?;
            json!(directory.sync(config)?)
        }
        "endpoint.failureGate" => {
            let failed = arguments
                .get("failedURL")
                .and_then(Value::as_str)
                .ok_or("failedURL is required")?;
            json!({"allowed":directory.failure_allowed(failed, now, &options)})
        }
        "endpoint.apply" => {
            let generation = arguments
                .get("generation")
                .and_then(Value::as_u64)
                .ok_or("generation must be an unsigned integer")?;
            let results: Vec<EndpointProbeResult> =
                serde_json::from_value(arguments.get("results").cloned().unwrap_or(Value::Null))
                    .map_err(|error| format!("invalid endpoint results: {error}"))?;
            json!(directory.apply(&results, generation, now, &options))
        }
        _ => return Err(format!("unknown endpoint method: {method}")),
    })
}

fn is_server_command(method: &str) -> bool {
    matches!(
        method,
        "server.probe"
            | "server.login"
            | "server.loginQuickConnect"
            | "server.quickConnect.initiate"
            | "server.quickConnect.state"
            | "server.quickConnect.wait"
            | "server.list"
            | "server.libraries"
            | "browse.home"
            | "browse.latest"
            | "browse.resume"
            | "browse.nextUp"
            | "browse.random"
            | "browse.played"
            | "browse.library"
            | "browse.detail"
            | "browse.chapters"
            | "browse.seasons"
            | "browse.episodes"
            | "browse.similar"
            | "playback.info"
            | "media.segments"
            | "media.subtitles"
            | "media.fileInfo"
            | "server.avatarTag"
            | "server.userImageURL"
            | "report.start"
            | "report.progress"
            | "report.stopped"
            | "server.markPlayed"
            | "server.markUnplayed"
    )
}

fn is_domain_command(method: &str) -> bool {
    matches!(
        method,
        "tmdb.search"
            | "tmdb.entity"
            | "tmdb.season"
            | "danmaku.load"
            | "danmaku.exchange"
            | "bangumi.request"
            | "bangumi.subject"
            | "bangumi.search"
            | "bangumi.episodes"
            | "bangumi.calendar"
            | "bangumi.collections"
            | "bangumi.subjectCollection"
            | "bangumi.updateSubject"
            | "bangumi.updateEpisode"
    )
}

fn is_moviepilot_command(method: &str) -> bool {
    matches!(
        method,
        "moviepilot.login"
            | "moviepilot.request"
            | "moviepilot.currentUser"
            | "moviepilot.mediaSearch"
            | "moviepilot.sites"
            | "moviepilot.torrentSearch"
            | "moviepilot.download.add"
            | "moviepilot.download.list"
            | "moviepilot.download.start"
            | "moviepilot.download.stop"
            | "moviepilot.download.remove"
            | "moviepilot.subscription.list"
            | "moviepilot.subscription.add"
            | "moviepilot.subscription.update"
            | "moviepilot.subscription.delete"
            | "moviepilot.subscription.deleteByMedia"
            | "moviepilot.subscription.refresh"
            | "moviepilot.subscription.search"
    )
}

fn run_server_command(
    service: &network::NetworkService,
    method: &str,
    arguments: &Value,
    cancelled: Option<Arc<AtomicBool>>,
) -> Result<Value, (i32, bool, String)> {
    let method = method.to_owned();
    let arguments = arguments.clone();
    let profile_value = arguments.get("profile").cloned().unwrap_or(Value::Null);
    let profile: ocp_jellyfin::ServerProfile = serde_json::from_value(profile_value)
        .map_err(|error| (1002, false, format!("invalid profile: {error}")))?;
    let http = service.http();
    service.run(cancellable(cancelled, async move {
            use ocp_jellyfin::MediaServerClient;
            let client = MediaServerClient::with_http(profile, http);
            let result = match method.as_str() {
                "server.probe" => Ok(encode_value(client.probe().await?)?),
                "server.loginQuickConnect" => Ok(encode_value(client.login_quick_connect(required_str(&arguments, "secret")?).await?)?),
                "server.quickConnect.initiate" => Ok(encode_value(client.quick_connect_initiate().await?)?),
                "server.quickConnect.state" => Ok(encode_value(client.quick_connect_state(required_str(&arguments, "secret")?).await?)?),
                "server.quickConnect.wait" => {
                    let secret = required_str(&arguments, "secret")?;
                    let interval = match arguments.get("pollInterval") {
                        None => 3.0,
                        Some(value) => value.as_f64().filter(|v| v.is_finite() && *v > 0.0 && *v <= 60.0)
                            .ok_or_else(|| CommandError::invalid("pollInterval must be in (0, 60] seconds"))?,
                    };
                    let bounded = |key: &str, default: u32, min: u32, max: u32| -> Result<u32, CommandError> {
                        match arguments.get(key) {
                            None => Ok(default),
                            Some(value) => value.as_u64().filter(|v| *v >= u64::from(min) && *v <= u64::from(max))
                                .map(|v| v as u32).ok_or_else(|| CommandError::invalid(format!("{key} must be an integer in [{min}, {max}]"))),
                        }
                    };
                    let max = bounded("maxPolls", 60, 1, 1000)?;
                    let tolerance = bounded("failureTolerance", 5, 0, 100)?;
                    Ok(encode_value(client.quick_connect_wait(secret, std::time::Duration::from_secs_f64(interval), max, tolerance).await?)?)
                }
                "server.login" => {
                    let username = arguments
                        .get("username")
                        .and_then(Value::as_str)
                        .ok_or_else(|| CommandError::invalid("username is required"))?;
                    let password = arguments
                        .get("password")
                        .and_then(Value::as_str)
                        .ok_or_else(|| CommandError::invalid("password is required"))?;
                    Ok(encode_value(client.login(username, password).await?)?)
                }
                "server.list" | "server.libraries" => Ok(encode_value(client.libraries().await?)?),
                "browse.latest" | "browse.resume" | "browse.nextUp" | "browse.random" => {
                    let limit = arguments.get("limit").and_then(Value::as_i64).unwrap_or(24).clamp(1, 100) as i32;
                    let items = match method.as_str() {
                        "browse.latest" => client.latest_items(limit).await?,
                        "browse.resume" => client.resume_items(limit).await?,
                        "browse.nextUp" => client.next_up(limit).await?,
                        _ => client.random_items(limit).await?,
                    };
                    Ok(encode_value(items)?)
                }
                "browse.home" => {
                    let (libraries, resume, next_up, latest, random) = tokio::join!(
                        client.libraries(),
                        client.resume_items(24),
                        client.next_up(24),
                        client.latest_items(24),
                        client.random_items(8),
                    );
                    let mut failures = serde_json::Map::new();
                    let libraries = home_part("libraries", libraries, &mut failures);
                    let resume = home_part("resume", resume, &mut failures);
                    let next_up = home_part("nextUp", next_up, &mut failures);
                    let latest = home_part("latest", latest, &mut failures);
                    let random = home_part("random", random, &mut failures);
                    Ok(json!({ "libraries": libraries, "resume": resume, "nextUp": next_up, "latest": latest, "random": random, "failures": failures }))
                }
                "browse.played" => {
                    let start = arguments.get("startIndex").and_then(Value::as_i64).unwrap_or(0).max(0).min(i32::MAX as i64) as i32;
                    let limit = arguments.get("limit").and_then(Value::as_i64).unwrap_or(50).clamp(1, 500) as i32;
                    Ok(encode_value(client.played_items_page(start, limit).await?)?)
                }
                "browse.library" => {
                    let start = arguments
                        .get("startIndex")
                        .and_then(Value::as_i64)
                        .unwrap_or(0);
                    let limit = arguments.get("limit").and_then(Value::as_i64).unwrap_or(50);
                    if start < 0 || limit <= 0 || start > i32::MAX as i64 || limit > 500 {
                        return Err(CommandError::invalid(
                            "startIndex must be non-negative and limit must be between 1 and 500",
                        ));
                    }
                    let query: ocp_jellyfin::ItemsQuery = serde_json::from_value(arguments.clone())
                        .map_err(|error| CommandError::invalid(format!("invalid browse query: {error}")))?;
                    Ok(encode_value(client.items_page_filtered(&query).await?)?)
                }

                "browse.detail" => {
                    let id = required_str(&arguments, "itemId")?;
                    Ok(encode_value(client.item(id).await?)?)
                }
                "browse.chapters" => {
                    let id = required_str(&arguments, "itemId")?;
                    let value = client
                        .raw_get(
                            &format!("Items/{id}"),
                            vec![("fields", "Chapters".into())],
                        )
                        .await?;
                    Ok(json!({ "chapters": value.get("Chapters").cloned().unwrap_or_else(|| json!([])) }))
                }
                "browse.seasons" => {
                    let series_id = required_str(&arguments, "seriesId")?;
                    let query = ocp_jellyfin::ItemsQuery {
                        parent_id: Some(series_id.to_owned()),
                        kinds: Some(vec!["season".into()]),
                        recursive: false,
                        start_index: 0,
                        limit: arguments.get("limit").and_then(Value::as_i64).unwrap_or(500).clamp(1, 500) as i32,
                        ..Default::default()
                    };
                    Ok(encode_value(client.items_page_filtered(&query).await?.items)? )
                }
                "browse.episodes" => {
                    let series_id = required_str(&arguments, "seriesId")?;
                    let parent_id = arguments.get("seasonId").and_then(Value::as_str).unwrap_or(series_id);
                    let query = ocp_jellyfin::ItemsQuery {
                        parent_id: Some(parent_id.to_owned()),
                        kinds: Some(vec!["episode".into()]),
                        recursive: false,
                        start_index: arguments.get("startIndex").and_then(Value::as_i64).unwrap_or(0).max(0) as i32,
                        limit: arguments.get("limit").and_then(Value::as_i64).unwrap_or(500).clamp(1, 500) as i32,
                        ..Default::default()
                    };
                    Ok(encode_value(client.items_page_filtered(&query).await?.items)? )
                }
                "browse.similar" => {
                    let id = required_str(&arguments, "itemId")?;
                    let value = client
                        .raw_get(
                            &format!("Items/{id}/Similar"),
                            vec![
                                ("limit", arguments.get("limit").and_then(Value::as_i64).unwrap_or(12).clamp(1, 100).to_string()),
                                ("fields", ocp_jellyfin::MEDIA_LIST_FIELDS.into()),
                            ],
                        )
                        .await?;
                    Ok(json!({ "items": value.get("Items").cloned().unwrap_or_else(|| json!([])) }))
                }
                "playback.info" => {
                    let id = required_str(&arguments, "itemId")?;
                    Ok(encode_value(client.playback_info(id).await?)?)
                }
                "media.segments" => {
                    let id = required_str(&arguments, "itemId")?;
                    let value = client
                        .raw_get(
                            &format!("MediaSegments/{id}"),
                            vec![("includeSegmentTypes", "Intro,Outro".into())],
                        )
                        .await?;
                    Ok(json!({ "items": value.get("Items").cloned().unwrap_or_else(|| json!([])) }))
                }
                "media.subtitles" => {
                    let id = required_str(&arguments, "itemId")?;
                    let mut params = vec![("ids", id.to_owned()), ("fields", "MediaSources".into())];
                    if let Some(source_id) = arguments.get("mediaSourceId").and_then(Value::as_str) {
                        params.push(("mediaSourceId", source_id.to_owned()));
                    }
                    let value = client.raw_get("Items", params).await?;
                    Ok(value)
                }
                "media.fileInfo" => {
                    let id = required_str(&arguments, "itemId")?;
                    let value = client
                        .raw_get("Items", vec![("ids", id.to_owned()), ("fields", "MediaSources".into())])
                        .await?;
                    Ok(value)
                }
                "server.avatarTag" => {
                    let user = client.current_user().await?;
                    Ok(json!({ "tag": user.get("PrimaryImageTag").or_else(|| user.get("primaryImageTag")).cloned() }))
                }
                "server.userImageURL" => {
                    let url = ocp_jellyfin::user_image_url(
                        &client.profile,
                        arguments.get("tag").and_then(Value::as_str),
                    )?;
                    Ok(json!({ "url": url.map(|value| value.to_string()) }))
                }
                "report.start" | "report.progress" | "report.stopped" => {
                    let id = required_str(&arguments, "itemId")?;
                    let position = arguments
                        .get("positionSeconds")
                        .and_then(Value::as_f64)
                        .filter(|value| value.is_finite() && *value >= 0.0)
                        .ok_or_else(|| {
                            CommandError::invalid(
                                "positionSeconds must be a non-negative finite number",
                            )
                        })?;
                    let source_id = arguments.get("mediaSourceId").and_then(Value::as_str);
                    let session_id = arguments.get("playSessionId").and_then(Value::as_str);
                    let result = match method.as_str() {
                        "report.start" => {
                            client
                                .report_playback_start(
                                    id,
                                    source_id,
                                    session_id,
                                    position,
                                    arguments
                                        .get("playMethod")
                                        .and_then(Value::as_str)
                                        .unwrap_or("DirectPlay"),
                                )
                                .await
                        }
                        "report.progress" => {
                            client
                                .report_playback_progress(
                                    id,
                                    source_id,
                                    session_id,
                                    position,
                                    arguments
                                        .get("playMethod")
                                        .and_then(Value::as_str)
                                        .unwrap_or("DirectPlay"),
                                    arguments
                                        .get("paused")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false),
                                )
                                .await
                        }
                        _ => {
                            client
                                .report_playback_stopped(id, source_id, session_id, position)
                                .await
                        }
                    };
                    result?;
                    Ok(json!({ "reported": true }))
                }
                "server.markPlayed" | "server.markUnplayed" => {
                    let id = required_str(&arguments, "itemId")?;
                    let state = if method.as_str() == "server.markPlayed" {
                        client.mark_played(id).await?
                    } else {
                        client.mark_unplayed(id).await?
                    };
                    Ok(json!({ "playState": state }))
                }
                _ => unreachable!("server command dispatch is exhaustive"),
            };
            result
    })).map_err(CommandError::into_tuple)
}

fn run_domain_command(
    service: &network::NetworkService,
    method: &str,
    arguments: &Value,
    cancelled: Option<Arc<AtomicBool>>,
) -> Result<Value, (i32, bool, String)> {
    let method = method.to_owned();
    let arguments = arguments.clone();
    let http = service.http();
    service
        .run(cancellable(cancelled, async move {
            match method.as_str() {
                "tmdb.search" | "tmdb.entity" | "tmdb.season" => {
                    let api_key = required_str(&arguments, "apiKey")?;
                    let language = arguments
                        .get("language")
                        .and_then(Value::as_str)
                        .unwrap_or("en-US");
                    let api_base = arguments
                        .get("apiBase")
                        .and_then(Value::as_str)
                        .unwrap_or("https://api.themoviedb.org/3");
                    let client = ocp_tmdb::TmdbClient::with_http(api_key, api_base, http.clone());
                    let media_type: ocp_tmdb::MediaType = arguments
                        .get("mediaType")
                        .cloned()
                        .map(serde_json::from_value)
                        .transpose()
                        .map_err(|error| {
                            CommandError::invalid(format!("invalid mediaType: {error}"))
                        })?
                        .unwrap_or(ocp_tmdb::MediaType::Movie);
                    let value = match method.as_str() {
                        "tmdb.search" => {
                            let query = required_str(&arguments, "query")?;
                            encode_value(
                                client
                                    .search(
                                        query,
                                        media_type,
                                        arguments
                                            .get("year")
                                            .and_then(Value::as_i64)
                                            .map(|value| value as i32),
                                        language,
                                    )
                                    .await?,
                            )?
                        }
                        "tmdb.entity" => {
                            let id = arguments
                                .get("id")
                                .and_then(Value::as_i64)
                                .filter(|id| *id > 0)
                                .ok_or_else(|| {
                                    CommandError::invalid("id must be a positive integer")
                                })?;
                            encode_value(client.entity(id, media_type, language).await?)?
                        }
                        _ => {
                            let id = arguments
                                .get("id")
                                .and_then(Value::as_i64)
                                .filter(|id| *id > 0)
                                .ok_or_else(|| {
                                    CommandError::invalid("id must be a positive integer")
                                })?;
                            let season = arguments
                                .get("seasonNumber")
                                .and_then(Value::as_i64)
                                .filter(|number| *number >= 0 && *number <= i32::MAX as i64)
                                .ok_or_else(|| {
                                    CommandError::invalid("seasonNumber must be non-negative")
                                })?;
                            encode_value(client.season(id, season as i32, language).await?)?
                        }
                    };
                    Ok(value)
                }
                "bangumi.request"
                | "bangumi.subject"
                | "bangumi.search"
                | "bangumi.episodes"
                | "bangumi.calendar"
                | "bangumi.collections"
                | "bangumi.subjectCollection"
                | "bangumi.updateSubject"
                | "bangumi.updateEpisode" => {
                    let base_url = arguments
                        .get("baseURL")
                        .and_then(Value::as_str)
                        .unwrap_or("https://api.bgm.tv/");
                    let client = ocp_bangumi::BangumiClient::with_http(
                        base_url,
                        arguments
                            .get("accessToken")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                        http.clone(),
                    )
                    .map_err(CommandError::from)?;
                    let value = match method.as_str() {
                        "bangumi.request" => {
                            let headers = arguments.get("headers").cloned().unwrap_or(json!({}));
                            let headers: HashMap<String, String> = serde_json::from_value(headers)
                                .map_err(|error| {
                                    CommandError::invalid(format!("invalid headers: {error}"))
                                })?;
                            client
                                .request(
                                    required_str(&arguments, "url")?,
                                    arguments
                                        .get("httpMethod")
                                        .and_then(Value::as_str)
                                        .unwrap_or("GET"),
                                    &headers,
                                    arguments
                                        .get("body")
                                        .cloned()
                                        .filter(|body| !body.is_null()),
                                )
                                .await?
                        }
                        "bangumi.subject" => {
                            let id = arguments
                                .get("subjectId")
                                .and_then(Value::as_i64)
                                .filter(|id| *id > 0)
                                .ok_or_else(|| {
                                    CommandError::invalid("subjectId must be positive")
                                })?;
                            encode_value(client.subject(id).await?)?
                        }
                        "bangumi.search" => encode_value(
                            client
                                .search_subjects(
                                    required_str(&arguments, "keyword")?,
                                    optional_i32_arg(&arguments, "subjectType")?,
                                    page_arg(&arguments, "limit", 30, 100)?,
                                    page_arg(&arguments, "offset", 0, i32::MAX as u32)?,
                                )
                                .await?,
                        )?,
                        "bangumi.episodes" => {
                            let id = arguments
                                .get("subjectId")
                                .and_then(Value::as_i64)
                                .filter(|id| *id > 0)
                                .ok_or_else(|| {
                                    CommandError::invalid("subjectId must be positive")
                                })?;
                            encode_value(
                                client
                                    .episodes(
                                        id,
                                        page_arg(&arguments, "limit", 100, 100)?,
                                        page_arg(&arguments, "offset", 0, i32::MAX as u32)?,
                                    )
                                    .await?,
                            )?
                        }
                        "bangumi.calendar" => encode_value(client.calendar().await?)?,
                        "bangumi.collections" => encode_value(
                            client
                                .collections(
                                    optional_i32_arg(&arguments, "collectionType")?,
                                    optional_i32_arg(&arguments, "subjectType")?,
                                    arguments.get("since").and_then(Value::as_i64).unwrap_or(0),
                                    page_arg(&arguments, "limit", 100, 100)?,
                                    page_arg(&arguments, "offset", 0, i32::MAX as u32)?,
                                )
                                .await?,
                        )?,
                        "bangumi.subjectCollection" => {
                            client
                                .subject_collection(
                                    positive_id_arg(&arguments, "subjectId")?,
                                    required_str(&arguments, "username")?,
                                )
                                .await?
                        }
                        "bangumi.updateSubject" => {
                            client
                                .update_subject_collection(
                                    positive_id_arg(&arguments, "subjectId")?,
                                    arguments
                                        .get("body")
                                        .cloned()
                                        .ok_or_else(|| CommandError::invalid("body is required"))?,
                                )
                                .await?;
                            json!({"updated": true})
                        }
                        _ => {
                            let id = arguments
                                .get("episodeId")
                                .and_then(Value::as_i64)
                                .filter(|id| *id > 0)
                                .ok_or_else(|| {
                                    CommandError::invalid("episodeId must be positive")
                                })?;
                            let kind = optional_i32_arg(&arguments, "collectionType")?.unwrap_or(2);
                            client
                                .update_episode_collection(
                                    id,
                                    kind,
                                    arguments
                                        .get("batch")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false),
                                )
                                .await?;
                            json!({"updated": true})
                        }
                    };
                    Ok(value)
                }
                "danmaku.exchange" => {
                    use base64::Engine;
                    let config: ocp_danmaku::GatewayConfig = serde_json::from_value(
                        arguments.get("gateway").cloned().unwrap_or(Value::Null),
                    )
                    .map_err(|e| CommandError::invalid(format!("invalid gateway config: {e}")))?;
                    let body = match arguments.get("bodyBase64") {
                        None | Some(Value::Null) => None,
                        Some(Value::String(value)) => Some(
                            base64::engine::general_purpose::STANDARD
                                .decode(value)
                                .map_err(|_| CommandError::invalid("invalid bodyBase64"))?,
                        ),
                        _ => return Err(CommandError::invalid("bodyBase64 must be a string")),
                    };
                    let timeout = match arguments.get("timeoutSeconds") {
                        None => 30.0,
                        Some(value) => value
                            .as_f64()
                            .ok_or_else(|| CommandError::invalid("invalid timeoutSeconds"))?,
                    };
                    let gateway = ocp_danmaku::DanmakuGateway::with_http(config, http.clone());
                    Ok(gateway
                        .exchange(
                            required_str(&arguments, "url")?,
                            required_str(&arguments, "httpMethod")?,
                            body,
                            timeout,
                        )
                        .await?)
                }
                "danmaku.load" => {
                    let config: ocp_danmaku::GatewayConfig = serde_json::from_value(
                        arguments.get("gateway").cloned().unwrap_or(Value::Null),
                    )
                    .map_err(|error| {
                        CommandError::invalid(format!("invalid gateway config: {error}"))
                    })?;
                    let request: ocp_danmaku::MatchRequest = serde_json::from_value(
                        arguments
                            .get("matchRequest")
                            .cloned()
                            .unwrap_or(Value::Null),
                    )
                    .map_err(|error| {
                        CommandError::invalid(format!("invalid matchRequest: {error}"))
                    })?;
                    let gateway = ocp_danmaku::DanmakuGateway::with_http(config, http.clone());
                    let matched = gateway.match_file(&request).await?;
                    let mut loaded = Vec::new();
                    for candidate in &matched.matches {
                        let response = gateway.comments(candidate.episode_id).await?;
                        let wire_comments = response
                            .comments
                            .unwrap_or_default()
                            .into_iter()
                            .map(|comment| ocp_danmaku::DanmakuWireComment {
                                cid: comment.cid,
                                p: comment.p,
                                m: comment.m,
                            })
                            .collect::<Vec<_>>();
                        let entries = ocp_danmaku::convert_comments(&wire_comments);
                        loaded.push(json!({
                            "candidate": candidate,
                            "count": entries.len(),
                            "comments": entries
                        }));
                    }
                    Ok(json!({ "match": matched, "episodes": loaded }))
                }
                _ => unreachable!("domain command dispatch is exhaustive"),
            }
        }))
        .map_err(CommandError::into_tuple)
}

fn run_moviepilot_command(
    service: &network::NetworkService,
    method: &str,
    arguments: &Value,
    state: Arc<Mutex<State>>,
    cancelled: Option<Arc<AtomicBool>>,
) -> Result<Value, (i32, bool, String)> {
    let method = method.to_owned();
    let arguments = arguments.clone();
    let base_url = arguments
        .get("baseURL")
        .or_else(|| arguments.get("baseUrl"))
        .or_else(|| arguments.get("serverURL"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| CommandError::invalid("baseURL is required"))
        .map_err(CommandError::into_tuple)?;
    let token = arguments
        .get("accessToken")
        .or_else(|| arguments.get("token"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let base_url = ocp_moviepilot::normalize_base_url(&base_url)
        .map_err(CommandError::from)
        .map_err(CommandError::into_tuple)?
        .to_string();
    let (pool, pool_generation) = service
        .moviepilot_pool(&base_url, token.as_deref(), method == "moviepilot.login")
        .map_err(CommandError::into_tuple)?;
    let sessions = service.moviepilot.clone();
    service.run(cancellable(cancelled, async move {
            let mut client =
                ocp_moviepilot::Client::with_http(&base_url, token, pool.http.clone(), pool.stream.clone()).map_err(CommandError::from)?;
            let value = match method.as_str() {
                "moviepilot.request" => {
                    use base64::Engine;
                    let headers: HashMap<String, String> = serde_json::from_value(arguments.get("headers").cloned().unwrap_or(json!({})))
                        .map_err(|_| CommandError::invalid("headers must be a string dictionary"))?;
                    let body = match arguments.get("bodyBase64") {
                        None | Some(Value::Null) => None,
                        Some(Value::String(body)) => Some(base64::engine::general_purpose::STANDARD.decode(body).map_err(|_| CommandError::invalid("invalid bodyBase64"))?),
                        _ => return Err(CommandError::invalid("bodyBase64 must be a string or null")),
                    };
                    let timeout = match arguments.get("timeout") {
                        None | Some(Value::Null) => None,
                        Some(value) => Some(value.as_f64().filter(|value| value.is_finite() && *value > 0.0)
                            .and_then(|value| std::time::Duration::try_from_secs_f64(value).ok())
                            .ok_or_else(|| CommandError::invalid("timeout must be a finite positive number"))?),
                    };
                    let response = client.raw_request(required_str(&arguments, "url")?, required_str(&arguments, "httpMethod")?, &headers, body, timeout).await?;
                    let status = response.status().as_u16();
                    let headers: HashMap<String, String> = response.headers().iter().filter_map(|(key, value)| value.to_str().ok().map(|value| (key.to_string(), value.to_owned()))).collect();
                    let bytes = response.bytes().await.map_err(|error| CommandError::from(ocp_moviepilot::MoviePilotError::Http(ocp_http::HttpError::Decode(error.without_url()))))?;
                    json!({"status": status, "headers": headers, "bodyBase64": base64::engine::general_purpose::STANDARD.encode(bytes)})
                }
                "moviepilot.login" => {
                    let validate_user = match arguments.get("validateUser") {
                        None => true,
                        Some(Value::Bool(value)) => *value,
                        _ => return Err(CommandError::invalid("validateUser must be boolean")),
                    };
                    let token = client.issue_token(required_str(&arguments, "username")?, required_str(&arguments, "password")?).await?;
                    let user = if validate_user { Some(client.current_user().await?) } else { None };
                    sessions.lock().map_err(|_| CommandError(1500, false, "session pool unavailable".into()))?.publish_login(pool_generation, base_url.clone(), token.clone(), pool);
                    json!({ "user": user, "accessToken": token })
                }
                "moviepilot.currentUser" => json!({ "user": client.current_user().await? }),
                "moviepilot.mediaSearch" => json!({
                    "items": client.search_media(required_str(&arguments, "title")?).await?
                }),
                "moviepilot.sites" => json!({ "items": client.sites().await? }),
                "moviepilot.torrentSearch" => {
                    let sites = arguments
                        .get("sites")
                        .and_then(Value::as_array)
                        .map(|values| values.iter().filter_map(Value::as_i64).collect::<Vec<_>>())
                        .unwrap_or_default();
                    json!({ "items": client.search_torrents_with_updates(required_str(&arguments, "keyword")?, &sites, |update| {
                        if let Ok(mut state) = state.lock() {
                            // Each event is a full projection; keep the latest until the host polls.
                            let request_id = arguments.get("requestId").cloned().unwrap_or(Value::Null);
                            let mut data = json!(update);
                            data["requestId"] = request_id;
                            state.push_event("moviepilot.searchProgress", data);
                        }
                    }).await? })
                }
                "moviepilot.download.add" => {
                    client
                        .add_download(
                            arguments.get("media").cloned().or_else(|| arguments.get("mediaIn").cloned()).ok_or_else(|| CommandError::invalid("media is required"))?,
                            arguments.get("torrent").cloned().or_else(|| arguments.get("torrentIn").cloned()).ok_or_else(|| CommandError::invalid("torrent is required"))?,
                        )
                        .await?;
                    json!({ "accepted": true })
                }
                "moviepilot.download.list" => json!({ "items": client.downloading_tasks().await? }),
                "moviepilot.download.start" | "moviepilot.download.stop" => {
                    let action = if method.ends_with("start") { "start" } else { "stop" };
                    client.download_control(action, required_str(&arguments, "hash")?).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.download.remove" => {
                    client.remove_download(required_str(&arguments, "hash")?).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.list" => json!({ "items": client.subscriptions().await? }),
                "moviepilot.subscription.add" => {
                    client.add_subscription(arguments.get("subscription").cloned().or_else(|| arguments.get("body").cloned()).ok_or_else(|| CommandError::invalid("subscription is required"))?).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.update" => {
                    client.update_subscription(arguments.get("subscription").cloned().or_else(|| arguments.get("body").cloned()).ok_or_else(|| CommandError::invalid("subscription is required"))?).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.delete" => {
                    let id = arguments.get("id").and_then(Value::as_i64).ok_or_else(|| CommandError::invalid("id is required"))?;
                    client.delete_subscription(id).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.deleteByMedia" => {
                    client.delete_subscription_by_media(required_str(&arguments, "mediaId")?).await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.refresh" => {
                    client.refresh_subscriptions().await?;
                    json!({ "accepted": true })
                }
                "moviepilot.subscription.search" => {
                    client.search_subscriptions().await?;
                    json!({ "accepted": true })
                }
                _ => unreachable!("moviepilot command dispatch is exhaustive"),
            };
            Ok(value)
    })).map_err(CommandError::into_tuple)
}

fn encode_value(value: impl serde::Serialize) -> Result<Value, CommandError> {
    serde_json::to_value(value)
        .map_err(|error| CommandError::invalid(format!("response encoding failed: {error}")))
}

fn home_part<T: serde::Serialize>(
    name: &str,
    result: Result<T, ocp_jellyfin::JellyfinError>,
    failures: &mut serde_json::Map<String, Value>,
) -> Value {
    match result {
        Ok(value) => serde_json::to_value(value).unwrap_or(Value::Null),
        Err(error) => {
            failures.insert(name.to_string(), json!({ "message": error.to_string() }));
            Value::Null
        }
    }
}

fn required_str<'a>(arguments: &'a Value, key: &str) -> Result<&'a str, CommandError> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CommandError::invalid(format!("{key} is required")))
}

fn optional_i32_arg(arguments: &Value, key: &str) -> Result<Option<i32>, CommandError> {
    arguments
        .get(key)
        .map(|value| {
            value
                .as_i64()
                .and_then(|value| i32::try_from(value).ok())
                .ok_or_else(|| CommandError::invalid(format!("{key} must be a 32-bit integer")))
        })
        .transpose()
}
fn page_arg(arguments: &Value, key: &str, default: u32, maximum: u32) -> Result<u32, CommandError> {
    let value = match arguments.get(key) {
        Some(value) => value
            .as_u64()
            .filter(|value| *value <= u64::from(maximum))
            .map(|value| value as u32)
            .ok_or_else(|| CommandError::invalid(format!("invalid {key}")))?,
        None => default,
    };
    if key == "limit" && value == 0 {
        return Err(CommandError::invalid("limit must be positive"));
    }
    Ok(value)
}
fn positive_id_arg(arguments: &Value, key: &str) -> Result<i64, CommandError> {
    arguments
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| CommandError::invalid(format!("{key} must be positive")))
}

struct CommandError(i32, bool, String);
impl CommandError {
    fn invalid(message: impl Into<String>) -> Self {
        Self(1002, false, message.into())
    }
    fn into_tuple(self) -> (i32, bool, String) {
        (self.0, self.1, self.2)
    }
}
impl From<ocp_jellyfin::JellyfinError> for CommandError {
    fn from(error: ocp_jellyfin::JellyfinError) -> Self {
        let retryable = matches!(
            ocp_jellyfin::classify_http_error(&error),
            ocp_http::ErrorCategory::Timeout
                | ocp_http::ErrorCategory::RateLimited
                | ocp_http::ErrorCategory::Server
                | ocp_http::ErrorCategory::Transport
        );
        let code = match &error {
            ocp_jellyfin::JellyfinError::Unauthorized => 2001,
            ocp_jellyfin::JellyfinError::QuickConnectDisabled => 2401,
            ocp_jellyfin::JellyfinError::QuickConnectTimeout => 2402,
            ocp_jellyfin::JellyfinError::InvalidProfile(_) => 1002,
            ocp_jellyfin::JellyfinError::Http(ocp_http::HttpError::Request {
                status: Some(status),
                ..
            }) => 1600 + i32::from(*status),
            ocp_jellyfin::JellyfinError::Http(ocp_http::HttpError::Decode(error))
                if error.is_timeout() =>
            {
                1521
            }
            ocp_jellyfin::JellyfinError::Http(ocp_http::HttpError::Decode(error))
                if error.is_connect() =>
            {
                1522
            }
            _ if ocp_jellyfin::classify_http_error(&error)
                == ocp_http::ErrorCategory::Transport =>
            {
                1523
            }
            _ if ocp_jellyfin::classify_http_error(&error) == ocp_http::ErrorCategory::Decode => {
                1514
            }
            _ => 1502,
        };
        (code, retryable, error.to_string()).into()
    }
}
impl From<ocp_tmdb::TmdbError> for CommandError {
    fn from(error: ocp_tmdb::TmdbError) -> Self {
        let (code, retryable) = match &error {
            ocp_tmdb::TmdbError::NotConfigured | ocp_tmdb::TmdbError::InvalidEndpoint(_) => {
                (1002, false)
            }
            ocp_tmdb::TmdbError::Response(_) | ocp_tmdb::TmdbError::Json(_) => (1514, false),
            ocp_tmdb::TmdbError::Http(http) => match http {
                ocp_http::HttpError::Request {
                    status: Some(status),
                    ..
                } => (1600 + i32::from(*status), http.retryable()),
                _ if http.category() == Some(ocp_http::ErrorCategory::Decode) => (1514, false),
                _ => (1501, http.retryable()),
            },
        };
        Self(code, retryable, error.to_string())
    }
}
impl From<ocp_danmaku::DanmakuError> for CommandError {
    fn from(error: ocp_danmaku::DanmakuError) -> Self {
        let (code, retryable) = match &error {
            ocp_danmaku::DanmakuError::Request(_) | ocp_danmaku::DanmakuError::InvalidUrl(_) => {
                (1002, false)
            }
            ocp_danmaku::DanmakuError::Http(http) => match http.category() {
                Some(ocp_http::ErrorCategory::Timeout) => (1503, true),
                Some(ocp_http::ErrorCategory::Transport) => (1501, true),
                _ => (1502, http.retryable()),
            },
            _ => (1502, false),
        };
        Self(code, retryable, error.to_string())
    }
}
impl From<ocp_bangumi::BangumiError> for CommandError {
    fn from(error: ocp_bangumi::BangumiError) -> Self {
        let (code, retryable) = match &error {
            ocp_bangumi::BangumiError::Http(http) => {
                let code = match http {
                    ocp_http::HttpError::Request {
                        status: Some(status),
                        ..
                    } => 1600 + i32::from(*status),
                    ocp_http::HttpError::Decode(error) if error.is_timeout() => 1521,
                    ocp_http::HttpError::Decode(error) if error.is_connect() => 1522,
                    _ => 1523,
                };
                (code, http.retryable())
            }
            ocp_bangumi::BangumiError::Url(_) | ocp_bangumi::BangumiError::Request(_) => {
                (1002, false)
            }
            _ => (1514, false),
        };
        Self(code, retryable, error.to_string())
    }
}
impl From<ocp_moviepilot::MoviePilotError> for CommandError {
    fn from(error: ocp_moviepilot::MoviePilotError) -> Self {
        if error.is_authentication_failure() {
            return Self(1503, false, error.to_string());
        }
        if matches!(
            &error,
            ocp_moviepilot::MoviePilotError::Http(ocp_http::HttpError::Request {
                status: Some(403),
                ..
            })
        ) {
            return Self(1504, false, error.to_string());
        }
        if matches!(error, ocp_moviepilot::MoviePilotError::Invalid(_)) {
            return Self::invalid(error.to_string());
        }

        let (code, retryable) = match &error {
            ocp_moviepilot::MoviePilotError::Http(http) => {
                let code = match http {
                    ocp_http::HttpError::Request {
                        status: Some(status),
                        ..
                    } => 1600 + i32::from(*status),
                    _ if http.category() == Some(ocp_http::ErrorCategory::Timeout) => 1521,
                    ocp_http::HttpError::Decode(error) if error.is_connect() => 1522,
                    _ => 1523,
                };
                (code, http.retryable())
            }
            ocp_moviepilot::MoviePilotError::Url(_) => (1002, false),
            ocp_moviepilot::MoviePilotError::Json(_) => (1514, false),
            _ => (1502, false),
        };
        Self(code, retryable, error.to_string())
    }
}
impl From<(i32, bool, String)> for CommandError {
    fn from(value: (i32, bool, String)) -> Self {
        Self(value.0, value.1, value.2)
    }
}

fn number_arg(arguments: &Value, key: &str) -> Option<f64> {
    arguments
        .get(key)?
        .as_f64()
        .filter(|value| value.is_finite())
}

fn required_arg<'a>(arguments: &'a Value, key: &str) -> Result<&'a str, CoreError> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CoreError::StoreConfig(format!("{key} is required")))
}

fn open_bangumi_store(config: &CoreConfig) -> Result<Option<ocp_store::BangumiStore>, CoreError> {
    let path = if let Some(path) = config.bangumi_database_path.as_ref() {
        PathBuf::from(path)
    } else if let Some(directory) = config.data_directory.as_ref() {
        std::fs::create_dir_all(directory).map_err(|e| CoreError::StoreConfig(e.to_string()))?;
        PathBuf::from(directory).join("Bangumi.sqlite")
    } else {
        return Ok(None);
    };
    let path = path
        .to_str()
        .ok_or_else(|| CoreError::StoreConfig("invalid Bangumi path".into()))?;
    ocp_store::BangumiStore::open(path)
        .map(Some)
        .map_err(CoreError::Store)
}

fn open_config_store(config: &CoreConfig) -> Result<Option<ocp_store::Store>, CoreError> {
    if let Some(path) = config.media_database_path.as_deref() {
        ocp_store::Store::open(path)
            .map(Some)
            .map_err(CoreError::Store)
    } else {
        config.data_directory.as_deref().map(open_store).transpose()
    }
}

fn open_store(directory: &str) -> Result<ocp_store::Store, CoreError> {
    let path = PathBuf::from(directory);
    std::fs::create_dir_all(&path).map_err(|error| {
        CoreError::StoreConfig(format!("cannot create data directory: {error}"))
    })?;
    let database = path.join("Media.sqlite");
    let database = database
        .to_str()
        .ok_or_else(|| CoreError::StoreConfig("data directory path is not valid UTF-8".into()))?;
    ocp_store::Store::open(database).map_err(CoreError::Store)
}

fn error_response(code: i32, retryable: bool, message: impl Into<String>) -> String {
    serde_json::to_string(&ApiResponse::error(code, retryable, message, Value::Null))
        .expect("serializing an API response cannot fail")
}

fn redact_config(config: &mut Value) {
    let Some(object) = config.as_object_mut() else {
        return;
    };
    // Keep the diagnostics schema useful while avoiding accidental disclosure of
    // credentials if future config fields are added by a platform adapter.
    for key in [
        "token",
        "accessToken",
        "password",
        "apiKey",
        "clientSecret",
        "refreshToken",
    ] {
        if object.contains_key(key) {
            object.insert(key.to_string(), Value::String("<redacted>".into()));
        }
    }
    if object.contains_key("bangumiDatabasePath") {
        object.insert(
            "bangumiDatabasePath".into(),
            Value::String("<redacted>".into()),
        );
    }
    if object.contains_key("mediaDatabasePath") {
        object.insert(
            "mediaDatabasePath".into(),
            Value::String("<redacted>".into()),
        );
    }
    if object.contains_key("dataDirectory") {
        object.insert("dataDirectory".into(), Value::String("<redacted>".into()));
    }
    if object.contains_key("data_directory") {
        object.insert("data_directory".into(), Value::String("<redacted>".into()));
    }
}

impl State {
    fn push_event(&mut self, kind: &str, data: Value) {
        self.events.push(kind, data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ocp_model::Event;

    #[test]
    fn unattended_render_and_position_updates_remain_bounded_and_observable() {
        let core = Arc::new(Core::new("{}").unwrap());
        core.call("playback.open", r#"{"source":"movie.mp4"}"#)
            .unwrap();
        core.call("playback.play", "{}").unwrap();
        core.attach_surface(1, 1920, 1080, 2.0, 0).unwrap();
        let workers = (0..4)
            .map(|worker| {
                let core = core.clone();
                std::thread::spawn(move || {
                    for index in 0..12_500 {
                        core.render_tick((worker * 12_500 + index) as f64 / 60.0)
                            .unwrap();
                    }
                })
            })
            .collect::<Vec<_>>();
        for position in 0..1_000 {
            core.call(
                "playback.position",
                &json!({"positionSeconds":position}).to_string(),
            )
            .unwrap();
        }
        for worker in workers {
            worker.join().unwrap();
        }
        core.call("playback.pause", "{}").unwrap();
        let diagnostics: Value =
            serde_json::from_str(&core.call("diag.snapshot", "{}").unwrap()).unwrap();
        let queue = &diagnostics["data"]["core"]["eventQueue"];
        assert_eq!(queue["depth"], 7);
        assert_eq!(queue["coalesced"], 50_998);
        assert_eq!(queue["dropped"], 0);
        assert!(queue["bytes"].as_u64().unwrap() <= events::MAX_EVENT_BYTES as u64);
        let mut last_sequence = 0;
        let mut kinds = Vec::new();
        while let Some(event) = core.poll_event().unwrap() {
            let event: Event = serde_json::from_str(&event).unwrap();
            assert!(event.sequence > last_sequence);
            last_sequence = event.sequence;
            if event.kind == "playback.position" {
                assert_eq!(event.data["positionSeconds"], 999.0);
            }
            kinds.push(event.kind);
        }
        assert!(kinds.contains(&"playback.play".to_owned()));
        assert_eq!(kinds.last().unwrap(), "playback.pause");
        assert_eq!(core.state.lock().unwrap().events.diagnostics()["bytes"], 0);
        let snapshot: Value = serde_json::from_str(&core.snapshot("playback").unwrap()).unwrap();
        assert_eq!(snapshot["positionSeconds"], 999.0);
        assert_eq!(snapshot["state"], "paused");
    }

    #[test]
    fn prepared_cancellation_prevents_dispatch_and_releases_request_id() {
        let core = Core::new("{}").unwrap();
        let control = r#"{"requestId":"cancel-before-dispatch"}"#;
        core.call("request.prepare", control).unwrap();
        let duplicate: Value =
            serde_json::from_str(&core.call("request.prepare", control).unwrap()).unwrap();
        assert_eq!(duplicate["code"], 1002);
        core.call("request.cancel", control).unwrap();
        // No profile is needed: a pre-cancelled operation cannot reach validation/networking.
        let response: Value =
            serde_json::from_str(&core.call("browse.latest", control).unwrap()).unwrap();
        assert_eq!(response["code"], 1003);
        assert!(core.requests.lock().unwrap().is_empty());
        let unknown: Value =
            serde_json::from_str(&core.call("request.cancel", control).unwrap()).unwrap();
        assert_eq!(unknown["data"]["cancelled"], false);
    }

    #[tokio::test]
    async fn cancellation_drops_in_flight_future() {
        struct OnDrop(Arc<AtomicBool>);
        impl Drop for OnDrop {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        let dropped = Arc::new(AtomicBool::new(false));
        let running = cancellable(Some(cancelled.clone()), async {
            let _guard = OnDrop(dropped.clone());
            std::future::pending::<()>().await;
            Ok(())
        });
        let cancel = async {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            cancelled.store(true, Ordering::Release);
        };
        let (result, _) = tokio::join!(running, cancel);
        assert!(matches!(result, Err(CommandError(1003, false, _))));
        assert!(dropped.load(Ordering::Acquire));
    }

    #[test]
    fn bangumi_rejects_invalid_pagination_and_types_before_network() {
        let core = Core::new("{}").unwrap();
        for (method, args) in [
            (
                "bangumi.search",
                json!({"keyword":"test", "limit":4294967297u64}),
            ),
            ("bangumi.search", json!({"keyword":"test", "limit":0})),
            (
                "bangumi.episodes",
                json!({"subjectId":1, "offset":4294967296u64}),
            ),
            (
                "bangumi.collections",
                json!({"accessToken":"test", "limit":-1}),
            ),
            (
                "bangumi.updateEpisode",
                json!({"episodeId":1,"collectionType":4294967298u64}),
            ),
            (
                "bangumi.subjectCollection",
                json!({"subjectId":1,"username":"-","accessToken":"test"}),
            ),
            ("bangumi.request", json!({"url":"file:///tmp/test"})),
        ] {
            let response: Value =
                serde_json::from_str(&core.call(method, &args.to_string()).unwrap()).unwrap();
            assert_eq!(response["code"], 1002, "{method}: {response}");
        }
    }

    #[test]
    fn creates_core_and_emits_ready_event() {
        let core = Core::new("{}").unwrap();
        let event = core.poll_event().unwrap().unwrap();
        assert!(event.contains("core.ready"));
    }

    #[test]
    fn endpoint_contract_rejects_bad_arguments_without_changing_policy() {
        let core = Core::new("{}").unwrap();
        let invoke = |method: &str, args: Value| -> Value {
            serde_json::from_str(&core.call(method, &args.to_string()).unwrap()).unwrap()
        };
        assert_eq!(invoke("endpoint.current", json!({}))["code"], 1002);
        assert_eq!(
            invoke(
                "endpoint.initialize",
                json!({"config":{"baseURL":"http://lan/emby","candidates":["http://lan/emby"]}})
            )["ok"],
            true
        );
        let before = invoke("endpoint.current", json!({}))["data"].clone();
        for (method, args) in [
            ("endpoint.decision", json!({"options":{"cacheTtl":-1}})),
            (
                "endpoint.sync",
                json!({"config":{"baseURL":"file:///tmp/test","candidates":[]}}),
            ),
            ("endpoint.apply", json!({"generation":-1,"results":[]})),
            ("endpoint.failureGate", json!({"failedURL":42})),
            ("endpoint.begin", json!({"now":"100"})),
        ] {
            assert_eq!(invoke(method, args)["code"], 1002);
            assert_eq!(invoke("endpoint.current", json!({}))["data"], before);
        }
        for args in [
            json!({"url":"file:///tmp/test"}),
            json!({"url":"http://127.0.0.1:9","timeout":0}),
            json!({"url":"http://127.0.0.1:9","authorizationHeader":42}),
        ] {
            assert_eq!(invoke("endpoint.probe", args)["code"], 1002);
        }
    }

    #[test]
    fn ping_is_json_response() {
        let core = Core::new("").unwrap();
        let value: Value = serde_json::from_str(&core.call("ping", "{}").unwrap()).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["pong"], true);
    }

    #[test]
    fn event_sequence_is_monotonic() {
        let core = Core::new("").unwrap();
        core.call("playback.open", r#"{"source":"movie.mp4"}"#)
            .unwrap();
        core.call("playback.play", "{}").unwrap();
        let first: Event = serde_json::from_str(&core.poll_event().unwrap().unwrap()).unwrap();
        let second: Event = serde_json::from_str(&core.poll_event().unwrap().unwrap()).unwrap();
        assert!(second.sequence > first.sequence);
    }

    #[test]
    fn playback_commands_update_state_and_snapshot() {
        let core = Core::new("").unwrap();
        core.call("playback.open", r#"{"source":"movie.mp4"}"#)
            .unwrap();
        core.call("playback.play", "{}").unwrap();
        core.call("playback.pause", "{}").unwrap();
        core.call("playback.seek", r#"{"positionSeconds":42.5}"#)
            .unwrap();
        core.call("playback.position", r#"{"positionSeconds":43.25}"#)
            .unwrap();
        core.call("playback.setRate", r#"{"rate":1.5}"#).unwrap();
        let snapshot: Value = serde_json::from_str(&core.snapshot("playback").unwrap()).unwrap();
        assert_eq!(snapshot["state"], "paused");
        assert_eq!(snapshot["positionSeconds"], 43.25);
        assert_eq!(snapshot["rate"], 1.5);
    }

    #[test]
    fn playback_settings_survive_timeline_and_lifecycle_updates() {
        let core = Core::new("{}").unwrap();
        for (method, args) in [
            ("playback.open", json!({"source":"movie.mp4"})),
            ("playback.ready", json!({"durationSeconds":120})),
            ("playback.setRate", json!({"rate":2})),
            ("playback.setVolume", json!({"volume":0.4})),
            ("playback.selectAudio", json!({"trackId":"audio-2"})),
            ("playback.selectSubtitle", json!({"trackId":"subtitle-3"})),
            ("playback.play", json!({})),
            (
                "playback.position",
                json!({"positionSeconds":25,"durationSeconds":125}),
            ),
            ("playback.pause", json!({})),
            ("playback.seek", json!({"positionSeconds":130})),
            ("playback.play", json!({})),
            ("playback.ended", json!({})),
        ] {
            let response: Value =
                serde_json::from_str(&core.call(method, &args.to_string()).unwrap()).unwrap();
            assert_eq!(response["ok"], true, "{method}: {response}");
        }
        let snapshot: Value = serde_json::from_str(&core.snapshot("playback").unwrap()).unwrap();
        assert_eq!(snapshot["rate"], 2.0);
        assert_eq!(snapshot["volume"], 0.4);
        assert_eq!(snapshot["audioTrack"], "audio-2");
        assert_eq!(snapshot["subtitleTrack"], "subtitle-3");
        assert_eq!(snapshot["durationSeconds"], 125.0);
        assert_eq!(snapshot["positionSeconds"], 125.0);
        assert_eq!(snapshot["state"], "ended");
    }

    #[test]
    fn playback_argument_errors_do_not_mutate_session_and_ready_can_pause() {
        let core = Core::new("{}").unwrap();
        for method in ["playback.ready", "playback.ended"] {
            let response: Value = serde_json::from_str(&core.call(method, "{}").unwrap()).unwrap();
            assert_eq!(response["code"], 1101);
        }
        let empty: Value = serde_json::from_str(
            &core
                .call("playback.open", r#"{"source":"movie.mp4","candidates":[]}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(empty["code"], 1002);
        core.call("playback.open", r#"{"source":"movie.mp4"}"#)
            .unwrap();
        core.call("playback.pause", "{}").unwrap();
        let before = core.snapshot("playback").unwrap();
        for (method, args) in [
            ("playback.ready", json!({"durationSeconds":-1})),
            (
                "playback.position",
                json!({"positionSeconds":25,"durationSeconds":"120"}),
            ),
            (
                "playback.seek",
                json!({"positionSeconds":25,"durationSeconds":false}),
            ),
            ("playback.selectAudio", json!({"trackId":42})),
            ("playback.selectSubtitle", json!({"trackId":false})),
        ] {
            let response: Value =
                serde_json::from_str(&core.call(method, &args.to_string()).unwrap()).unwrap();
            assert_eq!(response["code"], 1002);
            assert_eq!(core.snapshot("playback").unwrap(), before);
        }
        assert!(before.contains("\"state\":\"paused\""));
    }

    #[test]
    fn invalid_transitions_and_values_return_error_envelopes() {
        let core = Core::new("").unwrap();
        let response: Value =
            serde_json::from_str(&core.call("playback.play", "{}").unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["code"], 1101);
        let response: Value = serde_json::from_str(
            &core
                .call("playback.setVolume", r#"{"volume":2.0}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["code"], 1002);
        assert!(core
            .snapshot("playback")
            .unwrap()
            .contains("\"state\":\"idle\""));
    }

    #[test]
    fn persists_progress_when_data_directory_is_configured() {
        let directory = std::env::temp_dir().join(format!(
            "ocplayer-core-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let config = serde_json::json!({"data_directory": directory});
        let core = Core::new(&config.to_string()).unwrap();
        let response: Value = serde_json::from_str(&core.call(
            "progress.save",
            r#"{"tenantId":"server-1","itemId":"item-1","positionSeconds":12.5,"played":false,"recordedAt":100}"#,
        ).unwrap()).unwrap();
        assert_eq!(response["ok"], true);
        let response: Value = serde_json::from_str(
            &core
                .call(
                    "progress.get",
                    r#"{"tenantId":"server-1","itemId":"item-1"}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["data"]["progress"]["positionSeconds"], 12.5);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn network_commands_validate_before_requesting() {
        let core = Core::new("").unwrap();
        let response: Value =
            serde_json::from_str(&core.call("tmdb.search", r#"{"query":"test"}"#).unwrap())
                .unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["code"], 1002);
        let response: Value =
            serde_json::from_str(&core.call("server.probe", r#"{"profile":{}}"#).unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["code"], 1002);
        let response: Value = serde_json::from_str(
            &core
                .call("moviepilot.mediaSearch", r#"{"title":"test"}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["code"], 1002);
    }

    #[test]
    fn shared_cache_survives_locale_settings_and_reports_validation_errors() {
        let core = Core::new(r#"{"mediaDatabasePath":":memory:"}"#).unwrap();
        let call = |method: &str, args: &str| -> Value {
            serde_json::from_str(&core.call(method, args).unwrap()).unwrap()
        };
        let saved = call(
            "cache.saveItems",
            r#"{"tenantId":"t","items":[{"id":"one","name":"Movie","kind":"movie"}],"now":10,"requestStartedAt":9}"#,
        );
        assert_eq!(saved["ok"], true);
        assert_eq!(
            call("settings.set", r#"{"config":{"locale":"zh-CN"}}"#)["ok"],
            true
        );
        assert_eq!(
            call("cache.item", r#"{"tenantId":"t","itemId":"one"}"#)["data"]["payload"]["name"],
            "Movie"
        );
        assert_eq!(
            call("config.import", r#"{"config":{"locale":"en-US"}}"#)["ok"],
            true
        );
        assert_eq!(call("cache.itemCount", r#"{"tenantId":"t"}"#)["data"], 1);
        assert_eq!(call("cache.item", r#"{"itemId":"one"}"#)["code"], 1002);
        assert_eq!(
            call("diag.snapshot", r#"{"redact":true}"#)["data"]["config"]["mediaDatabasePath"],
            "<redacted>"
        );
        let unconfigured = Core::new("").unwrap();
        let error: Value =
            serde_json::from_str(&unconfigured.call("cache.itemCount", "{}").unwrap()).unwrap();
        assert_eq!(error["code"], 1401);
    }

    #[test]
    fn diagnostics_and_config_commands_are_versioned_and_redacted() {
        let directory =
            std::env::temp_dir().join(format!("ocplayer-core-diag-{}", std::process::id()));
        let config = serde_json::json!({
            "dataDirectory": directory,
            "locale": "zh-CN"
        });
        let core = Core::new(&config.to_string()).unwrap();
        let exported: Value =
            serde_json::from_str(&core.call("config.export", "{}").unwrap()).unwrap();
        assert_eq!(exported["data"]["schemaVersion"], 1);
        assert_eq!(exported["data"]["config"]["locale"], "zh-CN");

        let diagnostics: Value =
            serde_json::from_str(&core.call("diag.snapshot", r#"{"redact":true}"#).unwrap())
                .unwrap();
        assert_eq!(diagnostics["data"]["schemaVersion"], 1);
        assert_eq!(diagnostics["data"]["config"]["dataDirectory"], "<redacted>");
        assert!(diagnostics["data"]["generatedAt"].as_f64().unwrap() > 0.0);

        let imported: Value = serde_json::from_str(
            &core
                .call("config.import", r#"{"config":{"locale":"ja-JP"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(imported["data"]["config"]["locale"], "ja-JP");
        let _ = std::fs::remove_dir_all(directory);
    }
}
