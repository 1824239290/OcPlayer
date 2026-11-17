//! Native-engine event reduction with explicit generation ownership. Rendering,
//! observation publishing and elapsed-time statistics remain host operations.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    #[default]
    Idle,
    Opening,
    Ready,
    Playing,
    Paused,
    Stopped,
    Closed,
    Error,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Failure {
    pub code: i32,
    pub message: Option<String>,
}
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub generation: u64,
    pub state: State,
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub error_count: u64,
    pub failure: Option<Failure>,
    pub folded_stale_tail_failure: bool,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Event {
    StateChanged { state: State },
    Position { seconds: f64 },
    Duration { seconds: f64 },
    Failed { code: i32, message: Option<String> },
}
impl Event {
    pub fn valid(&self) -> bool {
        match self {
            Self::Position { seconds } | Self::Duration { seconds } => {
                seconds.is_finite() && *seconds >= 0.0
            }
            _ => true,
        }
    }
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub accepted: bool,
    pub reported_failure: bool,
    pub folded_tail_failure: bool,
    pub snapshot: Snapshot,
}
#[derive(Default)]
pub struct EngineEvents {
    snapshot: Snapshot,
    last_failure: Option<(i32, String)>,
}
impl EngineEvents {
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn begin(&mut self) -> &Snapshot {
        self.snapshot = Snapshot {
            generation: self.snapshot.generation.wrapping_add(1),
            ..Default::default()
        };
        self.last_failure = None;
        &self.snapshot
    }
    pub fn apply(&mut self, generation: u64, event: Event) -> Decision {
        let mut reported_failure = false;
        let mut folded_tail_failure = false;
        if generation != self.snapshot.generation || !event.valid() {
            return self.decision(false, false, false);
        }
        match event {
            Event::StateChanged { state } => {
                if !(state == State::Error
                    && self.snapshot.folded_stale_tail_failure
                    && in_tail(
                        self.snapshot.position_seconds,
                        self.snapshot.duration_seconds,
                    ))
                {
                    self.snapshot.state = state;
                }
            }
            Event::Position { seconds } => self.snapshot.position_seconds = seconds,
            Event::Duration { seconds } => self.snapshot.duration_seconds = seconds,
            Event::Failed { code, message } => {
                let failure = Failure { code, message };
                let key = (code, failure.message.clone().unwrap_or_default());
                if stale_tail_io(
                    failure.message.as_deref(),
                    self.snapshot.position_seconds,
                    self.snapshot.duration_seconds,
                ) {
                    // An already-visible real error must never be turned into EOF.
                    if self.snapshot.state != State::Error {
                        if self.last_failure.as_ref() != Some(&key) {
                            self.last_failure = Some(key);
                            self.snapshot.folded_stale_tail_failure = true;
                            folded_tail_failure = true;
                        }
                        self.snapshot.state = State::Stopped;
                    }
                } else {
                    if self.last_failure.as_ref() != Some(&key) {
                        self.last_failure = Some(key);
                        self.snapshot.error_count = self.snapshot.error_count.saturating_add(1);
                        reported_failure = true;
                    }
                    self.snapshot.state = State::Error;
                    self.snapshot.failure = Some(failure);
                }
            }
        }
        self.decision(true, reported_failure, folded_tail_failure)
    }
    fn decision(
        &self,
        accepted: bool,
        reported_failure: bool,
        folded_tail_failure: bool,
    ) -> Decision {
        Decision {
            accepted,
            reported_failure,
            folded_tail_failure,
            snapshot: self.snapshot.clone(),
        }
    }
}
pub fn in_tail(position: f64, duration: f64) -> bool {
    duration > 0.0 && position >= duration - 2.0
}
pub fn stale_tail_io(message: Option<&str>, position: f64, duration: f64) -> bool {
    in_tail(position, duration)
        && message
            .is_some_and(|message| message.contains("av_read_frame") && message.contains("(-5)"))
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResumeAction {
    None,
    Resume,
    Rebuild,
}
pub fn foreground_action(intent: bool, state: Option<State>, setup_error: bool) -> ResumeAction {
    if !intent || state.is_none() {
        return ResumeAction::None;
    }
    if setup_error || state == Some(State::Error) {
        return ResumeAction::Rebuild;
    }
    match state {
        Some(State::Paused | State::Ready | State::Playing) => ResumeAction::Resume,
        _ => ResumeAction::None,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn tail() -> EngineEvents {
        let mut events = EngineEvents::default();
        let g = events.begin().generation;
        events.apply(g, Event::Duration { seconds: 100.0 });
        events.apply(g, Event::Position { seconds: 99.0 });
        events
    }
    #[test]
    fn stale_tail_pair_folds_once_and_real_error_is_preserved() {
        let mut e = tail();
        let g = e.snapshot.generation;
        let failure = Event::Failed {
            code: -5,
            message: Some("ffmpeg av_read_frame: 本地化错误 (-5)".into()),
        };
        let d = e.apply(g, failure.clone());
        assert!(d.folded_tail_failure);
        assert_eq!(d.snapshot.state, State::Stopped);
        assert_eq!(d.snapshot.error_count, 0);
        assert!(!e.apply(g, failure.clone()).folded_tail_failure);
        assert_eq!(
            e.apply(
                g,
                Event::StateChanged {
                    state: State::Error
                }
            )
            .snapshot
            .state,
            State::Stopped
        );
        let real = Event::Failed {
            code: 401,
            message: Some("HTTP 401".into()),
        };
        assert!(e.apply(g, real.clone()).reported_failure);
        assert!(!e.apply(g, real).reported_failure);
        let d = e.apply(g, failure);
        assert_eq!(d.snapshot.state, State::Error);
        assert_eq!(d.snapshot.error_count, 1);
        assert_eq!(
            d.snapshot.failure.unwrap().message.as_deref(),
            Some("HTTP 401")
        );
    }
    #[test]
    fn nil_and_empty_messages_share_the_native_deduplication_key() {
        let mut events = EngineEvents::default();
        let generation = events.begin().generation;
        assert!(
            events
                .apply(
                    generation,
                    Event::Failed {
                        code: 7,
                        message: None
                    }
                )
                .reported_failure
        );
        let next = events.apply(
            generation,
            Event::Failed {
                code: 7,
                message: Some(String::new()),
            },
        );
        assert!(!next.reported_failure);
        assert_eq!(next.snapshot.error_count, 1);
        assert_eq!(next.snapshot.failure.unwrap().message.as_deref(), Some(""));
    }
    #[test]
    fn new_source_rejects_previous_generation_and_resets_failure_history() {
        let mut e = tail();
        let old = e.snapshot.generation;
        e.apply(
            old,
            Event::Failed {
                code: 7,
                message: None,
            },
        );
        let next = e.begin().generation;
        assert_ne!(old, next);
        for event in [
            Event::StateChanged {
                state: State::Error,
            },
            Event::Position { seconds: 100.0 },
            Event::Failed {
                code: 401,
                message: None,
            },
        ] {
            assert!(!e.apply(old, event).accepted);
        }
        assert_eq!(e.snapshot.state, State::Idle);
        assert_eq!(e.snapshot.error_count, 0);
        assert_eq!(e.snapshot.position_seconds, 0.0);
        assert!(
            e.apply(
                next,
                Event::Failed {
                    code: 7,
                    message: None
                }
            )
            .reported_failure
        );
    }
    #[test]
    fn only_tail_read_eio_is_folded() {
        assert!(stale_tail_io(Some("av_read_frame (-5)"), 98.0, 100.0));
        for (message, pos, duration) in [
            ("av_read_frame (-5)", 97.9, 100.0),
            ("av_read_frame (-5)", 99.0, 0.0),
            ("Input/output error (-5)", 99.0, 100.0),
            ("av_read_frame (-11)", 99.0, 100.0),
        ] {
            assert!(!stale_tail_io(Some(message), pos, duration));
        }
    }
    #[test]
    fn foreground_requires_intent_and_current_state_before_rebuilding() {
        assert_eq!(
            foreground_action(false, Some(State::Error), true),
            ResumeAction::None
        );
        assert_eq!(foreground_action(true, None, true), ResumeAction::None);
        for state in [State::Ready, State::Paused, State::Playing] {
            assert_eq!(
                foreground_action(true, Some(state), false),
                ResumeAction::Resume
            );
            assert_eq!(
                foreground_action(true, Some(state), true),
                ResumeAction::Rebuild
            );
        }
        for state in [State::Idle, State::Opening, State::Stopped, State::Closed] {
            assert_eq!(
                foreground_action(true, Some(state), false),
                ResumeAction::None
            );
        }
        assert_eq!(
            foreground_action(true, Some(State::Error), false),
            ResumeAction::Rebuild
        );
    }
}
