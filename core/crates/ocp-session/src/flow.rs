//! A playback request chain survives platform engine replacement. Hosts execute
//! decisions and acknowledge each replacement with a fresh request identity.
use serde::{Deserialize, Serialize};

pub const MAXIMUM_SOURCE_FAILOVERS: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpenFailureKind {
    Network,
    Format,
    Auth,
    Server,
    Aborted,
    Unknown,
}
impl OpenFailureKind {
    pub fn allows_source_failover(self) -> bool {
        !matches!(self, Self::Auth | Self::Aborted)
    }
    pub fn is_retryable(self) -> bool {
        self != Self::Aborted
    }
    pub fn classify(message: &str) -> Self {
        let text = message.to_lowercase();
        for (kind, words) in [
            (Self::Aborted, &["取消", "cancel", "让位"][..]),
            (
                Self::Network,
                &[
                    "超时",
                    "timeout",
                    "timed out",
                    "连接",
                    "网络",
                    "connection",
                    "network",
                    "unreachable",
                    "offline",
                    "host",
                    "socket",
                    "dns",
                    "拒绝",
                ][..],
            ),
            (
                Self::Auth,
                &[
                    "401",
                    "403",
                    "鉴权",
                    "认证",
                    "令牌",
                    "unauthorized",
                    "forbidden",
                    "token",
                ][..],
            ),
            (
                Self::Format,
                &[
                    "解码",
                    "格式",
                    "不支持",
                    "codec",
                    "format",
                    "demux",
                    "parse",
                ][..],
            ),
            (
                Self::Server,
                &["500", "502", "503", "504", "服务器", "server"][..],
            ),
        ] {
            if words.iter().any(|word| text.contains(word)) {
                return kind;
            }
        }
        Self::Unknown
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Alternate {
    pub id: String,
    pub has_session_context: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attempt {
    pub source_id: Option<String>,
    pub kind: OpenFailureKind,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowSnapshot {
    pub playback_request_id: Option<String>,
    pub source_id: Option<String>,
    pub active: bool,
    pub generation: u64,
    pub failover_count: usize,
    pub attempts: Vec<Attempt>,
    pub alternates: Vec<Alternate>,
    pub pending_source_id: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Ignored,
    None,
    Manual,
    Switch,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub action: Action,
    pub reason: &'static str,
    pub snapshot: FlowSnapshot,
}
#[derive(Default)]
pub struct PlaybackFlow {
    snapshot: FlowSnapshot,
}
impl PlaybackFlow {
    pub fn snapshot(&self) -> &FlowSnapshot {
        &self.snapshot
    }
    pub fn begin(
        &mut self,
        request_id: String,
        source_id: Option<String>,
        alternates: Vec<Alternate>,
    ) {
        let generation = self.snapshot.generation.wrapping_add(1);
        self.snapshot = FlowSnapshot {
            playback_request_id: Some(request_id),
            source_id,
            active: true,
            generation,
            alternates,
            ..Default::default()
        };
    }
    pub fn invalidate(&mut self) {
        self.snapshot.generation = self.snapshot.generation.wrapping_add(1);
        self.snapshot.active = false;
        self.snapshot.pending_source_id = None;
    }
    pub fn fail(&mut self, request_id: &str, kind: OpenFailureKind, has_item: bool) -> Decision {
        if !self.snapshot.active
            || self.snapshot.playback_request_id.as_deref() != Some(request_id)
            || self.snapshot.pending_source_id.is_some()
        {
            return self.decision(Action::Ignored, "stale_or_pending");
        }
        self.snapshot.attempts.push(Attempt {
            source_id: self.snapshot.source_id.clone(),
            kind,
        });
        if !kind.allows_source_failover() {
            return self.finish(Action::None, "recovery_disabled");
        }
        if self.snapshot.failover_count >= MAXIMUM_SOURCE_FAILOVERS {
            return self.finish(Action::Manual, "limit");
        }
        let Some(next) = self.snapshot.alternates.first() else {
            let action = if self.snapshot.failover_count > 0 {
                Action::Manual
            } else {
                Action::None
            };
            return self.finish(action, "exhausted");
        };
        if !has_item {
            return self.finish(Action::None, "missing_item");
        }
        self.snapshot.failover_count += 1;
        if !next.has_session_context {
            return self.finish(Action::Manual, "missing_context");
        }
        self.snapshot.pending_source_id = Some(next.id.clone());
        self.decision(Action::Switch, "alternate")
    }
    pub fn adopt(
        &mut self,
        from_request_id: &str,
        generation: u64,
        request_id: String,
        source_id: &str,
    ) -> bool {
        if !self.snapshot.active
            || self.snapshot.generation != generation
            || self.snapshot.playback_request_id.as_deref() != Some(from_request_id)
            || self.snapshot.pending_source_id.as_deref() != Some(source_id)
            || from_request_id == request_id
        {
            return false;
        }
        self.snapshot.playback_request_id = Some(request_id);
        self.snapshot.source_id = Some(source_id.to_owned());
        self.snapshot.alternates.remove(0);
        self.snapshot.pending_source_id = None;
        true
    }
    fn finish(&mut self, action: Action, reason: &'static str) -> Decision {
        self.snapshot.active = false;
        self.decision(action, reason)
    }
    fn decision(&self, action: Action, reason: &'static str) -> Decision {
        Decision {
            action,
            reason,
            snapshot: self.snapshot.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn flow(n: usize) -> PlaybackFlow {
        let mut flow = PlaybackFlow::default();
        flow.begin(
            "primary-request".into(),
            Some("primary".into()),
            (0..n)
                .map(|i| Alternate {
                    id: format!("alt-{i}"),
                    has_session_context: true,
                })
                .collect(),
        );
        flow
    }
    #[test]
    fn chain_preserves_identity_history_and_limits_across_replacements() {
        let mut flow = flow(4);
        for i in 0..MAXIMUM_SOURCE_FAILOVERS {
            let old = flow.snapshot.playback_request_id.clone().unwrap();
            let decision = flow.fail(&old, OpenFailureKind::Network, true);
            assert_eq!(decision.action, Action::Switch);
            assert_eq!(
                flow.fail(&old, OpenFailureKind::Network, true).action,
                Action::Ignored
            );
            let next = format!("request-{i}");
            assert!(!flow.adopt(
                &old,
                decision.snapshot.generation,
                old.clone(),
                &format!("alt-{i}")
            ));
            assert!(flow.adopt(
                &old,
                decision.snapshot.generation,
                next,
                &format!("alt-{i}")
            ));
            assert_eq!(
                flow.fail(&old, OpenFailureKind::Network, true).action,
                Action::Ignored
            );
        }
        let id = flow.snapshot.playback_request_id.clone().unwrap();
        assert_eq!(
            flow.fail(&id, OpenFailureKind::Unknown, true).action,
            Action::Manual
        );
        assert_eq!(flow.snapshot.attempts.len(), 4);
        assert_eq!(
            flow.snapshot.attempts[1].source_id.as_deref(),
            Some("alt-0")
        );
        flow.begin("user-retry".into(), None, vec![]);
        assert_eq!(flow.snapshot.failover_count, 0);
        assert!(flow.snapshot.attempts.is_empty());
    }
    #[test]
    fn cancellation_or_new_play_invalidates_queued_adoption() {
        let mut flow = flow(1);
        let d = flow.fail("primary-request", OpenFailureKind::Network, true);
        flow.invalidate();
        assert!(!flow.adopt(
            "primary-request",
            d.snapshot.generation,
            "late".into(),
            "alt-0"
        ));
        assert_eq!(
            flow.fail("primary-request", OpenFailureKind::Network, true)
                .action,
            Action::Ignored
        );
    }
    #[test]
    fn recovery_stops_for_auth_cancel_missing_item_and_missing_context() {
        for kind in [OpenFailureKind::Auth, OpenFailureKind::Aborted] {
            let mut f = flow(1);
            assert_eq!(f.fail("primary-request", kind, true).action, Action::None);
            assert_eq!(f.snapshot.failover_count, 0);
            assert_eq!(f.snapshot.attempts.len(), 1);
        }
        let mut f = flow(1);
        assert_eq!(
            f.fail("primary-request", OpenFailureKind::Network, false)
                .action,
            Action::None
        );
        let mut f = flow(1);
        f.snapshot.alternates[0].has_session_context = false;
        assert_eq!(
            f.fail("primary-request", OpenFailureKind::Format, true)
                .action,
            Action::Manual
        );
    }
    #[test]
    fn all_candidates_exhausted_explains_chain_but_single_source_keeps_original_error() {
        let mut f = flow(0);
        assert_eq!(
            f.fail("primary-request", OpenFailureKind::Network, true)
                .action,
            Action::None
        );
        let mut f = flow(1);
        let d = f.fail("primary-request", OpenFailureKind::Network, true);
        assert!(f.adopt(
            "primary-request",
            d.snapshot.generation,
            "next".into(),
            "alt-0"
        ));
        assert_eq!(
            f.fail("next", OpenFailureKind::Format, true).action,
            Action::Manual
        );
        assert_eq!(f.snapshot.attempts.len(), 2);
    }
    #[test]
    fn classifier_preserves_native_priority_and_capabilities() {
        assert_eq!(
            OpenFailureKind::classify("Cancelled network 401"),
            OpenFailureKind::Aborted
        );
        assert_eq!(
            OpenFailureKind::classify("connection 401"),
            OpenFailureKind::Network
        );
        assert_eq!(
            OpenFailureKind::classify("TOKEN expired"),
            OpenFailureKind::Auth
        );
        assert_eq!(
            OpenFailureKind::classify("demux parse failed"),
            OpenFailureKind::Format
        );
        assert_eq!(
            OpenFailureKind::classify("server 503"),
            OpenFailureKind::Server
        );
        assert!(OpenFailureKind::Unknown.allows_source_failover());
        assert!(OpenFailureKind::Auth.is_retryable());
        assert!(!OpenFailureKind::Aborted.is_retryable());
    }
}
