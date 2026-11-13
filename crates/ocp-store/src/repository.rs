//! Retained media-repository projections and refresh ownership. Payloads retain
//! their platform Codable schema; the platform only keeps Swift task handles.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;
mod composition;
mod progress;

// Swift String/Hashable uses canonical equivalence, recursively through keys.
// Keep the original key/payload; normalize only the retained lookup identity.
fn identity(value: &Value) -> Value {
    match value {
        Value::String(s) => Value::String(s.nfc().collect()),
        Value::Array(values) => Value::Array(values.iter().map(identity).collect()),
        Value::Object(values) => Value::Object(
            values
                .iter()
                .map(|(k, v)| (k.nfc().collect(), identity(v)))
                .collect(),
        ),
        value => value.clone(),
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Limits {
    #[serde(default = "item_limit")]
    item_limit: i64,
    #[serde(default = "detail_limit")]
    detail_limit: i64,
    #[serde(default = "episode_limit")]
    episode_list_limit: i64,
    #[serde(default = "page_limit")]
    page_limit: i64,
}
fn item_limit() -> i64 {
    1024
}
fn detail_limit() -> i64 {
    40
}
fn episode_limit() -> i64 {
    80
}
fn page_limit() -> i64 {
    24
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            item_limit: 1024,
            detail_limit: 40,
            episode_list_limit: 80,
            page_limit: 24,
        }
    }
}
#[derive(Clone)]
struct Bucket {
    limit: usize,
    values: HashMap<String, (Value, Value)>,
    recency: Vec<String>,
}
impl Bucket {
    fn new(limit: i64) -> Self {
        Self {
            limit: limit.max(1) as usize,
            values: HashMap::new(),
            recency: vec![],
        }
    }
    fn touch(&mut self, key: &str) {
        self.recency.retain(|k| k != key);
        self.recency.push(key.into());
    }
    fn clear(&mut self) {
        self.values.clear();
        self.recency.clear();
    }
}
#[derive(Default)]
pub struct Repository {
    buckets: HashMap<String, Bucket>,
    flights: HashMap<String, u64>,
    next_ticket: u64,
    progress: progress::Session,
}
impl Repository {
    fn configure(&mut self, limits: Limits) {
        self.buckets = [
            ("items", limits.item_limit),
            ("details", limits.detail_limit),
            ("episodes", limits.episode_list_limit),
            ("pages", limits.page_limit),
            ("home", 1),
        ]
        .into_iter()
        .map(|(key, limit)| (key.into(), Bucket::new(limit)))
        .collect();
    }
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        if let Some(method) = method.strip_prefix("compose.") {
            return composition::call(self, method, args);
        }
        if let Some(method) = method.strip_prefix("progress.") {
            return progress::call(self, method, args);
        }
        if method == "open" {
            let limits: Limits = serde_json::from_value(args.clone()).map_err(|e| e.to_string())?;
            if !self.flights.is_empty() {
                return Err("cannot reopen an active repository".into());
            }
            self.configure(limits);
            return Ok(json!({"opened":true}));
        }
        if method == "freshness" {
            let kind = args["kind"].as_str().ok_or("freshness kind required")?;
            let ttl = args["ttl"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("finite ttl required")?;
            let age = args["age"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("finite age required")?;
            return match kind {
                "snapshot" => {
                    let source = args["source"]
                        .as_str()
                        .filter(|s| ["memory", "disk", "network"].contains(s))
                        .ok_or("invalid source")?;
                    Ok(json!(source != "disk" && age < ttl))
                }
                "progress" => {
                    let present = args["present"].as_bool().ok_or("present must be boolean")?;
                    Ok(json!(!present || age > ttl))
                }
                _ => Err("invalid freshness kind".into()),
            };
        }
        if method == "claim" {
            let kind = args["kind"]
                .as_str()
                .filter(|s| ["home", "item", "detail", "episodes", "page"].contains(s))
                .ok_or("invalid refresh kind")?;
            let key = args
                .get("key")
                .filter(|v| !v.is_null())
                .ok_or("refresh key required")?;
            let key = format!("{kind}|{}", identity(key));
            if let Some(ticket) = self.flights.get(&key) {
                return Ok(json!({"owner":false,"ticket":ticket}));
            }
            let ticket = self
                .next_ticket
                .checked_add(1)
                .ok_or("refresh ticket exhausted")?;
            self.next_ticket = ticket;
            self.flights.insert(key, ticket);
            return Ok(json!({"owner":true,"ticket":ticket}));
        }
        if method == "finish" {
            let ticket = args["ticket"].as_u64().ok_or("ticket must be UInt64")?;
            let key = self
                .flights
                .iter()
                .find(|(_, value)| **value == ticket)
                .map(|(key, _)| key.clone())
                .ok_or("refresh ticket not active")?;
            self.flights.remove(&key);
            return Ok(json!({"finished":true}));
        }
        if method == "stats" {
            return Ok(
                json!({"flights":self.flights.len(),"buckets":self.buckets.iter().map(|(k,b)|(k.clone(),json!({"limit":b.limit,"count":b.values.len(),"recency":b.recency.iter().map(|key|&b.values[key].0).collect::<Vec<_>>()}))).collect::<HashMap<_,_>>()}),
            );
        }
        if method == "clear" {
            for bucket in self.buckets.values_mut() {
                bucket.clear()
            }
            // Native invalidation does not cancel or retire in-flight refreshes.
            return Ok(Value::Null);
        }
        let bucket = args["bucket"].as_str().ok_or("bucket required")?;
        if !["items", "details", "episodes", "pages", "home"].contains(&bucket) {
            return Err("invalid bucket".into());
        }
        if self.buckets.is_empty() {
            self.configure(Limits::default());
        }
        match method {
            "all" => Ok(json!(self.buckets[bucket]
                .values
                .values()
                .map(|(key, entry)| json!({"key":key,"entry":entry}))
                .collect::<Vec<_>>())),
            "clearBucket" => {
                self.buckets.get_mut(bucket).unwrap().clear();
                Ok(Value::Null)
            }
            "get" | "put" => {
                let raw = args["payloadJSON"].as_str().ok_or("payloadJSON required")?;
                let payload: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
                let key = payload
                    .get("key")
                    .filter(|v| !v.is_null())
                    .ok_or("key required")?;
                let encoded = identity(key).to_string();
                let entry = if method == "put" {
                    let entry = payload.get("entry").ok_or("entry required")?;
                    if !entry.is_null()
                        && (!entry.is_object()
                            || entry.get("value").is_none()
                            || !entry["fetchedAt"].as_f64().is_some_and(f64::is_finite))
                    {
                        return Err("invalid memory entry".into());
                    }
                    Some(entry.clone())
                } else {
                    None
                };
                let bucket = self.buckets.get_mut(bucket).unwrap();
                if let Some(entry) = entry {
                    if entry.is_null() {
                        bucket.values.remove(&encoded);
                        bucket.recency.retain(|k| k != &encoded);
                    } else {
                        bucket
                            .values
                            .entry(encoded.clone())
                            .and_modify(|(_, value)| *value = entry.clone())
                            .or_insert_with(|| (key.clone(), entry));
                        bucket.touch(&encoded);
                        while bucket.values.len() > bucket.limit {
                            let old = bucket.recency.remove(0);
                            bucket.values.remove(&old);
                        }
                    }
                    Ok(Value::Null)
                } else {
                    let value = bucket.values.get(&encoded).map(|(_, entry)| entry.clone());
                    if value.is_some() {
                        bucket.touch(&encoded)
                    }
                    Ok(value.unwrap_or(Value::Null))
                }
            }
            _ => Err("unknown repository command".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(repo: &mut Repository, key: Value, value: Value) {
        repo.call("put",&json!({"bucket":"items","payloadJSON":json!({"key":key,"entry":{"value":value,"fetchedAt":123.25}}).to_string()})).unwrap();
    }
    fn get(repo: &mut Repository, key: Value) -> Value {
        repo.call(
            "get",
            &json!({"bucket":"items","payloadJSON":json!({"key":key}).to_string()}),
        )
        .unwrap()
    }
    #[test]
    fn complete_lru_touch_delete_all_and_minimum_limits() {
        let mut r = Repository::default();
        r.call("open", &json!({"itemLimit":2,"detailLimit":0}))
            .unwrap();
        put(&mut r, json!("a"), json!(1));
        put(&mut r, json!("b"), json!(2));
        assert_eq!(get(&mut r, json!("a"))["value"], 1);
        put(&mut r, json!("c"), json!(3));
        assert!(get(&mut r, json!("b")).is_null());
        let before = r.call("stats", &json!({})).unwrap();
        r.call("all", &json!({"bucket":"items"})).unwrap();
        assert_eq!(before, r.call("stats", &json!({})).unwrap());
        r.call(
            "put",
            &json!({"bucket":"items","payloadJSON":"{\"key\":\"a\",\"entry\":null}"}),
        )
        .unwrap();
        assert!(get(&mut r, json!("a")).is_null());
        assert_eq!(before["buckets"]["details"]["limit"], 1);
        r.call("clear", &json!({})).unwrap();
        assert!(get(&mut r, json!("c")).is_null());
    }
    #[test]
    fn structured_keys_and_wide_nested_payloads_are_retained() {
        let mut r = Repository::default();
        let key = json!({"seriesID":"series/quoted\"","seasonID":"\n"});
        let value =
            json!({"id":i64::MAX,"episodes":[{"episodeNumber":i64::MIN}],"extra":{"unknown":true}});
        put(&mut r, key.clone(), value.clone());
        assert_eq!(get(&mut r, key)["value"], value);
    }
    #[test]
    fn refresh_ownership_retirement_and_invalidation_match_native() {
        let mut r = Repository::default();
        let key = json!({"kind":"page","key":{"startIndex":0,"limit":2,"searchTerm":"猫"}});
        let owner = r.call("claim", &key).unwrap();
        let joined = r.call("claim", &key).unwrap();
        assert_eq!(owner["ticket"], joined["ticket"]);
        assert_eq!(joined["owner"], false);
        r.call("clear", &json!({})).unwrap();
        assert_eq!(r.call("claim", &key).unwrap(), joined);
        assert!(r.call("open", &json!({})).is_err());
        r.call("finish", &json!({"ticket":owner["ticket"]}))
            .unwrap();
        assert!(r
            .call("finish", &json!({"ticket":owner["ticket"]}))
            .is_err());
        let next = r.call("claim", &key).unwrap();
        assert_eq!(next["owner"], true);
        assert_ne!(next["ticket"], owner["ticket"]);
    }
    #[test]
    fn complete_freshness_boundaries_and_invalid_receipts_leave_entries_intact() {
        let mut r = Repository::default();
        put(&mut r, json!("a"), json!(1));
        assert!(r
            .call(
                "put",
                &json!({"bucket":"items","payloadJSON":"{\"key\":\"a\",\"entry\":{}}"})
            )
            .is_err());
        assert_eq!(get(&mut r, json!("a"))["value"], 1);
        for source in ["memory", "disk", "network"] {
            for age in [-1.0, 899.0, 900.0, 901.0] {
                assert_eq!(
                    r.call(
                        "freshness",
                        &json!({"kind":"snapshot","source":source,"age":age,"ttl":900.0})
                    )
                    .unwrap(),
                    json!(source != "disk" && age < 900.0)
                );
                assert_eq!(
                    r.call(
                        "freshness",
                        &json!({"kind":"progress","present":true,"age":age,"ttl":900.0})
                    )
                    .unwrap(),
                    json!(age > 900.0)
                );
            }
        }
        assert_eq!(
            r.call(
                "freshness",
                &json!({"kind":"progress","present":false,"age":0.0,"ttl":900.0})
            )
            .unwrap(),
            true
        );
    }
    #[test]
    fn canonical_string_identity_matches_native_without_normalizing_payloads() {
        let mut r = Repository::default();
        put(&mut r, json!("é"), json!({"name":"e\u{301}"}));
        assert_eq!(get(&mut r, json!("e\u{301}"))["value"]["name"], "e\u{301}");
        put(&mut r, json!("e\u{301}"), json!({"name":"updated"}));
        let all = r.call("all", &json!({"bucket":"items"})).unwrap();
        assert_eq!(all.as_array().unwrap().len(), 1);
        assert_eq!(all[0]["key"], "é");
        let a = r
            .call(
                "claim",
                &json!({"kind":"page","key":{"parentID":"é","searchTerm":"Å"}}),
            )
            .unwrap();
        let b = r
            .call(
                "claim",
                &json!({"kind":"page","key":{"parentID":"e\u{301}","searchTerm":"A\u{30a}"}}),
            )
            .unwrap();
        assert_eq!(a["ticket"], b["ticket"]);
        assert_eq!(b["owner"], false);
    }
}
