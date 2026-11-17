//! Session-local progress, confirmation/revision barriers and projection updates.
//! Native hosts execute disk effects between beginFinal and finishFinal.
use super::*;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    item: Value,
    recorded_at: f64,
    confirmed_at: Option<f64>,
    #[serde(default)]
    completed: bool,
    #[serde(default)]
    revision: u64,
}
impl Record {
    fn protects(&self, started: f64) -> bool {
        self.confirmed_at.is_none_or(|t| started <= t)
    }
    fn completion(&self) -> bool {
        self.completed
            && self.confirmed_at.is_some()
            && self.item["playState"]["played"] == true
            && self.item["playState"]["positionSeconds"].as_f64() == Some(0.0)
    }
}
#[derive(Default)]
pub(super) struct Session {
    records: HashMap<String, Record>,
    shutdown: bool,
    revision: u64,
}
fn id(item: &Value) -> Result<String, String> {
    item["id"]
        .as_str()
        .map(|s| s.nfc().collect())
        .ok_or("item id required".into())
}
fn clock(v: &Value, field: &str) -> Result<f64, String> {
    v[field]
        .as_f64()
        .filter(|x| x.is_finite())
        .ok_or_else(|| format!("finite {field} required"))
}
fn array(v: &Value, field: &str) -> Result<Vec<Value>, String> {
    let values = v[field]
        .as_array()
        .ok_or_else(|| format!("{field} array required"))?;
    for item in values {
        id(item)?;
    }
    Ok(values.clone())
}
fn boolean(v: &Value, field: &str) -> Result<bool, String> {
    v[field]
        .as_bool()
        .ok_or_else(|| format!("boolean {field} required"))
}
fn validate_state(v: &Value) -> Result<(), String> {
    boolean(v, "played")?;
    clock(v, "percentage")?;
    clock(v, "positionSeconds")?;
    if !v["unplayedCount"].is_null() && v["unplayedCount"].as_i64().is_none() {
        return Err("unplayedCount must be Int64".into());
    }
    Ok(())
}
fn get(repo: &mut Repository, bucket: &str, key: &Value) -> Value {
    repo.call(
        "get",
        &json!({"bucket":bucket,"payloadJSON":json!({"key":key}).to_string()}),
    )
    .unwrap()
}
fn put(repo: &mut Repository, bucket: &str, key: &Value, entry: Value) {
    repo.call(
        "put",
        &json!({"bucket":bucket,"payloadJSON":json!({"key":key,"entry":entry}).to_string()}),
    )
    .unwrap();
}
fn next_revision(repo: &mut Repository) -> Result<u64, String> {
    let next = repo
        .progress
        .revision
        .checked_add(1)
        .ok_or("progress revision exhausted")?;
    repo.progress.revision = next;
    Ok(next)
}
pub(super) fn merged(repo: &Repository, values: Vec<Value>, started: f64) -> Vec<Value> {
    values
        .into_iter()
        .map(|mut item| {
            if let Some(p) = repo
                .progress
                .records
                .get(&id(&item).unwrap())
                .filter(|p| p.protects(started))
            {
                item["playState"] = p.item["playState"].clone();
            }
            item
        })
        .collect()
}
pub(super) fn filter_resume(repo: &Repository, values: &mut Vec<Value>) {
    values.retain(|i| {
        !repo
            .progress
            .records
            .get(&id(i).unwrap())
            .is_some_and(Record::completion)
    });
}
fn playback_state(position: f64, duration: Option<f64>, played: bool, previous: &Value) -> Value {
    let percentage = if played {
        1.0
    } else if let Some(d) = duration.filter(|d| *d > 0.0) {
        (position / d).clamp(0.0, 1.0)
    } else {
        previous["percentage"].as_f64().unwrap_or(0.0)
    };
    let mut result = json!({"played":played,"percentage":percentage,"positionSeconds":position});
    if !previous["unplayedCount"].is_null() {
        result["unplayedCount"] = previous["unplayedCount"].clone();
    }
    result
}
fn update_first(items: &mut Value, item_id: &str, state: &Value) -> bool {
    if let Some(items) = items.as_array_mut() {
        if let Some(item) = items
            .iter_mut()
            .find(|i| id(i).is_ok_and(|id| id == item_id))
        {
            item["playState"] = state.clone();
            return true;
        }
    }
    false
}
// Projection storage is deliberately generic. A progress operation requires
// complete media projections, so validate them before touching recency or state.
fn validate_items(items: &Value) -> Result<(), String> {
    for item in items
        .as_array()
        .ok_or("projection items must be an array")?
    {
        id(item)?;
    }
    Ok(())
}
fn validate_projections(repo: &Repository) -> Result<(), String> {
    for (bucket, entries) in &repo.buckets {
        for (_, entry) in entries.values.values() {
            let value = &entry["value"];
            match bucket.as_str() {
                "items" => {
                    id(value)?;
                }
                "details" => {
                    id(&value["item"])?;
                    validate_items(&value["episodes"])?;
                }
                "episodes" => {
                    validate_items(value)?;
                }
                "pages" => {
                    validate_items(&value["items"])?;
                }
                "home" => {
                    for rail in ["resume", "nextUp", "latest"] {
                        validate_items(&value[rail])?;
                    }
                }
                _ => return Err("invalid projection bucket".into()),
            }
        }
    }
    Ok(())
}
fn apply(
    repo: &mut Repository,
    item_id: &str,
    state: &Value,
    persist: bool,
    now: f64,
) -> Result<Value, String> {
    if repo.progress.shutdown {
        return Ok(json!({"applied":false}));
    }
    validate_projections(repo)?;
    let lookup: String = item_id.nfc().collect();
    let key = json!(item_id);
    let entry = get(repo, "items", &key);
    let mut fallback = if entry.is_object() {
        entry["value"].clone()
    } else {
        repo.progress
            .records
            .get(&lookup)
            .map(|p| p.item.clone())
            .unwrap_or_else(
                || json!({"id":item_id,"name":item_id,"kind":"other","genres":[],"cast":[]}),
            )
    };
    fallback["playState"] = state.clone();
    if persist {
        let revision = next_revision(repo)?;
        repo.progress.records.insert(
            lookup.clone(),
            Record {
                item: fallback.clone(),
                recorded_at: now,
                confirmed_at: Some(now),
                completed: false,
                revision,
            },
        );
    }
    if entry.is_object() {
        put(
            repo,
            "items",
            &key,
            json!({"value":fallback,"fetchedAt":now}),
        );
    }
    let mut entry = get(repo, "details", &key);
    if entry.is_object() {
        entry["value"]["item"]["playState"] = state.clone();
        entry["fetchedAt"] = json!(now);
        put(repo, "details", &key, entry);
    }
    for bucket in ["details", "episodes", "pages"] {
        let rows = repo.call("all", &json!({"bucket":bucket})).unwrap();
        for row in rows.as_array().unwrap() {
            let mut entry = row["entry"].clone();
            let items = match bucket {
                "details" => &mut entry["value"]["episodes"],
                "pages" => &mut entry["value"]["items"],
                _ => &mut entry["value"],
            };
            if update_first(items, &lookup, state) {
                entry["fetchedAt"] = json!(now);
                put(repo, bucket, &row["key"], entry);
            }
        }
    }
    let mut entry = get(repo, "home", &json!("home"));
    if entry.is_object() {
        for rail in ["resume", "nextUp", "latest"] {
            update_first(&mut entry["value"][rail], &lookup, state);
        }
        entry["fetchedAt"] = json!(now);
        put(repo, "home", &json!("home"), entry);
    }
    Ok(json!({"applied":true,"fallbackItem":fallback}))
}

