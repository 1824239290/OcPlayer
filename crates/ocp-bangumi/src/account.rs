//! Retained credential and account-operation policy. Secrets, clocks, tasks and
//! platform sessions remain effects; none of them are stored in this directory.
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Default)]
pub struct Account {
    generation: u64,
    exchange: u64,
    refresh: u64,
    active_refresh: Option<(u64, u64)>,
    pending_state: Option<String>,
    operation: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    generation: u64,
}
#[derive(Deserialize)]
struct OAuthState {
    state: String,
}
#[derive(Deserialize)]
struct Commit {
    kind: CommitKind,
    generation: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum CommitKind {
    OAuth,
    Refresh,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Access {
    present: bool,
    expires_at: Option<f64>,
    now: f64,
}
impl Access {
    fn expired(&self) -> Result<bool, String> {
        if !self.now.is_finite() || self.expires_at.is_some_and(|v| !v.is_finite()) {
            return Err("invalid credential clock".into());
        }
        Ok(self
            .expires_at
            .is_none_or(|expiry| self.now + 60.0 > expiry))
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    #[serde(flatten)]
    access: Access,
    session_generation: Option<u64>,
}
#[derive(Deserialize)]
struct RefreshFailure {
    generation: u64,
    kind: FailureKind,
}
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum FailureKind {
    Cancelled,
    Unauthorized,
}

fn decode<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, String> {
    serde_json::from_value(args.clone()).map_err(|e| e.to_string())
}

impl Account {
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        Ok(match method {
            "snapshot" => json!({"generation":self.generation,"exchangeGeneration":self.exchange,
                "refreshGeneration":self.refresh,"refreshActive":self.active_refresh.is_some(),
                "operationRevision":self.operation}),
            "current" => json!(decode::<Expected>(args)?.generation == self.generation),
            "oauth.prepare" => {
                let state = decode::<OAuthState>(args)?.state;
                if state.is_empty() || state.len() > 4096 {
                    return Err("invalid OAuth state".into());
                }
                self.pending_state = Some(state);
                json!(true)
            }
            "oauth.consume" => {
                let state = decode::<OAuthState>(args)?.state;
                // Consume before the network await. A replay cannot issue another
                // token request, and an old completion cannot erase a newer state.
                let accepted = self.pending_state.take().as_ref() == Some(&state);
                if accepted {
                    self.exchange = self.exchange.wrapping_add(1);
                }
                json!({"accepted":accepted,"generation":self.exchange})
            }
            "access" => {
                let access = decode::<Access>(args)?;
                let expired = access.expired()?;
                json!({"action":if !access.present { "missing" } else if expired { "refresh" } else { "reuse" },
                    "generation":self.generation})
            }
            "session" => {
                let session = decode::<Session>(args)?;
                json!(
                    session.access.present
                        && !session.access.expired()?
                        && session.session_generation == Some(self.generation)
                )
            }
            "refresh.claim" => {
                let (id, generation, joined) = if let Some((id, generation)) = self.active_refresh {
                    (id, generation, true)
                } else {
                    self.refresh = self.refresh.wrapping_add(1);
                    self.active_refresh = Some((self.refresh, self.generation));
                    (self.refresh, self.generation, false)
                };
                json!({"id":id,"generation":generation,"joined":joined,"timeoutSeconds":15})
            }
            "refresh.finish" => {
                let id = decode::<Expected>(args)?.generation;
                let accepted = self.active_refresh.is_some_and(|r| r.0 == id);
                if accepted {
                    self.active_refresh = None;
                }
                json!(accepted)
            }
            "refresh.failure" => {
                let failure = decode::<RefreshFailure>(args)?;
                json!(match failure.kind {
                    FailureKind::Cancelled if failure.generation != self.refresh => "stale",
                    FailureKind::Cancelled => "timeout",
                    FailureKind::Unauthorized if failure.generation != self.generation => "stale",
                    FailureKind::Unauthorized => "login",
                })
            }
            "commit" => {
                let commit = decode::<Commit>(args)?;
                let accepted = match commit.kind {
                    CommitKind::OAuth => commit.generation == self.exchange,
                    CommitKind::Refresh => commit.generation == self.generation,
                };
                if !accepted {
                    return Ok(json!({"accepted":false,"generation":self.generation}));
                }
                let cancel_refresh = matches!(commit.kind, CommitKind::OAuth);
                if cancel_refresh {
                    self.exchange = self.exchange.wrapping_add(1);
                    self.retire_refresh();
                }
                self.generation = self.generation.wrapping_add(1);
                json!({"accepted":true,"generation":self.generation,"cancelRefresh":cancel_refresh,
                    "cancelRequests":true,"invalidateSession":true})
            }
            "invalidate" => {
                // Validate before mutation, including null/negative/overflow.
                let expected = args
                    .get("generation")
                    .map(|_| decode::<Expected>(args))
                    .transpose()?;
                if expected.is_some_and(|e| e.generation != self.generation) {
                    return Ok(json!({"accepted":false,"generation":self.generation}));
                }
                self.generation = self.generation.wrapping_add(1);
                self.exchange = self.exchange.wrapping_add(1);
                self.retire_refresh();
                self.pending_state = None;
                json!({"accepted":true,"generation":self.generation,"cancelRefresh":true,
                    "cancelRequests":true,"invalidateSession":true})
            }
            "operation.begin" => {
                self.operation = self.operation.wrapping_add(1);
                json!(self.operation)
            }
            "operation.current" => json!(decode::<Expected>(args)?.generation == self.operation),
            _ => return Err(format!("unknown Bangumi account method: {method}")),
        })
    }
    fn retire_refresh(&mut self) {
        self.refresh = self.refresh.wrapping_add(1);
        self.active_refresh = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oauth_consumes_once_and_does_not_erase_next_state() {
        let mut a = Account::default();
        a.call("oauth.prepare", &json!({"state":"one"})).unwrap();
        let first = a.call("oauth.consume", &json!({"state":"one"})).unwrap();
        assert_eq!(first["accepted"], true);
        assert_eq!(
            a.call("oauth.consume", &json!({"state":"one"})).unwrap()["accepted"],
            false
        );
        a.call("oauth.prepare", &json!({"state":"two"})).unwrap();
        a.call(
            "commit",
            &json!({"kind":"oauth","generation":first["generation"]}),
        )
        .unwrap();
        assert_eq!(
            a.call("oauth.consume", &json!({"state":"two"})).unwrap()["accepted"],
            true
        );
        a.call("invalidate", &json!({})).unwrap();
        assert_eq!(
            a.call("commit", &json!({"kind":"oauth","generation":2}))
                .unwrap()["accepted"],
            false
        );
    }
    #[test]
    fn retired_refresh_cannot_commit_or_release_a_new_owner() {
        let mut a = Account::default();
        let first = a.call("refresh.claim", &json!({})).unwrap();
        let joined = a.call("refresh.claim", &json!({})).unwrap();
        assert_eq!(first["id"], joined["id"]);
        assert_eq!(joined["joined"], true);
        a.call("invalidate", &json!({})).unwrap();
        let second = a.call("refresh.claim", &json!({})).unwrap();
        assert_eq!(
            a.call("refresh.finish", &json!({"generation":first["id"]}))
                .unwrap(),
            false
        );
        assert_eq!(
            a.call("snapshot", &json!({})).unwrap()["refreshActive"],
            true
        );
        assert_eq!(
            a.call("commit", &json!({"kind":"refresh","generation":0}))
                .unwrap()["accepted"],
            false
        );
        assert_eq!(
            a.call(
                "refresh.failure",
                &json!({"kind":"cancelled","generation":first["id"]})
            )
            .unwrap(),
            "stale"
        );
        assert_eq!(
            a.call("refresh.finish", &json!({"generation":second["id"]}))
                .unwrap(),
            true
        );
    }
    #[test]
    fn exact_unsigned_generations_and_validation_are_atomic() {
        let mut a = Account {
            generation: u64::MAX,
            ..Default::default()
        };
        assert_eq!(
            a.call("current", &json!({"generation":u64::MAX})).unwrap(),
            true
        );
        for args in [
            json!({"generation":-1}),
            json!({"generation":null}),
            json!({"generation":1.2}),
        ] {
            assert!(a.call("invalidate", &args).is_err());
            assert_eq!(a.generation, u64::MAX);
        }
        assert_eq!(
            a.call("invalidate", &json!({"generation":u64::MAX}))
                .unwrap()["generation"],
            0
        );
    }
    #[test]
    fn session_access_and_profile_revision_policy() {
        let mut a = Account::default();
        assert_eq!(
            a.call("access", &json!({"present":false,"now":1000}))
                .unwrap()["action"],
            "missing"
        );
        assert_eq!(
            a.call(
                "access",
                &json!({"present":true,"expiresAt":1059,"now":1000})
            )
            .unwrap()["action"],
            "refresh"
        );
        assert_eq!(
            a.call(
                "session",
                &json!({"present":true,"expiresAt":1060,"now":1000,"sessionGeneration":0})
            )
            .unwrap(),
            true
        );
        let old = a.call("operation.begin", &json!({})).unwrap();
        a.call("operation.begin", &json!({})).unwrap();
        assert_eq!(
            a.call("operation.current", &json!({"generation":old}))
                .unwrap(),
            false
        );
    }
}
