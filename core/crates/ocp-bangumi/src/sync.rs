//! Resumable collection/episode synchronization. Database writes are applied by
//! the composition root under the same lock as receipt and account retirement.
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};

#[derive(Default)]
pub struct Directory {
    next: u64,
    epoch: u64,
    flows: BTreeMap<u64, Flow>,
}
#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum Operation {
    Collections,
    Episodes,
    Reconcile,
    AllCollections,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Start {
    operation: Operation,
    #[serde(default)]
    since: i64,
    #[serde(default)]
    started_at: i64,
    #[serde(default)]
    force: bool,
    #[serde(default = "concurrency")]
    max_concurrent: i64,
    #[serde(default)]
    authoritative_collection: bool,
    subject_id: Option<i64>,
    parent_token: Option<u64>,
    parent_job: Option<u64>,
}
fn concurrency() -> i64 {
    4
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
#[serde(rename_all = "camelCase")]
struct Completed {
    token: u64,
    job_id: u64,
    succeeded: bool,
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
fn decode<T: serde::de::DeserializeOwned>(v: &Value) -> Result<T, String> {
    serde_json::from_value(v.clone()).map_err(|e| e.to_string())
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Reset,
    CollectionPage,
    CollectionSave,
    Stamp,
    Targets,
    Batch,
    EpisodePage,
    EpisodeSave,
    Done,
}
#[derive(Clone)]
struct Flow {
    operation: Operation,
    phase: Phase,
    sequence: u64,
    since: i64,
    started_at: i64,
    count: i64,
    offset: i64,
    total: i64,
    subject: i64,
    authoritative: bool,
    items: Vec<Value>,
    maximum: usize,
    pending: VecDeque<i64>,
    running: BTreeMap<u64, i64>,
    next_job: u64,
    filled: i64,
    issued: Vec<Value>,
    parent: Option<(u64, u64)>,
}
impl Flow {
    fn new(start: Start) -> Result<Self, String> {
        let phase = match start.operation {
            Operation::AllCollections if start.force => Phase::Reset,
            Operation::AllCollections | Operation::Collections => Phase::CollectionPage,
            Operation::Episodes => Phase::EpisodePage,
            Operation::Reconcile => Phase::Targets,
        };
        let subject = start.subject_id.unwrap_or(0);
        if start.operation == Operation::Episodes && start.subject_id.is_none() {
            return Err("missing subjectId".into());
        }
        let parent = match (start.parent_token, start.parent_job) {
            (None, None) => None,
            (Some(token), Some(job)) if start.operation == Operation::Episodes => {
                Some((token, job))
            }
            _ => return Err("invalid sync parent".into()),
        };
        let since = if start.operation == Operation::AllCollections {
            if start.force || start.since <= 0 {
                0
            } else {
                start.since.saturating_sub(300).max(0)
            }
        } else {
            start.since
        };
        Ok(Self {
            operation: start.operation,
            phase,
            sequence: 1,
            since,
            started_at: start.started_at,
            count: 0,
            offset: 0,
            total: 0,
            subject,
            authoritative: start.authoritative_collection,
            items: vec![],
            maximum: usize::try_from(start.max_concurrent.max(1)).unwrap_or(usize::MAX),
            pending: VecDeque::new(),
            running: BTreeMap::new(),
            next_job: 0,
            filled: 0,
            issued: vec![],
            parent,
        })
    }
    fn after_collections(&mut self) {
        self.phase = if self.operation == Operation::AllCollections {
            Phase::Stamp
        } else {
            Phase::Done
        };
    }
    fn advance(&mut self, response: Value) -> Result<(), String> {
        match self.phase {
            Phase::Reset => self.phase = Phase::CollectionPage,
            Phase::CollectionPage => {
                let page: Page = decode(&response)?;
                if page.data.is_empty() {
                    self.after_collections();
                } else {
                    self.items = page.data;
                    self.total = page.total;
                    self.phase = Phase::CollectionSave;
                }
            }
            Phase::CollectionSave => {
                self.count = self
                    .count
                    .checked_add(
                        self.items
                            .len()
                            .try_into()
                            .map_err(|_| "collection count overflow")?,
                    )
                    .ok_or("collection count overflow")?;
                self.items.clear();
                self.offset = self
                    .offset
                    .checked_add(100)
                    .ok_or("collection offset overflow")?;
                if self.offset >= self.total {
                    self.after_collections();
                } else {
                    self.phase = Phase::CollectionPage;
                }
            }
            Phase::Stamp => self.phase = Phase::Targets,
            Phase::Targets => {
                self.pending = decode::<Vec<i64>>(&response)?.into();
                self.phase = Phase::Batch;
                self.issue_jobs()?;
                if self.running.is_empty() {
                    self.phase = Phase::Done;
                }
            }
            Phase::EpisodePage => {
                let page: Page = decode(&response)?;
                let empty = page.data.is_empty();
                self.items.extend(page.data);
                self.offset = self
                    .offset
                    .checked_add(1000)
                    .ok_or("episode offset overflow")?;
                if empty || self.offset >= page.total {
                    self.phase = Phase::EpisodeSave;
                }
            }
            Phase::EpisodeSave => self.phase = Phase::Done,
            Phase::Batch | Phase::Done => return Err("sync phase does not accept resume".into()),
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("sync sequence exhausted")?;
        Ok(())
    }
    fn issue_jobs(&mut self) -> Result<(), String> {
        self.issued.clear();
        while self.running.len() < self.maximum {
            let Some(subject) = self.pending.pop_front() else {
                break;
            };
            self.next_job = self
                .next_job
                .checked_add(1)
                .ok_or("sync job ID exhausted")?;
            self.running.insert(self.next_job, subject);
            self.issued
                .push(json!({"id":self.next_job,"subjectId":subject}));
        }
        Ok(())
    }
    fn reply(&self, token: u64) -> Value {
        if self.phase == Phase::Done {
            let result = match self.operation {
                Operation::Episodes => json!(true),
                Operation::Reconcile => json!(self.filled),
                _ => json!(self.count),
            };
            return json!({"token":token,"sequence":self.sequence,"done":true,"result":result});
        }
        let (effect, args) = match self.phase {
            Phase::Reset => ("timestamp", json!({"value":0})),
            Phase::CollectionPage => (
                "collections",
                json!({"since":self.since,"limit":100,"offset":self.offset}),
            ),
            Phase::CollectionSave => (
                "saveSubjects",
                json!({"count":self.items.len(),"authoritativeInterest":true}),
            ),
            Phase::Stamp => ("timestamp", json!({"value":self.started_at})),
            Phase::Targets => ("targets", json!({})),
            Phase::Batch => (
                "episodeBatch",
                json!({"jobs":self.issued,"authoritativeCollection":self.authoritative}),
            ),
            Phase::EpisodePage => (
                "episodes",
                json!({"subjectId":self.subject,"limit":1000,"offset":self.offset}),
            ),
            Phase::EpisodeSave => (
                "replaceEpisodes",
                json!({"subjectId":self.subject,"count":self.items.len(),"authoritativeCollection":self.authoritative}),
            ),
            Phase::Done => unreachable!(),
        };
        json!({"token":token,"sequence":self.sequence,"done":false,"effect":effect,"arguments":args})
    }
}
impl Directory {
    fn current(&self, token: u64) -> Result<&Flow, String> {
        let flow = self.flows.get(&token).ok_or("retired sync token")?;
        if let Some((parent, job)) = flow.parent {
            let owner = self.flows.get(&parent).ok_or("retired sync parent")?;
            if owner.running.get(&job) != Some(&flow.subject) {
                return Err("retired sync job".into());
            }
        }
        Ok(flow)
    }
    fn receipt(&self, token: u64, sequence: u64) -> Result<Flow, String> {
        let flow = self.current(token)?;
        if flow.sequence != sequence {
            return Err("stale sync receipt".into());
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
        if self.flows.len() >= 1024 {
            return Err("too many active sync flows".into());
        }
        let flow = Flow::new(decode(args)?)?;
        if let Some((parent, job)) = flow.parent {
            let owner = self.current(parent)?;
            if owner.running.get(&job) != Some(&flow.subject)
                || self.flows.values().any(|f| f.parent == flow.parent)
            {
                return Err("invalid or already running sync child".into());
            }
        }
        let token = self.next.checked_add(1).ok_or("sync tokens exhausted")?;
        self.next = token;
        Ok(self.publish(token, flow))
    }
    pub fn resume(&mut self, args: &Value) -> Result<Value, String> {
        let input: Resume = decode(args)?;
        let mut flow = self.receipt(input.token, input.sequence)?;
        if matches!(flow.phase, Phase::CollectionSave | Phase::EpisodeSave) {
            return Err("database effects require apply".into());
        }
        flow.advance(input.response)?;
        Ok(self.publish(input.token, flow))
    }
    pub fn mutation(&self, args: &Value) -> Result<(&'static str, Value), String> {
        let input: Receipt = decode(args)?;
        let flow = self.receipt(input.token, input.sequence)?;
        let method = match flow.phase {
            Phase::CollectionSave => "saveSubjects",
            Phase::EpisodeSave => "replaceEpisodes",
            _ => return Err("sync receipt is not a database effect".into()),
        };
        let mut data = match flow.phase {
            Phase::CollectionSave => json!({"items":flow.items,"authoritativeInterest":true}),
            Phase::EpisodeSave => {
                json!({"subjectId":flow.subject,"items":flow.items,"authoritativeCollection":flow.authoritative})
            }
            _ => unreachable!(),
        };
        if flow.phase == Phase::EpisodeSave {
            let now = args["now"].as_i64().ok_or("now must be an integer")?;
            data["now"] = json!(now);
        }
        let mut after = flow.clone();
        after.advance(Value::Null)?;
        Ok((method, data))
    }
    pub fn applied(&mut self, args: &Value) -> Result<Value, String> {
        let input: Receipt = decode(args)?;
        let mut flow = self.receipt(input.token, input.sequence)?;
        flow.advance(Value::Null)?;
        Ok(self.publish(input.token, flow))
    }
    pub fn complete(&mut self, args: &Value) -> Result<Value, String> {
        let input: Completed = decode(args)?;
        let mut flow = self.current(input.token)?.clone();
        if flow.phase != Phase::Batch || flow.running.remove(&input.job_id).is_none() {
            return Err("retired sync job completion".into());
        }
        if self
            .flows
            .values()
            .any(|f| f.parent == Some((input.token, input.job_id)))
        {
            return Err("sync child has not finished".into());
        }
        if input.succeeded {
            flow.filled = flow.filled.checked_add(1).ok_or("sync count overflow")?;
        }
        flow.issue_jobs()?;
        if flow.running.is_empty() {
            flow.phase = Phase::Done;
        }
        flow.sequence = flow
            .sequence
            .checked_add(1)
            .ok_or("sync sequence exhausted")?;
        Ok(self.publish(input.token, flow))
    }
    pub fn cancel(&mut self, args: &Value) -> Result<Value, String> {
        let token = decode::<Token>(args)?.token;
        let existed = self.flows.remove(&token).is_some();
        let children: Vec<u64> = self
            .flows
            .iter()
            .filter_map(|(id, f)| (f.parent.is_some_and(|p| p.0 == token)).then_some(*id))
            .collect();
        for id in children {
            self.cancel(&json!({"token":id}))?;
        }
        Ok(json!(existed))
    }
    pub fn invalidate(&mut self) {
        self.flows.clear();
        self.epoch = self.epoch.wrapping_add(1);
    }
    pub fn stats(&self) -> Value {
        json!({"active":self.flows.len(),"epoch":self.epoch})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn resume(d: &mut Directory, s: &Value, response: Value) -> Value {
        d.resume(&json!({"token":s["token"],"sequence":s["sequence"],"response":response}))
            .unwrap()
    }
    #[test]
    fn collection_pages_require_actual_writes_and_single_use_receipts() {
        let mut d = Directory::default();
        let page = d
            .start(&json!({"operation":"collections","since":9}))
            .unwrap();
        let write = resume(&mut d, &page, json!({"data":[{"id":1}],"total":101}));
        assert!(d
            .resume(&json!({"token":write["token"],"sequence":write["sequence"],"response":null}))
            .is_err());
        let args = json!({"token":write["token"],"sequence":write["sequence"]});
        assert_eq!(d.mutation(&args).unwrap().0, "saveSubjects");
        let next = d.applied(&args).unwrap();
        assert_eq!(next["arguments"]["offset"], 100);
        assert!(d.applied(&args).is_err());
        let done = resume(&mut d, &next, json!({"data":[],"total":101}));
        assert_eq!(done["result"], 1);
        assert_eq!(d.stats()["active"], 0);
    }
    #[test]
    fn episode_empty_tail_still_replaces_the_full_accumulated_set() {
        let mut d = Directory::default();
        let page=d.start(&json!({"operation":"episodes","subjectId":i64::MAX,"authoritativeCollection":true})).unwrap();
        let next = resume(
            &mut d,
            &page,
            json!({"data":[{"id":i64::MAX}],"total":2000}),
        );
        let write = resume(&mut d, &next, json!({"data":[],"total":2000}));
        assert_eq!(write["effect"], "replaceEpisodes");
        let args = json!({"token":write["token"],"sequence":write["sequence"],"now":123});
        assert_eq!(d.mutation(&args).unwrap().1["items"][0]["id"], i64::MAX);
        d.invalidate();
        assert!(d.mutation(&args).is_err());
    }
    #[test]
    fn batch_slides_one_slot_and_cancels_descendants() {
        let mut d = Directory::default();
        let targets = d
            .start(&json!({"operation":"reconcile","maxConcurrent":2}))
            .unwrap();
        let batch = resume(&mut d, &targets, json!([1, 2, 3]));
        assert_eq!(batch["arguments"]["jobs"].as_array().unwrap().len(), 2);
        let token = batch["token"].as_u64().unwrap();
        let child = d
            .start(&json!({"operation":"episodes","subjectId":1,"parentToken":token,"parentJob":1}))
            .unwrap();
        assert!(d
            .complete(&json!({"token":token,"jobId":1,"succeeded":true}))
            .is_err());
        d.cancel(&json!({"token":child["token"]})).unwrap();
        let next = d
            .complete(&json!({"token":token,"jobId":1,"succeeded":false}))
            .unwrap();
        assert_eq!(next["arguments"]["jobs"][0]["subjectId"], 3);
        assert!(d
            .complete(&json!({"token":token,"jobId":1,"succeeded":false}))
            .is_err());
        let child = d
            .start(&json!({"operation":"episodes","subjectId":2,"parentToken":token,"parentJob":2}))
            .unwrap();
        d.cancel(&json!({"token":token})).unwrap();
        assert!(d.current(child["token"].as_u64().unwrap()).is_err());
        assert_eq!(d.stats()["active"], 0);
    }
    #[test]
    fn full_sync_uses_start_time_overlap_and_stamp_before_reconcile() {
        let mut d = Directory::default();
        let start = d
            .start(&json!({"operation":"allCollections","since":400,"startedAt":500}))
            .unwrap();
        assert_eq!(start["arguments"]["since"], 100);
        let stamp = resume(&mut d, &start, json!({"data":[],"total":0}));
        assert_eq!(stamp["arguments"]["value"], 500);
        let targets = resume(&mut d, &stamp, json!(true));
        assert_eq!(targets["effect"], "targets");
        assert_eq!(resume(&mut d, &targets, json!([]))["result"], 0);
    }
}