pub(super) fn call(repo: &mut Repository, method: &str, args: &Value) -> Result<Value, String> {
    let v: Value = if let Some(raw) = args["payloadJSON"].as_str() {
        serde_json::from_str(raw).map_err(|e| e.to_string())?
    } else {
        args.clone()
    };
    if !v.is_object() {
        return Err("progress arguments must be an object".into());
    }
    match method {
        "lifecycle" => Ok(json!(repo.progress.shutdown)),
        "stats" => Ok(
            json!({"shutdown":repo.progress.shutdown,"records":repo.progress.records.values().collect::<Vec<_>>()}),
        ),
        "shutdown" | "invalidate" => {
            let discard = if method == "invalidate" {
                boolean(&v, "discardLocalProgress")?
            } else {
                false
            };
            if method == "shutdown" {
                repo.progress.shutdown = true;
            }
            if discard {
                repo.progress.records.clear();
            }
            repo.call("clear", &json!({}))
        }
        "merge" | "filterResume" => {
            let items = array(&v, "items")?;
            if method == "merge" {
                Ok(json!(merged(repo, items, clock(&v, "requestStartedAt")?)))
            } else {
                let mut items = items;
                filter_resume(repo, &mut items);
                Ok(json!(items))
            }
        }
        "incoming" => {
            let incoming = array(&v, "incoming")?;
            let values = array(&v, "merged")?;
            let started = clock(&v, "requestStartedAt")?;
            let now = clock(&v, "now")?;
            for remote in incoming {
                if let Some(p) = repo.progress.records.get_mut(&id(&remote)?) {
                    if !p.protects(started) {
                        p.item["playState"] = remote["playState"].clone();
                    }
                    let local = &p.item["playState"];
                    let state = &remote["playState"];
                    if p.confirmed_at.is_none()
                        && started >= p.recorded_at
                        && local.is_object()
                        && state.is_object()
                    {
                        let same = local["played"] == state["played"]
                            && local["positionSeconds"]
                                .as_f64()
                                .zip(state["positionSeconds"].as_f64())
                                .is_some_and(|(a, b)| (a - b).abs() < 1.0);
                        let finished = p.completed && state["played"] == true;
                        if same || finished {
                            if finished {
                                p.item["playState"] = state.clone();
                            }
                            p.confirmed_at = Some(now);
                        }
                    }
                }
            }
            let mut values = merged(repo, values, started);
            if v["rail"] == "resume" {
                filter_resume(repo, &mut values);
                let ids: std::collections::HashSet<_> =
                    values.iter().map(|i| id(i).unwrap()).collect();
                let mut missing: Vec<_> = repo
                    .progress
                    .records
                    .values()
                    .filter(|p| {
                        p.protects(started)
                            && !ids.contains(&id(&p.item).unwrap())
                            && p.item["playState"]["played"] == false
                            && p.item["playState"]["positionSeconds"]
                                .as_f64()
                                .unwrap_or(0.0)
                                > 0.0
                    })
                    .cloned()
                    .collect();
                missing.sort_by(|a, b| {
                    b.recorded_at
                        .total_cmp(&a.recorded_at)
                        .then_with(|| id(&a.item).unwrap().cmp(&id(&b.item).unwrap()))
                });
                for p in missing {
                    let entry = get(repo, "items", &p.item["id"]);
                    let mut item = if entry.is_object() {
                        entry["value"].clone()
                    } else {
                        p.item.clone()
                    };
                    item["playState"] = p.item["playState"].clone();
                    values.push(item);
                }
            }
            Ok(json!(values))
        }
        "apply" => {
            id(&json!({"id":v["itemID"]}))?;
            validate_state(&v["state"])?;
            let now = clock(&v, "now")?;
            let persist = boolean(&v, "persistToStore")?;
            apply(
                repo,
                v["itemID"].as_str().unwrap(),
                &v["state"],
                persist,
                now,
            )
        }
        "playbackState" | "beginFinal" => {
            let item_id = if method == "beginFinal" {
                id(&v["item"])?
            } else {
                id(&json!({"id":v["itemID"]}))?
            };
            let position = clock(&v, "positionSeconds")?;
            let duration = if v["durationSeconds"].is_null() {
                None
            } else {
                Some(clock(&v, "durationSeconds")?)
            };
            let timestamp = if method == "beginFinal" {
                Some(clock(&v, "recordedAt")?)
            } else {
                None
            };
            let played = if method == "playbackState" {
                Some(boolean(&v, "played")?)
            } else {
                None
            };
            if timestamp.is_some_and(|t| {
                repo.progress
                    .records
                    .get(&item_id)
                    .is_some_and(|p| p.recorded_at > t)
            }) {
                return Ok(json!({"accepted":false}));
            }
            let key = if method == "beginFinal" {
                &v["item"]["id"]
            } else {
                &v["itemID"]
            };
            let cached = get(repo, "items", key);
            let mut previous = cached["value"]["playState"].clone();
            if method == "beginFinal" && previous.is_null() {
                previous = repo
                    .progress
                    .records
                    .get(&item_id)
                    .map(|p| p.item["playState"].clone())
                    .filter(|p| !p.is_null())
                    .unwrap_or_else(|| v["item"]["playState"].clone());
            }
            let state = playback_state(
                position,
                duration,
                played.unwrap_or_else(|| previous["played"].as_bool().unwrap_or(false)),
                &previous,
            );
            if let Some(recorded_at) = timestamp {
                let revision = next_revision(repo)?;
                let mut item = v["item"].clone();
                item["playState"] = state.clone();
                repo.progress.records.insert(
                    item_id,
                    Record {
                        item,
                        recorded_at,
                        confirmed_at: None,
                        completed: duration
                            .is_some_and(|d| d > 0.0 && position >= (d - 2.0).max(0.0)),
                        revision,
                    },
                );
                Ok(json!({"accepted":true,"revision":revision,"state":state}))
            } else {
                Ok(state)
            }
        }
        "finishFinal" => {
            let item_id = id(&json!({"id":v["itemID"]}))?;
            let revision = v["revision"].as_u64().ok_or("UInt64 revision required")?;
            validate_state(&v["state"])?;
            let now = clock(&v, "now")?;
            let newer: Option<Record> = if v["newerRecord"].is_null() {
                None
            } else {
                let p: Record =
                    serde_json::from_value(v["newerRecord"].clone()).map_err(|e| e.to_string())?;
                if id(&p.item)? != item_id
                    || !p.recorded_at.is_finite()
                    || p.confirmed_at.is_some_and(|t| !t.is_finite())
                {
                    return Err("invalid newer progress record".into());
                }
                Some(p)
            };
            let Some(current) = repo
                .progress
                .records
                .get(&item_id)
                .filter(|p| p.revision == revision && p.confirmed_at.is_none())
                .cloned()
            else {
                return Ok(json!({"applied":false}));
            };
            if !repo.progress.shutdown {
                validate_projections(repo)?;
            }
            let mut item = current.item;
            item["playState"] = v["state"].clone();
            let mut accepted = newer.unwrap_or(Record {
                item: item.clone(),
                ..current
            });
            accepted.item = item.clone();
            accepted.revision = next_revision(repo)?;
            repo.progress.records.insert(item_id.clone(), accepted);
            if repo.progress.shutdown {
                return Ok(json!({"applied":false}));
            }
            if get(repo, "items", &item["id"]).is_null() {
                put(
                    repo,
                    "items",
                    &item["id"],
                    json!({"value":item,"fetchedAt":now}),
                );
            }
            apply(repo, v["itemID"].as_str().unwrap(), &v["state"], false, now)
        }
        _ => Err("unknown repository progress command".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn item(id: &str, position: f64) -> Value {
        json!({"id":id,"name":"作品","kind":"movie","year":i64::MAX,"playState":{"played":false,"percentage":0.4,"positionSeconds":position,"unplayedCount":i64::MAX},"extra":{"retained":true}})
    }
    fn invoke(r: &mut Repository, method: &str, v: Value) -> Value {
        call(r, method, &v).unwrap()
    }
    fn begin(r: &mut Repository, i: Value, position: f64, at: f64) -> Value {
        invoke(
            r,
            "beginFinal",
            json!({"item":i,"positionSeconds":position,"durationSeconds":100,"recordedAt":at}),
        )
    }
    fn finish(r: &mut Repository, receipt: &Value, state: Value, newer: Value) -> Value {
        invoke(
            r,
            "finishFinal",
            json!({"itemID":"movie","revision":receipt["revision"],"state":state,"newerRecord":newer,"now":30}),
        )
    }
    #[test]
    fn apply_updates_every_projection_first_duplicate_and_preserves_original_unicode_payload() {
        let mut r = Repository::default();
        let i = item("e\u{301}", 2.0);
        let key = &i["id"];
        put(&mut r, "items", key, json!({"value":i,"fetchedAt":1}));
        put(
            &mut r,
            "details",
            key,
            json!({"value":{"item":i,"episodes":[i,i]},"fetchedAt":1}),
        );
        put(
            &mut r,
            "episodes",
            &json!({"season":"s"}),
            json!({"value":[i,i],"fetchedAt":1}),
        );
        put(
            &mut r,
            "pages",
            &json!({"query":"q"}),
            json!({"value":{"items":[i,i],"totalCount":i64::MAX},"fetchedAt":1}),
        );
        put(
            &mut r,
            "home",
            &json!("home"),
            json!({"value":{"resume":[i,i],"nextUp":[i],"latest":[i],"libraries":[]},"fetchedAt":1}),
        );
        let state =
            json!({"played":true,"percentage":1,"positionSeconds":0,"unplayedCount":i64::MAX});
        let result = invoke(
            &mut r,
            "apply",
            json!({"itemID":"é","state":state,"persistToStore":true,"now":20}),
        );
        assert_eq!(result["fallbackItem"]["id"], "e\u{301}");
        for bucket in ["items", "details", "episodes", "pages", "home"] {
            let rows = r.call("all", &json!({"bucket":bucket})).unwrap();
            assert_eq!(rows[0]["entry"]["fetchedAt"], 20.0);
            assert!(rows.to_string().contains(&i64::MAX.to_string()));
        }
        let detail = get(&mut r, "details", key);
        assert_eq!(detail["value"]["episodes"][0]["playState"], state);
        assert_eq!(detail["value"]["episodes"][1]["playState"], i["playState"]);
        let r2 = invoke(
            &mut r,
            "apply",
            json!({"itemID":"a\u{301}","state":state,"persistToStore":true,"now":21}),
        );
        assert_eq!(r2["fallbackItem"]["id"], "a\u{301}");
    }
    #[test]
    fn revisions_survive_invalidation_reject_older_final_and_accept_owned_final_after_shutdown() {
        let mut r = Repository::default();
        let i = item("movie", 0.0);
        let receipt = begin(&mut r, i.clone(), 42.0, 10.0);
        assert_eq!(begin(&mut r, i.clone(), 12.0, 9.0)["accepted"], false);
        invoke(&mut r, "invalidate", json!({"discardLocalProgress":false}));
        assert_eq!(
            finish(&mut r, &receipt, receipt["state"].clone(), Value::Null)["applied"],
            true
        );
        let stale = begin(&mut r, i.clone(), 60.0, 20.0);
        let newer = begin(&mut r, i, 70.0, 21.0);
        assert_eq!(
            finish(&mut r, &stale, stale["state"].clone(), Value::Null)["applied"],
            false
        );
        invoke(&mut r, "shutdown", json!({}));
        assert_eq!(
            finish(&mut r, &newer, newer["state"].clone(), Value::Null)["applied"],
            false
        );
        let stats = invoke(&mut r, "stats", json!({}));
        assert_eq!(
            stats["records"][0]["item"]["playState"]["positionSeconds"],
            70.0
        );
        assert_eq!(get(&mut r, "items", &json!("movie")), Value::Null);
        assert_eq!(invoke(&mut r, "lifecycle", json!({})), true);
        invoke(&mut r, "invalidate", json!({"discardLocalProgress":true}));
        assert_eq!(invoke(&mut r, "stats", json!({}))["records"], json!([]));
    }
    #[test]
    fn confirmation_and_finished_resume_boundaries_match_native_observation() {
        let mut r = Repository::default();
        let i = item("movie", 0.0);
        begin(&mut r, i.clone(), 99.0, 10.0);
        let mut completed = i.clone();
        completed["playState"] = json!({"played":true,"positionSeconds":0,"percentage":1});
        let older = invoke(
            &mut r,
            "incoming",
            json!({"incoming":[completed],"merged":[completed],"rail":"resume","requestStartedAt":9,"now":12}),
        );
        assert_eq!(older[0]["playState"]["positionSeconds"], 99.0);
        let confirmed = invoke(
            &mut r,
            "incoming",
            json!({"incoming":[completed],"merged":[completed],"rail":"resume","requestStartedAt":10,"now":12}),
        );
        assert_eq!(confirmed, json!([]));
        let changed = item("movie", 4.0);
        let protected = invoke(
            &mut r,
            "merge",
            json!({"items":[changed],"requestStartedAt":12}),
        );
        assert_eq!(protected[0]["playState"]["played"], true);
        let fresh = invoke(
            &mut r,
            "incoming",
            json!({"incoming":[changed],"merged":[changed],"requestStartedAt":13,"now":14}),
        );
        assert_eq!(fresh[0]["playState"]["positionSeconds"], 4.0);
    }
    #[test]
    fn resume_reinserts_missing_pending_items_using_current_metadata_and_record_order() {
        let mut r = Repository::default();
        begin(&mut r, item("movie", 0.0), 42.0, 10.0);
        begin(&mut r, item("newer", 0.0), 60.0, 11.0);
        let mut metadata = item("movie", 1.0);
        metadata["name"] = json!("Updated title");
        put(
            &mut r,
            "items",
            &json!("movie"),
            json!({"value":metadata,"fetchedAt":12}),
        );
        let rows = invoke(
            &mut r,
            "incoming",
            json!({"incoming":[],"merged":[],"rail":"resume","requestStartedAt":0,"now":13}),
        );
        assert_eq!(rows[0]["id"], "newer");
        assert_eq!(rows[1]["name"], "Updated title");
        assert_eq!(rows[1]["playState"]["positionSeconds"], 42.0);
    }
    #[test]
    fn newer_disk_confirmation_is_adopted_without_reopening_protection_and_preflight_is_atomic() {
        let mut r = Repository::default();
        let receipt = begin(&mut r, item("movie", 0.0), 42.0, 10.0);
        let state = json!({"played":true,"percentage":1,"positionSeconds":0});
        let newer =
            json!({"item":item("movie",0.0),"recordedAt":20,"confirmedAt":20,"completed":false});
        assert_eq!(
            finish(&mut r, &receipt, state.clone(), newer)["applied"],
            true
        );
        let merged = invoke(
            &mut r,
            "merge",
            json!({"items":[item("movie",1.0)],"requestStartedAt":21}),
        );
        assert_eq!(merged[0]["playState"]["positionSeconds"], 1.0);
        let before = invoke(&mut r, "stats", json!({}));
        assert!(call(
            &mut r,
            "apply",
            &json!({"itemID":"movie","state":{},"now":22,"persistToStore":true})
        )
        .is_err());
        assert_eq!(invoke(&mut r, "stats", json!({})), before);
        for position in [-10.0_f64, 0.0, 50.0, 200.0] {
            for duration in [None, Some(-1.0), Some(0.0), Some(100.0)] {
                let state = invoke(
                    &mut r,
                    "playbackState",
                    json!({"itemID":"movie","positionSeconds":position,"durationSeconds":duration,"played":false}),
                );
                let expected = if duration.is_some_and(|d| d > 0.0) {
                    (position / duration.unwrap()).clamp(0.0, 1.0)
                } else {
                    1.0
                };
                assert_eq!(state["percentage"], json!(expected));
            }
        }
    }
}
