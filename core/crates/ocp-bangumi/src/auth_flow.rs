//! Complete UI account/profile effect sequencing; no credentials or profile
//! payloads are retained. Account counters share the composition-root lock.
use crate::account::Account;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Directory {
    next: u64,
    flows: BTreeMap<u64, Flow>,
}
#[derive(Debug)]
pub struct Error(pub i32, pub String);
fn invalid(message: impl Into<String>) -> Error {
    Error(1002, message.into())
}
fn retired() -> Error {
    Error(1003, "authentication flow retired".into())
}
fn decode<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T, Error> {
    serde_json::from_value(value.clone()).map_err(|e| invalid(e.to_string()))
}
#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum Operation {
    Exchange,
    RefreshProfile,
    Logout,
    InvalidateSession,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Start {
    operation: Operation,
    #[serde(default)]
    authenticated: bool,
    expected_generation: Option<u64>,
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
struct Token {
    token: u64,
}
#[derive(Deserialize)]
struct ExchangeReceipt {
    generation: u64,
    identity: u64,
}
#[derive(Deserialize)]
struct Cleared {
    generation: Option<u64>,
}
#[derive(Clone, Copy, PartialEq)]
enum Phase {
    RetireWork,
    Exchange,
    FetchProfile,
    CommitProfile,
    ClearProfile,
    ClearCredentials,
    ClearDatabase,
    Rollback,
    Done,
}
#[derive(Clone)]
struct Flow {
    operation: Operation,
    revision: u64,
    identity: Option<u64>,
    generation: Option<u64>,
    phase: Phase,
    sequence: u64,
    success: bool,
    result: bool,
}
impl Flow {
    fn current(&self, account: &Account) -> bool {
        self.revision == account.operation_revision()
            && self
                .identity
                .is_none_or(|id| id == account.identity_generation())
    }
    fn acknowledge(response: &Value) -> Result<(), Error> {
        if response != &json!(true) {
            return Err(invalid("authentication effect requires acknowledgement"));
        }
        Ok(())
    }
    fn finish(&mut self, success: bool, result: bool) {
        self.phase = Phase::Done;
        self.success = success;
        self.result = result;
    }
    fn advance(&mut self, response: &Value, account: &mut Account) -> Result<(), Error> {
        use Phase::*;
        match self.phase {
            RetireWork => {
                Self::acknowledge(response)?;
                self.phase = match self.operation {
                    Operation::Exchange => Phase::Exchange,
                    Operation::RefreshProfile => FetchProfile,
                    Operation::Logout | Operation::InvalidateSession => ClearProfile,
                };
            }
            Phase::Exchange => {
                let receipt: ExchangeReceipt = decode(response)?;
                if receipt.identity != account.identity_generation() {
                    return Err(retired());
                }
                self.generation = Some(receipt.generation);
                self.identity = Some(receipt.identity);
                self.phase = FetchProfile;
            }
            FetchProfile => {
                Self::acknowledge(response)?;
                self.phase = CommitProfile;
            }
            CommitProfile => {
                Self::acknowledge(response)?;
                self.finish(true, true);
            }
            ClearProfile => {
                Self::acknowledge(response)?;
                if self.operation == Operation::InvalidateSession {
                    self.finish(true, true);
                } else {
                    self.phase = ClearCredentials;
                }
            }
            ClearCredentials => {
                let cleared: Cleared = decode(response)?;
                if cleared
                    .generation
                    .is_none_or(|id| id != account.credential_generation())
                {
                    self.finish(true, false);
                } else if self.operation == Operation::InvalidateSession {
                    self.revision = account
                        .call("operation.begin", &json!({}))
                        .map_err(invalid)?
                        .as_u64()
                        .ok_or_else(|| invalid("invalid operation revision"))?;
                    self.phase = RetireWork;
                } else {
                    self.phase = ClearDatabase;
                }
            }
            ClearDatabase => {
                Self::acknowledge(response)?;
                self.finish(true, true);
            }
            Rollback => {
                let _: Cleared = decode(response)?;
                self.finish(false, false);
            }
            Done => return Err(retired()),
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("authentication receipt exhausted"))?;
        Ok(())
    }
    fn fail(&mut self) -> Result<(), Error> {
        if self.operation == Operation::Exchange
            && matches!(self.phase, Phase::FetchProfile | Phase::CommitProfile)
        {
            // The rollback itself changes identity; retain only its operation guard.
            self.identity = None;
            self.phase = Phase::Rollback;
        } else if self.phase == Phase::ClearDatabase {
            self.finish(true, true);
        } else {
            self.finish(false, false);
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("authentication receipt exhausted"))?;
        Ok(())
    }
    fn reply(&self, token: u64) -> Value {
        if self.phase == Phase::Done {
            return json!({"token":token,"sequence":self.sequence,"operationRevision":self.revision,
                "done":true,"success":self.success,"result":self.result});
        }
        let effect = match self.phase {
            Phase::RetireWork => "retireWork",
            Phase::Exchange => "exchange",
            Phase::FetchProfile => "fetchProfile",
            Phase::CommitProfile => "commitProfile",
            Phase::ClearProfile => "clearProfile",
            Phase::ClearCredentials | Phase::Rollback => "clearCredentials",
            Phase::ClearDatabase => "clearDatabase",
            Phase::Done => unreachable!(),
        };
        json!({"token":token,"sequence":self.sequence,"operationRevision":self.revision,
            "done":false,"effect":effect,"arguments":{"operationRevision":self.revision,
                "expectedGeneration":self.generation},"cleanup":self.phase==Phase::Rollback})
    }
}
impl Directory {
    pub fn retain_account(&mut self, account: &Account) {
        self.flows.retain(|_, flow| flow.current(account));
    }
    pub fn stats(&self) -> Value {
        json!({"active":self.flows.len()})
    }
    pub fn validate(&mut self, args: &Value, account: &Account) -> Result<Value, Error> {
        self.current(&decode::<Receipt>(args)?, account)?;
        Ok(json!(true))
    }
    fn current(&mut self, receipt: &Receipt, account: &Account) -> Result<Flow, Error> {
        let flow = self.flows.get(&receipt.token).ok_or_else(retired)?;
        if flow.sequence != receipt.sequence {
            return Err(invalid("authentication receipt sequence mismatch"));
        }
        if !flow.current(account) {
            self.flows.remove(&receipt.token);
            return Err(retired());
        }
        Ok(flow.clone())
    }
    fn publish(&mut self, token: u64, flow: Flow) -> Value {
        let result = flow.reply(token);
        if flow.phase == Phase::Done {
            self.flows.remove(&token);
        } else {
            self.flows.insert(token, flow);
        }
        result
    }
    pub fn start(&mut self, args: &Value, account: &mut Account) -> Result<Value, Error> {
        let input: Start = decode(args)?;
        let passive = input.operation == Operation::InvalidateSession;
        if passive && input.authenticated && input.expected_generation.is_none() {
            return Err(invalid("missing expectedGeneration"));
        }
        if passive && self.flows.len() >= 1024 {
            return Err(invalid("too many authentication flows"));
        }
        let token = self
            .next
            .checked_add(1)
            .ok_or_else(|| invalid("authentication tokens exhausted"))?;
        let revision = if passive {
            account.operation_revision()
        } else {
            account
                .call("operation.begin", &json!({}))
                .map_err(invalid)?
                .as_u64()
                .ok_or_else(|| invalid("invalid operation revision"))?
        };
        self.retain_account(account);
        self.next = token;
        let flow = Flow {
            operation: input.operation,
            revision,
            identity: (input.operation == Operation::RefreshProfile)
                .then(|| account.identity_generation()),
            generation: input.expected_generation,
            phase: if passive {
                if input.authenticated {
                    Phase::ClearCredentials
                } else {
                    Phase::Done
                }
            } else {
                Phase::RetireWork
            },
            sequence: 1,
            success: true,
            result: false,
        };
        Ok(self.publish(token, flow))
    }
    pub fn resume(&mut self, args: &Value, account: &mut Account) -> Result<Value, Error> {
        let input: Resume = decode(args)?;
        let mut flow = self.current(
            &Receipt {
                token: input.token,
                sequence: input.sequence,
            },
            account,
        )?;
        flow.sequence
            .checked_add(1)
            .ok_or_else(|| invalid("authentication receipt exhausted"))?;
        if let Err(error) = flow.advance(&input.response, account) {
            if error.0 == 1003 {
                self.flows.remove(&input.token);
            }
            return Err(error);
        }
        self.retain_account(account);
        Ok(self.publish(input.token, flow))
    }
    pub fn fail(&mut self, args: &Value, account: &Account) -> Result<Value, Error> {
        let input: Receipt = decode(args)?;
        let mut flow = self.current(&input, account)?;
        flow.fail()?;
        Ok(self.publish(input.token, flow))
    }
    pub fn cancel(&mut self, args: &Value) -> Result<Value, Error> {
        Ok(json!(self
            .flows
            .remove(&decode::<Token>(args)?.token)
            .is_some()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_exhaustion_and_invalid_start_do_not_advance_the_account() {
        let (mut d, mut a) = (Directory::default(), Account::default());
        d.next = u64::MAX;
        assert_eq!(
            d.start(&json!({"operation":"logout"}), &mut a)
                .err()
                .unwrap()
                .0,
            1002
        );
        assert_eq!(a.operation_revision(), 0);
        d.next = 0;
        assert_eq!(
            d.start(
                &json!({"operation":"invalidateSession","authenticated":true}),
                &mut a
            )
            .err()
            .unwrap()
            .0,
            1002
        );
        assert_eq!(a.operation_revision(), 0);
    }
    fn resume(d: &mut Directory, a: &mut Account, step: &Value, response: Value) -> Value {
        d.resume(
            &json!({"token":step["token"],"sequence":step["sequence"],"response":response}),
            a,
        )
        .unwrap()
    }
    #[test]
    fn login_failure_clears_only_its_generation_and_keeps_original_failure() {
        let (mut d, mut a) = (Directory::default(), Account::default());
        let start = d.start(&json!({"operation":"exchange"}), &mut a).unwrap();
        let exchange = resume(&mut d, &mut a, &start, json!(true));
        let profile = resume(
            &mut d,
            &mut a,
            &exchange,
            json!({"generation":7,"identity":0}),
        );
        let rollback = d
            .fail(
                &json!({"token":profile["token"],"sequence":profile["sequence"]}),
                &a,
            )
            .unwrap();
        assert_eq!(rollback["arguments"]["expectedGeneration"], 7);
        assert_eq!(rollback["cleanup"], true);
        let done = resume(&mut d, &mut a, &rollback, json!({"generation":null}));
        assert_eq!(done["success"], false);
        assert_eq!(d.stats()["active"], 0);
        let start = d.start(&json!({"operation":"exchange"}), &mut a).unwrap();
        let exchange = resume(&mut d, &mut a, &start, json!(true));
        let args = json!({"token":exchange["token"],"sequence":exchange["sequence"],"response":{"generation":0,"identity":u64::MAX}});
        assert_eq!(d.resume(&args, &mut a).err().unwrap().0, 1003);
        assert_eq!(d.stats()["active"], 0);
        assert_eq!(
            d.validate(
                &json!({"token":exchange["token"],"sequence":exchange["sequence"]}),
                &a
            )
            .err()
            .unwrap()
            .0,
            1003
        );
    }
    #[test]
    fn passive_invalidation_requires_current_cleared_generation_before_new_operation() {
        let (mut d, mut a) = (Directory::default(), Account::default());
        let before = a.operation_revision();
        let step=d.start(&json!({"operation":"invalidateSession","authenticated":true,"expectedGeneration":0}),&mut a).unwrap();
        a.call("invalidate", &json!({"generation":0})).unwrap();
        let work = resume(&mut d, &mut a, &step, json!({"generation":1}));
        assert_eq!(work["effect"], "retireWork");
        assert_eq!(a.operation_revision(), before + 1);
        let clear = resume(&mut d, &mut a, &work, json!(true));
        assert_eq!(clear["effect"], "clearProfile");
        assert_eq!(resume(&mut d, &mut a, &clear, json!(true))["done"], true);
    }
    #[test]
    fn stale_profile_and_bad_acknowledgements_cannot_advance() {
        let (mut d, mut a) = (Directory::default(), Account::default());
        let step = d
            .start(&json!({"operation":"refreshProfile"}), &mut a)
            .unwrap();
        let args = json!({"token":step["token"],"sequence":step["sequence"],"response":false});
        assert_eq!(d.resume(&args, &mut a).err().unwrap().0, 1002);
        let profile = resume(&mut d, &mut a, &step, json!(true));
        a.call("invalidate", &json!({})).unwrap();
        assert_eq!(
            d.resume(
                &json!({"token":profile["token"],"sequence":profile["sequence"],"response":true}),
                &mut a
            )
            .err()
            .unwrap()
            .0,
            1003
        );
        assert_eq!(d.stats()["active"], 0);
    }
    #[test]
    fn newer_login_retires_prior_flow_and_logout_ignores_database_failure() {
        let (mut d, mut a) = (Directory::default(), Account::default());
        let old = d.start(&json!({"operation":"exchange"}), &mut a).unwrap();
        let logout = d.start(&json!({"operation":"logout"}), &mut a).unwrap();
        assert_eq!(d.cancel(&json!({"token":old["token"]})).unwrap(), false);
        let clear = resume(&mut d, &mut a, &logout, json!(true));
        let credentials = resume(&mut d, &mut a, &clear, json!(true));
        let database = resume(&mut d, &mut a, &credentials, json!({"generation":0}));
        let done = d
            .fail(
                &json!({"token":database["token"],"sequence":database["sequence"]}),
                &a,
            )
            .unwrap();
        assert_eq!(done["success"], true);
        assert_eq!(d.stats()["active"], 0);
    }
}
