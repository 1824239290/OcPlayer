//! Report scheduling decisions. Hosts retain ordered, cancellable I/O tasks.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Active,
    Paused,
    Stopped,
    Error,
}
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub state: State,
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub source_open_failed: bool,
}
impl Snapshot {
    pub fn valid(&self) -> bool {
        self.position_seconds.is_finite()
            && self.position_seconds >= 0.0
            && self.duration_seconds.is_finite()
            && self.duration_seconds >= 0.0
    }
    pub fn terminal(&self) -> bool {
        matches!(self.state, State::Stopped | State::Error) || self.source_open_failed
    }
    pub fn natural_end(&self) -> bool {
        self.state == State::Stopped
            && !self.source_open_failed
            && self.duration_seconds > 0.0
            && self.position_seconds >= self.duration_seconds - 2.0
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Heartbeat,
    Background,
    Inspect,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    None,
    Progress,
    Stopped,
}
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub action: Action,
    pub ticks: u64,
    pub reported_pause: bool,
    pub reached_end: bool,
}
pub fn step(
    snapshot: Snapshot,
    mode: Mode,
    ticks: u64,
    reported_pause: bool,
    every_ticks: u64,
) -> Decision {
    let mut next = Decision {
        action: Action::None,
        ticks,
        reported_pause,
        reached_end: snapshot.natural_end(),
    };
    if mode == Mode::Inspect {
        return next;
    }
    if snapshot.terminal() {
        next.action = Action::Stopped;
        return next;
    }
    if mode == Mode::Background {
        next.action = Action::Progress;
        return next;
    }
    next.ticks = ticks.wrapping_add(1);
    if snapshot.state == State::Paused {
        next.reported_pause = true;
        if !reported_pause {
            next.action = Action::Progress;
        }
    } else {
        next.reported_pause = false;
        if next.ticks.is_multiple_of(every_ticks.max(1)) {
            next.action = Action::Progress;
        }
    }
    next
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample(state: State, position: f64) -> Snapshot {
        Snapshot {
            state,
            position_seconds: position,
            duration_seconds: 100.0,
            source_open_failed: false,
        }
    }
    #[test]
    fn terminal_requires_clean_stopped_and_known_duration() {
        assert!(sample(State::Stopped, 98.0).natural_end());
        assert!(!sample(State::Stopped, 97.99).natural_end());
        assert!(!sample(State::Error, 100.0).natural_end());
        let mut snapshot = sample(State::Stopped, 100.0);
        snapshot.source_open_failed = true;
        assert!(!snapshot.natural_end());
        snapshot.source_open_failed = false;
        snapshot.duration_seconds = 0.0;
        assert!(!snapshot.natural_end());
        assert_eq!(
            step(sample(State::Error, 100.0), Mode::Heartbeat, 0, false, 10).action,
            Action::Stopped
        );
    }
    #[test]
    fn pause_reports_once_then_resuming_restores_periodic_reporting() {
        let paused = sample(State::Paused, 30.0);
        let first = step(paused, Mode::Heartbeat, 0, false, 10);
        assert_eq!(first.action, Action::Progress);
        let next = step(
            paused,
            Mode::Heartbeat,
            first.ticks,
            first.reported_pause,
            10,
        );
        assert_eq!(next.action, Action::None);
        let resumed = step(sample(State::Active, 40.0), Mode::Heartbeat, 9, true, 10);
        assert_eq!(resumed.action, Action::Progress);
        assert!(!resumed.reported_pause);
        assert_eq!(
            step(paused, Mode::Background, 0, true, 10).action,
            Action::Progress
        );
        assert_eq!(
            step(paused, Mode::Inspect, 0, false, 10).action,
            Action::None
        );
    }
}
