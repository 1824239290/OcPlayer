//! Retained subject/progress workflows. The composition root applies all SQL
//! reads/writes under the receipt/retirement lock. HTTP and notifications yield.
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Directory {
    next: u64,
    flows: BTreeMap<u64, Flow>,
}
#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum Operation {
    EnsureSubject,
    ReconcileSubject,
    RefreshAfterProgress,
    EnsureWatching,
    UpdateEpisode,
    UpdateSubject,
    UpdateRating,
    LoadEpisodes,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Start {
    operation: Operation,
    subject_id: Option<i64>,
    episode_id: Option<i64>,
    r#type: Option<i64>,
    rate: Option<i64>,
    #[serde(default)]
    refresh_episodes: bool,
    #[serde(default)]
    authoritative_collection: bool,
    #[serde(default)]
    batch: bool,
    #[serde(default)]
    prepare_watching: bool,
}
#[derive(Clone, Copy, PartialEq)]
enum Phase {
    SubjectPresence,
    SubjectRemote,
    Interest,
    SubjectSave,
    Counts,
    EpisodePage,
    EpisodeSave,
    EpisodeSubject,
    WatchingLookup,
    WatchingRemote,
    EpisodeRemote,
    EpisodeLocal,
    SubjectRemoteWrite,
    SubjectLocalWrite,
    Mains,
    PromoteLookup,
    PromoteRemote,
    PromoteLocal,
    Notify,
    NotifyMember,
    Log,
    Done,
}
#[derive(Deserialize)]
struct Receipt {
    token: u64,
    sequence: u64,
}
#[derive(Deserialize)]
struct Resume {
    token: u64,
    sequence: u64,
    response: Value,
}
#[derive(Deserialize)]
struct Failure {
    token: u64,
    sequence: u64,
    reason: String,
}
#[derive(Deserialize)]
struct Token {
    token: u64,
}
#[derive(Deserialize)]
struct Page {
    data: Vec<Value>,
    total: i64,
}
#[derive(Deserialize)]
struct EpisodeCounts {
    main: i64,
    other: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum LookupState {
    Collected,
    NotCollected,
    Unknown,
}
#[derive(Deserialize)]
struct Lookup {
    state: LookupState,
    interest: Option<Value>,
    reason: Option<String>,
}
fn decode<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T, String> {
    serde_json::from_value(value.clone()).map_err(|e| e.to_string())
}
fn interest_type(lookup: &Lookup) -> Result<Option<i64>, String> {
    if matches!(lookup.state, LookupState::Collected) {
        let typ = lookup
            .interest
            .as_ref()
            .and_then(|i| i["type"].as_i64())
            .ok_or("collected lookup requires interest.type")?;
        if !(0..=5).contains(&typ) {
            return Err("invalid collection type".into());
        }
        Ok(Some(typ))
    } else {
        Ok(None)
    }
}
fn watching_target(lookup: &Lookup) -> Result<Option<i64>, String> {
    Ok(match lookup.state {
        LookupState::Unknown => None,
        LookupState::NotCollected => Some(3),
        LookupState::Collected => match interest_type(lookup)? {
            Some(2 | 3) => None,
            _ => Some(3),
        },
    })
}
#[derive(Clone)]
struct Flow {
    operation: Operation,
    phase: Phase,
    sequence: u64,
    subject: i64,
    episode: i64,
    typ: i64,
    rate: i64,
    refresh: bool,
    authoritative: bool,
    batch: bool,
    remote: Value,
    episodes: Vec<Value>,
    offset: i64,
    success: bool,
    result: bool,
    log: String,
    reason: String,
    after_log: Phase,
}
impl Flow {
    fn new(start: Start) -> Result<Self, String> {
        use Operation::*;
        let episode = start.episode_id.unwrap_or(0);
        let subject = start.subject_id.unwrap_or(0);
        if start.operation == UpdateEpisode {
            if start.episode_id.is_none() {
                return Err("missing episodeId".into());
            }
        } else if start.subject_id.is_none() {
            return Err("missing subjectId".into());
        }
        let typ = start.r#type.unwrap_or(0);
        if matches!(start.operation, UpdateEpisode | UpdateSubject)
            && (start.r#type.is_none()
                || !(0..=if start.operation == UpdateEpisode {
                    3
                } else {
                    5
                })
                    .contains(&typ))
        {
            return Err("invalid collection type".into());
        }
        let rate = start.rate.unwrap_or(0);
        if start.operation == UpdateRating && (start.rate.is_none() || !(0..=10).contains(&rate)) {
            return Err("invalid subject rating".into());
        }
        let phase = match start.operation {
            EnsureSubject => Phase::SubjectPresence,
            ReconcileSubject | RefreshAfterProgress => Phase::SubjectRemote,
            EnsureWatching => Phase::WatchingLookup,
            UpdateEpisode if start.prepare_watching && typ == 2 => Phase::EpisodeSubject,
            UpdateEpisode => Phase::EpisodeRemote,
            UpdateSubject | UpdateRating => Phase::SubjectRemoteWrite,
            LoadEpisodes => Phase::EpisodePage,
        };
        Ok(Self {
            operation: start.operation,
            phase,
            sequence: 1,
            subject,
            episode,
            typ,
            rate,
            refresh: start.refresh_episodes,
            authoritative: start.authoritative_collection,
            batch: start.batch,
            remote: Value::Null,
            episodes: vec![],
            offset: 0,
            success: true,
            result: start.operation != EnsureWatching,
            log: String::new(),
            reason: String::new(),
            after_log: Phase::Done,
        })
    }
    fn database(&self) -> bool {
        matches!(
            self.phase,
            Phase::SubjectPresence
                | Phase::SubjectSave
                | Phase::Counts
                | Phase::EpisodeSave
                | Phase::EpisodeSubject
                | Phase::EpisodeLocal
                | Phase::SubjectLocalWrite
                | Phase::Mains
                | Phase::PromoteLocal
        )
    }
    fn log_then(&mut self, kind: &str, reason: &str, next: Phase) {
        self.log = kind.into();
        self.reason = reason.chars().take(4096).collect();
        self.after_log = next;
        self.phase = Phase::Log;
    }
    fn begin_reconcile(&mut self) {
        self.phase = Phase::SubjectRemote;
        self.remote = Value::Null;
        self.episodes.clear();
        self.offset = 0;
    }
    fn advance(&mut self, response: Value) -> Result<(), String> {
        use Operation::*;
        use Phase::*;
        match self.phase {
            SubjectPresence => {
                self.phase = if response.is_null() {
                    SubjectRemote
                } else {
                    Counts
                }
            }
            SubjectRemote => {
                if !response.is_object() || response["id"].as_i64() != Some(self.subject) {
                    return Err("subject response identity mismatch".into());
                }
                self.remote = response;
                self.phase = if self.operation == EnsureSubject {
                    SubjectSave
                } else {
                    Interest
                };
            }
            Interest => {
                let lookup: Lookup = decode(&response)?;
                interest_type(&lookup)?;
                if matches!(lookup.state, LookupState::Collected) {
                    self.remote["interest"] = lookup.interest.unwrap();
                }
                self.phase = SubjectSave;
            }
            SubjectSave => {
                self.phase = if self.operation == EnsureSubject {
                    Counts
                } else {
                    EpisodePage
                }
            }
            Counts => {
                let counts: EpisodeCounts = decode(&response)?;
                self.phase = if self.refresh
                    || counts
                        .main
                        .checked_add(counts.other)
                        .ok_or("episode count overflow")?
                        == 0
                {
                    EpisodePage
                } else {
                    Notify
                };
            }
            EpisodePage => {
                let page: Page = decode(&response)?;
                let empty = page.data.is_empty();
                self.episodes.extend(page.data);
                self.offset = self
                    .offset
                    .checked_add(1000)
                    .ok_or("episode page overflow")?;
                if empty || self.offset >= page.total {
                    self.phase = EpisodeSave;
                }
            }
            EpisodeSave => {
                self.phase = match self.operation {
                    EnsureSubject | LoadEpisodes => Notify,
                    RefreshAfterProgress => Mains,
                    UpdateEpisode => NotifyMember,
                    _ => Done,
                }
            }
            EpisodeSubject => {
                let subject: Option<i64> = decode(&response)?;
                if let Some(subject) = subject {
                    self.subject = subject;
                    self.phase = WatchingLookup;
                } else {
                    self.phase = EpisodeRemote;
                }
            }
            WatchingLookup => {
                let lookup: Lookup = decode(&response)?;
                if watching_target(&lookup)?.is_some() {
                    self.phase = WatchingRemote;
                } else {
                    let next = if self.operation == UpdateEpisode {
                        EpisodeRemote
                    } else {
                        Done
                    };
                    if let Some(reason) = lookup.reason {
                        self.log_then("watchingUnknown", &reason, next);
                    } else {
                        self.phase = next;
                    }
                }
            }
            WatchingRemote => {
                self.result = true;
                let next = if self.operation == UpdateEpisode {
                    EpisodeRemote
                } else {
                    Done
                };
                self.log_then("watchingAdvanced", "", next);
            }
            EpisodeRemote => self.phase = EpisodeLocal,
            EpisodeLocal => {
                let subject: Option<i64> = decode(&response)?;
                if let Some(subject) = subject {
                    self.subject = subject;
                    self.phase = Notify;
                } else {
                    self.phase = Done;
                }
            }
            SubjectRemoteWrite => self.phase = SubjectLocalWrite,
            SubjectLocalWrite => {
                self.phase = if self.operation == UpdateSubject {
                    NotifyMember
                } else {
                    Notify
                }
            }
            Mains => {
                let episodes: Vec<Value> = decode(&response)?;
                self.phase = if !episodes.is_empty()
                    && episodes.iter().all(|e| e["collection"]["status"] == 2)
                {
                    PromoteLookup
                } else {
                    NotifyMember
                };
            }
            PromoteLookup => {
                let lookup: Lookup = decode(&response)?;
                self.phase = if interest_type(&lookup)? == Some(3) {
                    PromoteRemote
                } else {
                    NotifyMember
                };
            }
            PromoteRemote => self.phase = PromoteLocal,
            PromoteLocal => self.log_then("seasonCompleted", "", NotifyMember),
            Notify => {
                if self.operation == UpdateEpisode && self.batch {
                    self.begin_reconcile();
                } else {
                    self.phase = Done;
                }
            }
            NotifyMember => self.phase = Done,
            Log => self.phase = self.after_log,
            Done => return Err("retired progress flow".into()),
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("progress sequence exhausted")?;
        Ok(())
    }
    fn fail(&mut self, reason: &str) -> Result<(), String> {
        use Phase::*;
        if self.operation == Operation::UpdateEpisode
            && matches!(self.phase, WatchingLookup | WatchingRemote)
        {
            self.phase = EpisodeRemote;
        } else if matches!(
            self.phase,
            SubjectRemote | Interest | SubjectSave | EpisodePage | EpisodeSave
        ) && self.operation == Operation::RefreshAfterProgress
        {
            self.log_then("reconcileFailed", reason, Mains);
        } else if matches!(
            self.phase,
            SubjectRemote | Interest | SubjectSave | EpisodePage | EpisodeSave
        ) && self.operation == Operation::UpdateEpisode
        {
            self.log_then("batchReconcileFailed", reason, Done);
        } else if matches!(
            self.phase,
            Mains | PromoteLookup | PromoteRemote | PromoteLocal
        ) && self.operation == Operation::RefreshAfterProgress
        {
            self.log_then("promotionFailed", reason, NotifyMember);
        } else {
            self.success = false;
            self.phase = Done;
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("progress sequence exhausted")?;
        Ok(())
    }
    fn statement(&self, now: i64) -> Result<(&'static str, Value), String> {
        use Phase::*;
        Ok(match self.phase {
            SubjectPresence => ("subject", json!({"subjectId":self.subject})),
            SubjectSave => (
                "saveSubject",
                json!({"item":self.remote,"authoritativeInterest":false}),
            ),
            Counts => ("episodeCounts", json!({"subjectId":self.subject})),
            EpisodeSave => (
                "replaceEpisodes",
                json!({"subjectId":self.subject,"items":self.episodes,"authoritativeCollection":self.authoritative,"now":now}),
            ),
            EpisodeSubject => ("subjectID", json!({"episodeId":self.episode})),
            EpisodeLocal => (
                "updateEpisodeCollection",
                json!({"episodeId":self.episode,"type":self.typ,"batch":self.batch,"now":now}),
            ),
            SubjectLocalWrite if self.operation == Operation::UpdateRating => (
                "updateSubjectRating",
                json!({"subjectId":self.subject,"rate":self.rate,"now":now}),
            ),
            SubjectLocalWrite => (
                "updateSubjectCollectionType",
                json!({"subjectId":self.subject,"type":self.typ,"now":now}),
            ),
            Mains => ("episodes", json!({"subjectId":self.subject,"main":true})),
            PromoteLocal => (
                "updateSubjectCollectionType",
                json!({"subjectId":self.subject,"type":2,"now":now}),
            ),
            _ => return Err("progress receipt is not a database effect".into()),
        })
    }
    fn reply(&self, token: u64) -> Value {
        if self.phase == Phase::Done {
            return json!({"token":token,"sequence":self.sequence,"done":true,"success":self.success,"result":self.result});
        }
        let (effect, args) = if self.database() {
            ("database", json!({}))
        } else {
            match self.phase {
                Phase::SubjectRemote => ("subject", json!({"subjectId":self.subject})),
                Phase::Interest | Phase::WatchingLookup | Phase::PromoteLookup => {
                    ("lookup", json!({"subjectId":self.subject}))
                }
                Phase::EpisodePage => (
                    "episodes",
                    json!({"subjectId":self.subject,"offset":self.offset,"limit":1000}),
                ),
                Phase::WatchingRemote => (
                    "subjectMutation",
                    json!({"subjectId":self.subject,"type":3}),
                ),
                Phase::PromoteRemote => (
                    "subjectMutation",
                    json!({"subjectId":self.subject,"type":2}),
                ),
                Phase::SubjectRemoteWrite if self.operation == Operation::UpdateRating => (
                    "subjectMutation",
                    json!({"subjectId":self.subject,"rate":self.rate}),
                ),
                Phase::SubjectRemoteWrite => (
                    "subjectMutation",
                    json!({"subjectId":self.subject,"type":self.typ}),
                ),
                Phase::EpisodeRemote => (
                    "episodeMutation",
                    json!({"episodeId":self.episode,"type":self.typ,"batch":self.batch}),
                ),
                Phase::Notify | Phase::NotifyMember => (
                    "notify",
                    json!({"subjectId":self.subject,"membership":self.phase==Phase::NotifyMember}),
                ),
                Phase::Log => (
                    "log",
                    json!({"subjectId":self.subject,"kind":self.log,"reason":self.reason}),
                ),
                _ => unreachable!(),
            }
        };
        json!({"token":token,"sequence":self.sequence,"done":false,"effect":effect,"arguments":args})
    }
}
impl Directory {
    pub fn invalidate(&mut self) {
        self.flows.clear();
    }
    pub fn stats(&self) -> Value {
        json!({"active":self.flows.len()})
    }
    fn current(&self, input: &Receipt) -> Result<Flow, String> {
        let flow = self
            .flows
            .get(&input.token)
            .ok_or("retired progress flow")?;
        if flow.sequence != input.sequence {
            return Err("progress receipt sequence mismatch".into());
        }
        Ok(flow.clone())
    }
    fn publish(&mut self, token: u64, flow: Flow) -> Value {
        let reply = flow.reply(token);
        if flow.phase == Phase::Done {
            self.flows.remove(&token);
        } else {
            self.flows.insert(token, flow);
        }
        reply
    }
    pub fn start(&mut self, args: &Value) -> Result<Value, String> {
        let flow = Flow::new(decode(args)?)?;
        if self.flows.len() >= 1024 {
            return Err("too many progress flows".into());
        }
        let token = self
            .next
            .checked_add(1)
            .ok_or("progress tokens exhausted")?;
        self.next = token;
        Ok(self.publish(token, flow))
    }
    pub fn resume(&mut self, args: &Value) -> Result<Value, String> {
        let input: Resume = decode(args)?;
        let mut flow = self.current(&Receipt {
            token: input.token,
            sequence: input.sequence,
        })?;
        if flow.database() {
            return Err("database effects require apply".into());
        }
        flow.advance(input.response)?;
        Ok(self.publish(input.token, flow))
    }
    pub fn statement(&self, args: &Value) -> Result<(&'static str, Value), String> {
        let input: Receipt = decode(args)?;
        let flow = self.current(&input)?;
        flow.sequence
            .checked_add(1)
            .ok_or("progress sequence exhausted")?;
        let now = args["now"].as_i64().ok_or("now must be an integer")?;
        now.checked_sub(1)
            .ok_or("now is outside supported timestamp range")?;
        flow.statement(now)
    }
    pub fn applied(&mut self, args: &Value, result: Value) -> Result<Value, String> {
        let input: Receipt = decode(args)?;
        let mut flow = self.current(&input)?;
        if !flow.database() {
            return Err("progress receipt is not a database effect".into());
        }
        flow.advance(result)?;
        Ok(self.publish(input.token, flow))
    }
    pub fn fail(&mut self, args: &Value) -> Result<Value, String> {
        let input: Failure = decode(args)?;
        let mut flow = self.current(&Receipt {
            token: input.token,
            sequence: input.sequence,
        })?;
        flow.fail(&input.reason)?;
        Ok(self.publish(input.token, flow))
    }
    pub fn cancel(&mut self, args: &Value) -> Result<Value, String> {
        let input: Token = decode(args)?;
        Ok(json!(self.flows.remove(&input.token).is_some()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn watching_keeps_unknown_doing_and_completed_while_advancing_explicit_unwatched_states() {
        for typ in 0..=5 {
            let lookup: Lookup =
                decode(&json!({"state":"collected","interest":{"type":typ}})).unwrap();
            assert_eq!(
                watching_target(&lookup).unwrap(),
                if typ == 2 || typ == 3 { None } else { Some(3) }
            );
        }
        assert_eq!(
            watching_target(&decode(&json!({"state":"unknown"})).unwrap()).unwrap(),
            None
        );
        assert_eq!(
            watching_target(&decode(&json!({"state":"notCollected"})).unwrap()).unwrap(),
            Some(3)
        );
    }
    #[test]
    fn invalid_receipt_and_input_preserve_pending_state() {
        let mut d = Directory::default();
        let step = d
            .start(&json!({"operation":"ensureSubject","subjectId":1}))
            .unwrap();
        assert!(d
            .resume(&json!({"token":step["token"],"sequence":step["sequence"],"response":null}))
            .is_err());
        assert!(d
            .start(&json!({"operation":"updateRating","subjectId":1,"rate":11}))
            .is_err());
        assert_eq!(d.stats()["active"], 1);
        d.invalidate();
        assert!(d
            .statement(&json!({"token":step["token"],"sequence":step["sequence"],"now":0}))
            .is_err());
    }
    #[test]
    fn batch_reconcile_failure_preserves_first_notification_and_stops_without_membership_notification(
    ) {
        let mut f = Flow::new(
            decode(&json!({"operation":"updateEpisode","episodeId":1,"type":2,"batch":true}))
                .unwrap(),
        )
        .unwrap();
        f.advance(json!(true)).unwrap();
        f.advance(json!(9)).unwrap();
        assert!(f.phase == Phase::Notify);
        f.advance(json!(true)).unwrap();
        f.fail("offline").unwrap();
        assert_eq!(f.log, "batchReconcileFailed");
        f.advance(json!(true)).unwrap();
        assert!(f.phase == Phase::Done && f.success);
    }
    #[test]
    fn completion_only_promotes_nonempty_all_watched_mains_and_remote_doing() {
        let mut f =
            Flow::new(decode(&json!({"operation":"refreshAfterProgress","subjectId":1})).unwrap())
                .unwrap();
        f.phase = Phase::Mains;
        f.advance(json!([])).unwrap();
        assert!(f.phase == Phase::NotifyMember);
        for typ in 0..=5 {
            f.phase = Phase::Mains;
            f.advance(json!([{"collection":{"status":2}}])).unwrap();
            f.advance(json!({"state":"collected","interest":{"type":typ}}))
                .unwrap();
            assert!(
                f.phase
                    == if typ == 3 {
                        Phase::PromoteRemote
                    } else {
                        Phase::NotifyMember
                    }
            );
        }
    }
}
