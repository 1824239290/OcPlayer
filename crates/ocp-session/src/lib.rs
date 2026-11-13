//! Platform-neutral playback session reducer and recovery policy.

pub mod engine;
pub mod flow;
pub mod report;

use ocp_model::{PlaybackError, PlaybackSnapshot, PlaybackState};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackFailureCategory {
    Network,
    Timeout,
    Unauthorized,
    Unsupported,
    Decode,
    Missing,
    Cancelled,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackFailure {
    pub category: PlaybackFailureCategory,
    pub message: String,
    pub retryable: bool,
    pub stops_automatic_recovery: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackCandidate {
    pub id: String,
    pub source: serde_json::Value,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSessionSnapshot {
    pub playback: PlaybackSnapshot,
    pub candidates: Vec<PlaybackCandidate>,
    pub active_candidate: Option<usize>,
    pub failed_candidate_ids: Vec<String>,
    pub generation: u64,
    pub recovery_attempts: u8,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SessionError {
    #[error("session has no resource candidates")]
    EmptyCandidates,
    #[error("invalid playback transition from {0:?}")]
    InvalidTransition(PlaybackState),
    #[error("resource candidate not found")]
    CandidateNotFound,
    #[error("automatic recovery is disabled")]
    RecoveryDisabled,
    #[error("recovery budget exhausted")]
    RecoveryExhausted,
}

pub struct PlaybackSession {
    snapshot: PlaybackSessionSnapshot,
    retry_budget: u8,
}

impl PlaybackSession {
    pub fn new(retry_budget: u8) -> Self {
        Self {
            snapshot: PlaybackSessionSnapshot {
                playback: PlaybackSnapshot::default(),
                candidates: Vec::new(),
                active_candidate: None,
                failed_candidate_ids: Vec::new(),
                generation: 0,
                recovery_attempts: 0,
            },
            retry_budget,
        }
    }
    pub fn snapshot(&self) -> &PlaybackSessionSnapshot {
        &self.snapshot
    }
    pub fn open(
        &mut self,
        candidates: Vec<PlaybackCandidate>,
        preferred: Option<&str>,
    ) -> Result<&PlaybackCandidate, SessionError> {
        if candidates.is_empty() {
            return Err(SessionError::EmptyCandidates);
        }
        self.snapshot.generation = self.snapshot.generation.wrapping_add(1);
        self.snapshot.failed_candidate_ids.clear();
        self.snapshot.recovery_attempts = 0;
        self.snapshot.active_candidate = preferred
            .and_then(|id| candidates.iter().position(|candidate| candidate.id == id))
            .or(Some(0));
        self.snapshot.playback = PlaybackSnapshot::default();
        self.snapshot.playback.state = PlaybackState::Ready;
        self.snapshot.playback.source = Some(
            candidates[self.snapshot.active_candidate.unwrap()]
                .source
                .clone(),
        );
        self.snapshot.candidates = candidates;
        Ok(&self.snapshot.candidates[self.snapshot.active_candidate.unwrap()])
    }
    pub fn play(&mut self) -> Result<(), SessionError> {
        if !matches!(
            self.snapshot.playback.state,
            PlaybackState::Ready | PlaybackState::Paused
        ) {
            return Err(SessionError::InvalidTransition(
                self.snapshot.playback.state,
            ));
        }
        self.snapshot.playback.state = PlaybackState::Playing;
        Ok(())
    }
    pub fn pause(&mut self) -> Result<(), SessionError> {
        if !matches!(
            self.snapshot.playback.state,
            PlaybackState::Ready | PlaybackState::Playing
        ) {
            return Err(SessionError::InvalidTransition(
                self.snapshot.playback.state,
            ));
        }
        self.snapshot.playback.state = PlaybackState::Paused;
        Ok(())
    }
    pub fn update_position(&mut self, position: f64, duration: Option<f64>) {
        let duration = duration
            .filter(|duration| duration.is_finite() && *duration >= 0.0)
            .or(self.snapshot.playback.duration_seconds);
        if position.is_finite() && position >= 0.0 {
            self.snapshot.playback.position_seconds = duration
                .filter(|d| d.is_finite() && *d >= 0.0)
                .map_or(position, |d| position.min(d));
        }
        self.snapshot.playback.duration_seconds = duration;
    }
    pub fn set_rate(&mut self, rate: f64) {
        if rate.is_finite() && (0.25..=4.0).contains(&rate) {
            self.snapshot.playback.rate = rate;
        }
    }
    pub fn set_volume(&mut self, volume: f64) {
        if volume.is_finite() && (0.0..=1.0).contains(&volume) {
            self.snapshot.playback.volume = volume;
        }
    }
    pub fn set_muted(&mut self, muted: bool) {
        self.snapshot.playback.muted = muted;
    }
    pub fn observe_engine_timeline(&mut self, snapshot: &engine::Snapshot) {
        if self.snapshot.playback.source.is_none() {
            return;
        }
        // Native duration zero means unknown (e.g. live streams). Clearing a
        // formerly known duration must also remove its old position clamp.
        self.snapshot.playback.duration_seconds =
            (snapshot.duration_seconds > 0.0).then_some(snapshot.duration_seconds);
        self.update_position(
            snapshot.position_seconds,
            self.snapshot.playback.duration_seconds,
        );
    }
    pub fn observe_engine(&mut self, snapshot: &engine::Snapshot) {
        if self.snapshot.playback.source.is_none() {
            return;
        }
        self.observe_engine_timeline(snapshot);
        self.snapshot.playback.state = match snapshot.state {
            engine::State::Idle => PlaybackState::Idle,
            engine::State::Opening => PlaybackState::Opening,
            engine::State::Ready => PlaybackState::Ready,
            engine::State::Playing => PlaybackState::Playing,
            engine::State::Paused => PlaybackState::Paused,
            engine::State::Stopped
                if engine::in_tail(snapshot.position_seconds, snapshot.duration_seconds) =>
            {
                PlaybackState::Ended
            }
            engine::State::Stopped | engine::State::Closed => PlaybackState::Stopped,
            engine::State::Error => PlaybackState::Failed,
        };
        if let Some(failure) = &snapshot.failure {
            self.snapshot.playback.error = Some(PlaybackError {
                category: format!(
                    "{:?}",
                    flow::OpenFailureKind::classify(failure.message.as_deref().unwrap_or(""))
                )
                .to_lowercase(),
                message: failure
                    .message
                    .clone()
                    .unwrap_or_else(|| format!("engine error code={}", failure.code)),
            });
        }
    }
    pub fn select_audio(&mut self, track: Option<&str>) {
        self.snapshot.playback.audio_track = track.map(str::to_owned);
    }
    pub fn select_subtitle(&mut self, track: Option<&str>) {
        self.snapshot.playback.subtitle_track = track.map(str::to_owned);
    }
    pub fn fail(
        &mut self,
        failure: PlaybackFailure,
    ) -> Result<Option<&PlaybackCandidate>, SessionError> {
        let Some(index) = self.snapshot.active_candidate else {
            return Err(SessionError::InvalidTransition(
                self.snapshot.playback.state,
            ));
        };
        let candidate = self.snapshot.candidates[index].clone();
        if !self.snapshot.failed_candidate_ids.contains(&candidate.id) {
            self.snapshot.failed_candidate_ids.push(candidate.id);
        }
        if failure.stops_automatic_recovery {
            self.set_failure(&failure);
            return Err(SessionError::RecoveryDisabled);
        }
        if failure.retryable && self.snapshot.recovery_attempts < self.retry_budget {
            self.snapshot.recovery_attempts += 1;
            self.set_failure(&failure);
            return Ok(Some(&self.snapshot.candidates[index]));
        }
        if let Some(next) = self
            .snapshot
            .candidates
            .iter()
            .enumerate()
            .find(|(_, candidate)| !self.snapshot.failed_candidate_ids.contains(&candidate.id))
            .map(|(index, _)| index)
        {
            self.snapshot.active_candidate = Some(next);
            self.snapshot.playback.source = Some(self.snapshot.candidates[next].source.clone());
            self.snapshot.playback.state = PlaybackState::Opening;
            return Ok(Some(&self.snapshot.candidates[next]));
        }
        self.set_failure(&failure);
        Err(SessionError::RecoveryExhausted)
    }
    pub fn ready(&mut self, duration: Option<f64>) {
        self.snapshot.playback.state = PlaybackState::Ready;
        self.snapshot.playback.duration_seconds =
            duration.filter(|duration| duration.is_finite() && *duration >= 0.0);
        self.snapshot.playback.error = None;
    }
    pub fn ended(&mut self) {
        self.snapshot.playback.state = PlaybackState::Ended;
    }
    pub fn stop(&mut self) {
        self.snapshot.playback.state = PlaybackState::Stopped;
        self.snapshot.playback.position_seconds = 0.0;
    }
    pub fn record_failure(&mut self, failure: &PlaybackFailure) {
        self.set_failure(failure);
    }
    fn set_failure(&mut self, failure: &PlaybackFailure) {
        self.snapshot.playback.state = PlaybackState::Failed;
        self.snapshot.playback.error = Some(PlaybackError {
            category: format!("{:?}", failure.category).to_lowercase(),
            message: failure.message.clone(),
        });
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SegmentKind {
    Intro,
    Outro,
    Recap,
    Preview,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SkipSegment {
    pub kind: SegmentKind,
    pub start_seconds: f64,
    pub end_seconds: f64,
}

pub fn segment_at(segments: &[SkipSegment], position: f64, margin: f64) -> Option<&SkipSegment> {
    segments.iter().find(|segment| {
        position >= segment.start_seconds - margin && position < segment.end_seconds
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn candidate(id: &str) -> PlaybackCandidate {
        PlaybackCandidate {
            id: id.into(),
            source: serde_json::json!({"id":id}),
            display_name: None,
        }
    }
    #[test]
    fn engine_unknown_duration_preserves_timeline_and_clears_previous_clamp() {
        let mut session = PlaybackSession::new(0);
        session.open(vec![candidate("live")], None).unwrap();
        let mut snapshot = engine::Snapshot {
            state: engine::State::Playing,
            position_seconds: 30.0,
            ..Default::default()
        };
        session.observe_engine(&snapshot);
        assert_eq!(session.snapshot().playback.position_seconds, 30.0);
        assert_eq!(session.snapshot().playback.duration_seconds, None);
        session.pause().unwrap();
        snapshot.duration_seconds = 100.0;
        session.observe_engine_timeline(&snapshot);
        assert_eq!(session.snapshot().playback.state, PlaybackState::Paused);
        snapshot.duration_seconds = 0.0;
        snapshot.position_seconds = 150.0;
        session.observe_engine_timeline(&snapshot);
        assert_eq!(session.snapshot().playback.state, PlaybackState::Paused);
        assert_eq!(session.snapshot().playback.position_seconds, 150.0);
        assert_eq!(session.snapshot().playback.duration_seconds, None);
        snapshot.duration_seconds = 60.0;
        session.observe_engine(&snapshot);
        assert_eq!(session.snapshot().playback.position_seconds, 60.0);
    }
    #[test]
    fn failed_candidate_advances_and_generation_changes() {
        let mut session = PlaybackSession::new(1);
        session
            .open(vec![candidate("a"), candidate("b")], None)
            .unwrap();
        let generation = session.snapshot().generation;
        let next = session
            .fail(PlaybackFailure {
                category: PlaybackFailureCategory::Decode,
                message: "unsupported source".into(),
                retryable: false,
                stops_automatic_recovery: false,
            })
            .unwrap()
            .unwrap();
        assert_eq!(next.id, "b");
        assert_eq!(session.snapshot().playback.state, PlaybackState::Opening);
        session.open(vec![candidate("c")], None).unwrap();
        assert!(session.snapshot().generation > generation);
    }
}
