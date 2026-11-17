//! Retained request/auth replay sequencing. Bytes, tokens, jitter, sleeps and
//! network/account work remain host effects; raw and named retry owners differ.
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Directory {
    next: u64,
    flows: BTreeMap<u64, Flow>,
}
pub struct Error(pub i32, pub String);
fn invalid(message: impl Into<String>) -> Error {
    Error(1002, message.into())
}
fn retired() -> Error {
    Error(1003, "request flow retired".into())
}
fn decode<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T, Error> {
    serde_json::from_value(value.clone()).map_err(|e| invalid(e.to_string()))
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Raw,
    Named,
}
#[derive(Deserialize)]
struct Start {
    kind: Kind,
    revision: u64,
    authorized: bool,
    method: String,
    idempotent: Option<bool>,
}
#[derive(Deserialize)]
struct Token {
    token: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Resume {
    token: u64,
    sequence: u64,
    revision: u64,
    outcome: Outcome,
    token_changed: Option<bool>,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Outcome {
    Success,
    Unauthorized,
    Retryable,
    Fatal,
    Ready,
}
#[derive(Clone, Copy)]
enum Phase {
    Send { replay: bool },
    LatestToken,
    Refresh,
    Sleep,
    Done { success: bool },
}
#[derive(Clone)]
struct Flow {
    revision: u64,
    authorized: bool,
    attempt: u8,
    retries: u8,
    sequence: u64,
    phase: Phase,
}
impl Flow {
    fn new(start: Start) -> Result<Self, Error> {
        if start.method.is_empty() {
            return Err(invalid("request method is empty"));
        }
        let idempotent = start.idempotent.unwrap_or_else(|| {
            matches!(
                start.method.to_ascii_uppercase().as_str(),
                "GET" | "HEAD" | "PUT" | "DELETE" | "OPTIONS" | "TRACE"
            )
        });
        let retries = if matches!(start.kind, Kind::Raw) && idempotent {
            2
        } else {
            0
        };
        Ok(Self {
            revision: start.revision,
            authorized: start.authorized,
            attempt: 0,
            retries,
            sequence: 0,
            phase: Phase::Send { replay: false },
        })
    }
    fn advance(&mut self, receipt: &Resume) -> Result<(), Error> {
        self.phase = match self.phase {
            Phase::Send { replay } => match receipt.outcome {
                Outcome::Success => Phase::Done { success: true },
                Outcome::Unauthorized if self.authorized && !replay => Phase::LatestToken,
                Outcome::Retryable if self.attempt < self.retries => {
                    self.attempt += 1;
                    Phase::Sleep
                }
                Outcome::Unauthorized | Outcome::Retryable | Outcome::Fatal => {
                    Phase::Done { success: false }
                }
                Outcome::Ready => return Err(invalid("send requires a network outcome")),
            },
            Phase::LatestToken => {
                if !matches!(receipt.outcome, Outcome::Ready) {
                    return Err(invalid("token effect requires ready"));
                }
                if receipt
                    .token_changed
                    .ok_or_else(|| invalid("token effect requires tokenChanged"))?
                {
                    Phase::Send { replay: true }
                } else {
                    Phase::Refresh
                }
            }
            Phase::Refresh => match receipt.outcome {
                Outcome::Success => Phase::Send { replay: true },
                // The login transport already retries its own transient failures.
                // A refresh failure must never restart the rejected-token request.
                Outcome::Unauthorized | Outcome::Retryable | Outcome::Fatal => {
                    Phase::Done { success: false }
                }
                Outcome::Ready => return Err(invalid("refresh requires an account outcome")),
            },
            Phase::Sleep => {
                if !matches!(receipt.outcome, Outcome::Ready) {
                    return Err(invalid("sleep requires ready"));
                }
                Phase::Send { replay: false }
            }
            Phase::Done { .. } => return Err(retired()),
        };
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("request sequence exhausted"))?;
        Ok(())
    }
    fn reply(&self, token: u64) -> Value {
        let mut reply = json!({"token": token, "sequence": self.sequence, "done": false});
        reply["effect"] = match self.phase {
            Phase::Send { replay } => json!({"kind": "send", "replay": replay,
                "attempt": self.attempt, "maxAttempts": self.retries + 1}),
            Phase::LatestToken => json!({"kind": "latestToken"}),
            Phase::Refresh => json!({"kind": "refresh"}),
            Phase::Sleep => json!({"kind": "sleep", "baseSeconds": 1_u8 << (self.attempt - 1),
                "minimumSeconds": f64::from(1_u8 << (self.attempt - 1)) * 0.5,
                "maximumSeconds": f64::from(1_u8 << (self.attempt - 1)) * 1.5,
                "attempt": self.attempt, "maxAttempts": self.retries + 1}),
            Phase::Done { success } => {
                reply["done"] = json!(true);
                reply["success"] = json!(success);
                Value::Null
            }
        };
        reply
    }
}
impl Directory {
    pub fn invalidate(&mut self) -> usize {
        let count = self.flows.len();
        self.flows.clear();
        count
    }
    pub fn retain_revision(&mut self, revision: u64) {
        self.flows.retain(|_, flow| flow.revision == revision);
    }
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, Error> {
        match method {
            "start" => {
                let flow = Flow::new(decode(args)?)?;
                if self.flows.len() >= 1024 {
                    return Err(invalid("too many active request flows"));
                }
                let token = self
                    .next
                    .checked_add(1)
                    .ok_or_else(|| invalid("request identifiers exhausted"))?;
                let reply = flow.reply(token);
                self.next = token;
                self.flows.insert(token, flow);
                Ok(reply)
            }
            "resume" => {
                let receipt: Resume = decode(args)?;
                let mut flow = self.flows.get(&receipt.token).ok_or_else(retired)?.clone();
                if flow.revision != receipt.revision {
                    self.flows.remove(&receipt.token);
                    return Err(retired());
                }
                if flow.sequence != receipt.sequence {
                    return Err(invalid("request receipt sequence mismatch"));
                }
                flow.advance(&receipt)?;
                let reply = flow.reply(receipt.token);
                if reply["done"] == true {
                    self.flows.remove(&receipt.token);
                } else {
                    self.flows.insert(receipt.token, flow);
                }
                Ok(reply)
            }
            "cancel" => {
                Ok(json!({"cancelled": self.flows.remove(&decode::<Token>(args)?.token).is_some()}))
            }
            "stats" => Ok(json!({"active": self.flows.len()})),
            _ => Err(invalid(format!(
                "unknown MoviePilot request flow method: {method}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn start(d: &mut Directory, kind: &str, method: &str) -> Value {
        d.call(
            "start",
            &json!({"kind":kind,"method":method,"authorized":true,"revision":0}),
        )
        .ok()
        .unwrap()
    }
    fn resume(d: &mut Directory, step: &Value, outcome: &str) -> Value {
        d.call(
            "resume",
            &json!({"token":step["token"],"sequence":step["sequence"],"revision":0,
            "outcome":outcome,"tokenChanged":false}),
        )
        .ok()
        .unwrap()
    }
    #[test]
    fn read_retries_and_backoff_are_bounded_but_creations_and_named_are_one_owner() {
        let mut d = Directory::default();
        let mut read = start(&mut d, "raw", "get");
        for base in [1, 2] {
            read = resume(&mut d, &read, "retryable");
            assert_eq!(read["effect"]["baseSeconds"], base);
            assert_eq!(read["effect"]["minimumSeconds"], f64::from(base) * 0.5);
            assert_eq!(read["effect"]["maximumSeconds"], f64::from(base) * 1.5);
            read = resume(&mut d, &read, "ready");
        }
        assert_eq!(resume(&mut d, &read, "retryable")["success"], false);
        for (kind, method) in [("raw", "POST"), ("raw", "PATCH"), ("named", "GET")] {
            let step = start(&mut d, kind, method);
            assert_eq!(resume(&mut d, &step, "retryable")["done"], true);
        }
    }
    #[test]
    fn failed_refresh_cannot_restart_raw_request_and_replay_401_is_terminal() {
        let mut d = Directory::default();
        for outcome in ["retryable", "unauthorized", "fatal"] {
            let step = start(&mut d, "raw", "GET");
            let step = resume(&mut d, &step, "unauthorized");
            let step = resume(&mut d, &step, "ready");
            assert_eq!(step["effect"]["kind"], "refresh");
            assert_eq!(resume(&mut d, &step, outcome)["done"], true);
        }
        let step = start(&mut d, "raw", "POST");
        let step = resume(&mut d, &step, "unauthorized");
        let step = resume(&mut d, &step, "ready");
        let step = resume(&mut d, &step, "success");
        assert_eq!(step["effect"]["replay"], true);
        assert_eq!(resume(&mut d, &step, "unauthorized")["done"], true);
    }
    #[test]
    fn bad_receipts_do_not_advance_and_configuration_change_retires() {
        let mut d = Directory::default();
        let step = start(&mut d, "raw", "GET");
        assert!(d
            .call(
                "resume",
                &json!({"token":step["token"],"sequence":0,"revision":0,"outcome":"ready"})
            )
            .is_err());
        assert_eq!(resume(&mut d, &step, "success")["success"], true);
        let step = start(&mut d, "raw", "GET");
        assert_eq!(
            d.call(
                "resume",
                &json!({"token":step["token"],"sequence":0,"revision":1,"outcome":"success"})
            )
            .err()
            .unwrap()
            .0,
            1003
        );
        assert_eq!(d.call("stats", &json!({})).ok().unwrap()["active"], 0);
    }
    #[test]
    fn cancellation_directory_bound_and_identifier_exhaustion_preserve_other_flows() {
        let mut d = Directory::default();
        for _ in 0..1024 {
            start(&mut d, "raw", "GET");
        }
        assert!(d
            .call(
                "start",
                &json!({"kind":"raw","method":"GET","authorized":true,"revision":0})
            )
            .is_err());
        assert_eq!(d.invalidate(), 1024);
        d.next = u64::MAX;
        assert!(d
            .call(
                "start",
                &json!({"kind":"raw","method":"GET","authorized":true,"revision":0})
            )
            .is_err());
        assert_eq!(d.flows.len(), 0);
    }
}
