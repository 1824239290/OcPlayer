//! Retained MoviePilot account policy. Platform revisions are opaque receipts;
//! credentials, tasks, storage, notifications and cookie pools remain effects.
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Clone, Default)]
pub struct Account {
    initialized: bool,
    generation: u64,
    configuration_revision: u64,
    login_id: u64,
    refresh_id: u64,
    login: Option<Claim>,
    refresh: Option<Claim>,
    exhausted: Option<u64>,
}
#[derive(Clone, Copy)]
struct Claim {
    id: u64,
    generation: u64,
    revision: u64,
    committed: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Seed {
    generation: u64,
    configuration_revision: u64,
    refresh_id: u64,
    exhausted_generation: Option<u64>,
}
#[derive(Deserialize)]
struct Revision {
    revision: u64,
}
#[derive(Deserialize)]
struct Current {
    generation: u64,
}
#[derive(Deserialize)]
struct Expected {
    generation: u64,
    revision: u64,
}
#[derive(Deserialize)]
struct Receipt {
    id: u64,
    revision: u64,
}
#[derive(Deserialize)]
struct ID {
    id: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginCommit {
    id: u64,
    revision: u64,
    token_matches: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshClaim {
    revision: u64,
    token_present: bool,
    credentials_present: bool,
}
#[derive(Deserialize)]
struct Failure {
    id: u64,
    revision: u64,
    kind: FailureKind,
}
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum FailureKind {
    Rejected,
    Transient,
    Cancelled,
}

fn decode<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, String> {
    serde_json::from_value(args.clone()).map_err(|e| e.to_string())
}
fn increment(value: &mut u64) -> Result<u64, String> {
    *value = value.checked_add(1).ok_or("account generation exhausted")?;
    Ok(*value)
}
impl Account {
    /// Invalid arguments and arithmetic exhaustion cannot partially retire an owner.
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        let mut next = self.clone();
        let reply = next.dispatch(method, args)?;
        *self = next;
        Ok(reply)
    }
    fn current_claim(&self, claim: Option<Claim>, receipt: &Receipt) -> bool {
        claim.is_some_and(|c| {
            c.id == receipt.id
                && c.revision == receipt.revision
                && c.generation == self.generation
                && !c.committed
        })
    }
    fn transition(&self) -> Value {
        json!({"generation": self.generation, "cancelRefresh": true,
            "cancelRequests": true, "clearSessions": true})
    }
    fn retire(&mut self, revision: u64) -> Result<(), String> {
        increment(&mut self.generation)?;
        increment(&mut self.refresh_id)?;
        self.configuration_revision = revision;
        self.login = None;
        self.refresh = None;
        self.exhausted = None;
        self.initialized = true;
        Ok(())
    }
    fn dispatch(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        match method {
            "seed" => {
                let seed: Seed = decode(args)?;
                if self.initialized {
                    return Err("account policy already initialized".into());
                }
                self.generation = seed.generation;
                self.configuration_revision = seed.configuration_revision;
                self.refresh_id = seed.refresh_id;
                self.exhausted = seed.exhausted_generation;
                self.initialized = true;
                Ok(self.snapshot())
            }
            "snapshot" => Ok(self.snapshot()),
            "current" => Ok(json!(
                decode::<Current>(args)?.generation == self.generation
            )),
            "clear.allowed" => {
                let expected: Expected = decode(args)?;
                Ok(json!(
                    expected.generation == self.generation
                        && expected.revision == self.configuration_revision
                ))
            }
            "invalidate" => {
                self.retire(decode::<Revision>(args)?.revision)?;
                Ok(self.transition())
            }
            "login.begin" => {
                let revision = decode::<Revision>(args)?.revision;
                self.retire(revision)?;
                let id = increment(&mut self.login_id)?;
                self.login = Some(Claim {
                    id,
                    generation: self.generation,
                    revision,
                    committed: false,
                });
                let mut reply = self.transition();
                reply["id"] = json!(id);
                Ok(reply)
            }
            "login.authorize" => Ok(json!(self.current_claim(self.login, &decode(args)?))),
            "login.commit" => {
                let receipt: LoginCommit = decode(args)?;
                let accepted = self.login.is_some_and(|c| {
                    c.id == receipt.id
                        && c.generation == self.generation
                        && !c.committed
                        && receipt.token_matches
                        && c.revision.checked_add(1) == Some(receipt.revision)
                });
                if accepted {
                    increment(&mut self.generation)?;
                    self.configuration_revision = receipt.revision;
                    self.login = None;
                    self.exhausted = None;
                }
                Ok(json!({"accepted": accepted, "generation": self.generation}))
            }
            "login.finish" => {
                let id = decode::<ID>(args)?.id;
                let accepted = self.login.is_some_and(|c| c.id == id);
                if accepted {
                    self.login = None;
                }
                Ok(json!(accepted))
            }
            "refresh.claim" => {
                let request: RefreshClaim = decode(args)?;
                if let Some(active) = self.refresh {
                    if active.revision == request.revision {
                        return Ok(json!({"action": "join", "id": active.id,
                            "generation": active.generation, "timeoutSeconds": 15,
                            "clearToken": false, "notify": false}));
                    }
                    // A changed platform configuration retires the old task's receipt.
                    self.refresh = None;
                }
                let action = if self.exhausted == Some(self.generation) {
                    "fused"
                } else if !request.credentials_present {
                    "missing"
                } else {
                    "start"
                };
                let id = if action == "start" {
                    let id = increment(&mut self.refresh_id)?;
                    self.refresh = Some(Claim {
                        id,
                        generation: self.generation,
                        revision: request.revision,
                        committed: false,
                    });
                    id
                } else {
                    self.refresh_id
                };
                self.initialized = true;
                Ok(
                    json!({"action": action, "id": id, "generation": self.generation,
                    "timeoutSeconds": 15, "clearToken": action == "missing" || (action == "fused" && request.token_present),
                    "notify": action == "fused" && request.token_present}),
                )
            }
            "refresh.authorize" => Ok(json!(self.current_claim(self.refresh, &decode(args)?))),
            "refresh.commit" => {
                let receipt: Receipt = decode(args)?;
                let accepted = self.current_claim(self.refresh, &receipt);
                if accepted {
                    increment(&mut self.generation)?;
                    self.configuration_revision = receipt.revision;
                    self.exhausted = Some(self.generation);
                    self.refresh.as_mut().unwrap().committed = true;
                }
                Ok(json!({"accepted": accepted, "generation": self.generation}))
            }
            "refresh.failure" => {
                let failure: Failure = decode(args)?;
                let accepted = self.current_claim(
                    self.refresh,
                    &Receipt {
                        id: failure.id,
                        revision: failure.revision,
                    },
                );
                let rejected = accepted && matches!(failure.kind, FailureKind::Rejected);
                if rejected {
                    self.exhausted = Some(self.generation);
                }
                Ok(json!({"accepted": accepted, "generation": self.generation,
                    "clearToken": rejected, "notify": rejected}))
            }
            "refresh.finish" => {
                let id = decode::<ID>(args)?.id;
                let accepted = self.refresh.is_some_and(|c| c.id == id);
                if accepted {
                    self.refresh = None;
                }
                Ok(json!(accepted))
            }
            _ => Err(format!("unknown MoviePilot account method: {method}")),
        }
    }
    fn snapshot(&self) -> Value {
        json!({"generation": self.generation, "configurationRevision": self.configuration_revision,
            "refreshID": self.refresh_id, "exhaustedGeneration": self.exhausted,
            "loginActive": self.login.is_some(), "refreshActive": self.refresh.is_some()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_commit_cannot_publish_after_logout_or_new_attempt() {
        let mut account = Account::default();
        let old = account
            .call("login.begin", &json!({"revision": 1}))
            .unwrap();
        assert_eq!(
            account
                .call("login.authorize", &json!({"id": old["id"], "revision": 1}))
                .unwrap(),
            true
        );
        account.call("invalidate", &json!({"revision": 3})).unwrap();
        assert_eq!(
            account
                .call(
                    "login.commit",
                    &json!({"id": old["id"], "revision": 2, "tokenMatches": true})
                )
                .unwrap()["accepted"],
            false
        );
        let new = account
            .call("login.begin", &json!({"revision": 4}))
            .unwrap();
        account
            .call("login.finish", &json!({"id": old["id"]}))
            .unwrap();
        assert_eq!(account.snapshot()["loginActive"], true);
        assert_eq!(
            account
                .call(
                    "login.commit",
                    &json!({"id": new["id"], "revision": 5, "tokenMatches": true})
                )
                .unwrap()["accepted"],
            true
        );
    }
    #[test]
    fn refresh_singleflight_fuse_and_late_release() {
        let mut a = Account::default();
        let args = json!({"revision": 0, "tokenPresent": true, "credentialsPresent": true});
        let first = a.call("refresh.claim", &args).unwrap();
        assert_eq!(a.call("refresh.claim", &args).unwrap()["action"], "join");
        let receipt = json!({"id": first["id"], "revision": 0});
        assert_eq!(
            a.call("refresh.commit", &receipt).unwrap()["accepted"],
            true
        );
        assert_eq!(a.call("refresh.claim", &args).unwrap()["action"], "join");
        a.call("refresh.finish", &json!({"id": first["id"]}))
            .unwrap();
        assert_eq!(a.call("refresh.claim", &args).unwrap()["notify"], true);
        a.call("invalidate", &json!({"revision": 1})).unwrap();
        let new = a
            .call(
                "refresh.claim",
                &json!({"revision": 1, "tokenPresent": true, "credentialsPresent": true}),
            )
            .unwrap();
        assert_eq!(
            a.call("refresh.finish", &json!({"id": first["id"]}))
                .unwrap(),
            false
        );
        assert_eq!(
            a.call(
                "refresh.authorize",
                &json!({"id": new["id"], "revision": 1})
            )
            .unwrap(),
            true
        );
    }
    #[test]
    fn transient_and_cancelled_failures_preserve_credentials() {
        let mut a = Account::default();
        let claim = a
            .call(
                "refresh.claim",
                &json!({"revision": 8, "tokenPresent": true, "credentialsPresent": true}),
            )
            .unwrap();
        for kind in ["transient", "cancelled"] {
            let reply = a
                .call(
                    "refresh.failure",
                    &json!({"id": claim["id"], "revision": 8, "kind": kind}),
                )
                .unwrap();
            assert_eq!(reply["clearToken"], false);
            assert_eq!(reply["notify"], false);
        }
        let reply = a
            .call(
                "refresh.failure",
                &json!({"id": claim["id"], "revision": 8, "kind": "rejected"}),
            )
            .unwrap();
        assert_eq!(reply["clearToken"], true);
        assert_eq!(reply["notify"], true);
    }
    #[test]
    fn overflow_and_invalid_receipts_leave_state_unchanged() {
        let mut a = Account::default();
        a.call(
            "seed",
            &json!({"generation": u64::MAX, "configurationRevision": 3, "refreshId": 0}),
        )
        .unwrap();
        let before = a.snapshot();
        assert!(a.call("login.begin", &json!({"revision": 4})).is_err());
        assert!(a.call("invalidate", &json!({"revision": -1})).is_err());
        assert_eq!(a.snapshot(), before);
    }
}
