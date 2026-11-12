//! Composition root for the platform-neutral OcPlayer business core.

use std::collections::VecDeque;
use std::sync::Mutex;

use ocp_model::{ApiResponse, CoreConfig, CoreSnapshot, Event, ABI_VERSION, CORE_VERSION};
use serde_json::{json, Value};
use thiserror::Error;

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
}

struct State {
    config: CoreConfig,
    ready: bool,
    surface_attached: bool,
    active_method: Option<String>,
    next_sequence: u64,
    events: VecDeque<Event>,
}

pub struct Core {
    state: Mutex<State>,
}

impl Core {
    pub fn new(config_json: &str) -> Result<Self, CoreError> {
        let config = if config_json.trim().is_empty() {
            CoreConfig::default()
        } else {
            serde_json::from_str(config_json)?
        };

        let mut core = Self {
            state: Mutex::new(State {
                config,
                ready: true,
                surface_attached: false,
                active_method: None,
                next_sequence: 1,
                events: VecDeque::new(),
            }),
        };
        core.push_event_locked("core.ready", json!({ "abiVersion": ABI_VERSION }));
        Ok(core)
    }

    pub fn call(&self, method: &str, arguments_json: &str) -> Result<String, CoreError> {
        let arguments: Value = if arguments_json.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(arguments_json)?
        };
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        state.active_method = Some(method.to_string());

        let response = match method {
            "ping" => ApiResponse::ok(json!({
                "abiVersion": ABI_VERSION,
                "coreVersion": CORE_VERSION,
                "pong": true,
            })),
            "core.getVersion" => ApiResponse::ok(json!({
                "abiVersion": ABI_VERSION,
                "coreVersion": CORE_VERSION,
            })),
            "settings.get" => ApiResponse::ok(json!({ "config": state.config })),
            "settings.set" => {
                let config: CoreConfig =
                    serde_json::from_value(arguments.get("config").cloned().unwrap_or(arguments))?;
                state.config = config.clone();
                state.push_event("settings.changed", json!({ "config": config }));
                ApiResponse::ok(json!({ "config": state.config }))
            }
            "playback.open" => {
                let source = arguments.get("source").cloned().unwrap_or(Value::Null);
                state.push_event("playback.opened", json!({ "source": source }));
                ApiResponse::ok(json!({ "accepted": true }))
            }
            "playback.play" | "playback.pause" | "playback.stop" => {
                state.push_event(method, arguments);
                ApiResponse::ok(json!({ "accepted": true }))
            }
            "playback.seek"
            | "playback.setRate"
            | "playback.setVolume"
            | "playback.selectAudio"
            | "playback.selectSubtitle" => {
                state.push_event(method, arguments);
                ApiResponse::ok(json!({ "accepted": true }))
            }
            _ => return Err(CoreError::UnknownMethod(method.to_string())),
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
            })?,
            "playback" => json!({ "surfaceAttached": state.surface_attached }),
            _ => return Err(CoreError::UnknownSnapshot(kind.to_string())),
        };
        serde_json::to_string(&value).map_err(CoreError::InvalidJson)
    }

    pub fn poll_event(&self) -> Result<Option<String>, CoreError> {
        let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        state
            .events
            .pop_front()
            .map(|event| serde_json::to_string(&event).map_err(CoreError::InvalidJson))
            .transpose()
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
        let state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
        if state.surface_attached {
            drop(state);
            let mut state = self.state.lock().map_err(|_| CoreError::StateUnavailable)?;
            state.push_event("render.tick", json!({ "timeSeconds": time_seconds }));
        }
        Ok(())
    }

    fn push_event_locked(&mut self, kind: &str, data: Value) {
        if let Ok(mut state) = self.state.lock() {
            state.push_event(kind, data);
        }
    }
}

impl State {
    fn push_event(&mut self, kind: &str, data: Value) {
        let event = Event {
            sequence: self.next_sequence,
            kind: kind.to_string(),
            data,
        };
        self.next_sequence += 1;
        self.events.push_back(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_core_and_emits_ready_event() {
        let core = Core::new("{}").unwrap();
        let event = core.poll_event().unwrap().unwrap();
        assert!(event.contains("core.ready"));
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
        core.call("playback.play", "{}").unwrap();
        let first: Event = serde_json::from_str(&core.poll_event().unwrap().unwrap()).unwrap();
        let second: Event = serde_json::from_str(&core.poll_event().unwrap().unwrap()).unwrap();
        assert!(second.sequence > first.sequence);
    }
}
