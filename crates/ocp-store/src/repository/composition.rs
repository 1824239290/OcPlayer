//! Native repository composition policy. Hosts execute asynchronous effects;
//! each reduction observes the same retained session progress as mutations.
use super::*;
use std::collections::HashSet;

fn items(v: &Value, field: &str) -> Result<Vec<Value>, String> {
    let items = v[field]
        .as_array()
        .ok_or_else(|| format!("{field} array required"))?;
    for item in items {
        item["id"].as_str().ok_or("item id required")?;
    }
    Ok(items.clone())
}
fn integer(v: &Value, field: &str) -> Result<i64, String> {
    v[field]
        .as_i64()
        .ok_or_else(|| format!("{field} must be Int64"))
}
fn optional_integer(v: &Value, field: &str) -> Result<Option<i64>, String> {
    if v[field].is_null() {
        Ok(None)
    } else {
        integer(v, field).map(Some)
    }
}
fn clock(v: &Value, field: &str) -> Result<f64, String> {
    v[field]
        .as_f64()
        .filter(|v| v.is_finite())
        .ok_or_else(|| format!("finite {field} required"))
}
fn item_id(item: &Value) -> String {
    item["id"].as_str().unwrap().nfc().collect()
}
fn next_up(next: Vec<Value>, resume: &[Value]) -> Vec<Value> {
    let ids: HashSet<_> = resume.iter().map(item_id).collect();
    next.into_iter()
        .filter(|i| !ids.contains(&item_id(i)))
        .collect()
}
fn page(items: Vec<Value>, total: Option<i64>, next: i64, full: bool) -> Value {
    let mut page = json!({"items":items,"nextStartIndex":next,"lastPageWasFull":full});
    if let Some(total) = total {
        page["totalCount"] = json!(total);
    }
    page
}
fn validate_page(v: &Value) -> Result<(), String> {
    items(v, "items")?;
    integer(v, "nextStartIndex")?;
    optional_integer(v, "totalCount")?;
    v["lastPageWasFull"]
        .as_bool()
        .ok_or("lastPageWasFull must be boolean")?;
    Ok(())
}
pub(super) fn call(repo: &Repository, method: &str, args: &Value) -> Result<Value, String> {
    let raw = args["payloadJSON"].as_str().ok_or("payloadJSON required")?;
    let v: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
    match method {
        "nextUp" => Ok(json!(next_up(items(&v, "nextUp")?, &items(&v, "resume")?))),
        "defaultSeason" => {
            let seasons = items(&v, "seasons")?;
            for item in &seasons {
                optional_integer(item, "seasonNumber")?;
            }
            // A missing season number compares unequal to zero in Swift.
            Ok(seasons
                .iter()
                .find(|i| i["seasonNumber"].as_i64() != Some(0))
                .or_else(|| seasons.first())
                .map(|i| i["id"].clone())
                .unwrap_or(Value::Null))
        }
        "detailPlan" => {
            let hint = v["kindHint"].as_str();
            let previous = v["previous"]["item"]["kind"].as_str();
            let kind = hint.or(previous);
            let phase = if kind == Some("series") {
                "series"
            } else if v["item"]["kind"] == "boxSet" || kind == Some("boxSet") {
                "members"
            } else if v["item"]["kind"] == "series" {
                "retrySeries"
            } else {
                "item"
            };
            Ok(json!(phase))
        }
        "detail" => {
            let mut content = v["content"].clone();
            content["item"]["id"].as_str().ok_or("item id required")?;
            let started = clock(&v, "requestStartedAt")?;
            let merge = v["mergeProgress"]
                .as_bool()
                .ok_or("mergeProgress must be boolean")?;
            for field in ["seasons", "episodes", "collectionMembers"] {
                let values = items(&content, field)?;
                if merge {
                    content[field] = json!(progress::merged(repo, values, started));
                }
            }
            optional_integer(&content, "collectionMembersTotalCount")?;
            if merge {
                content["item"] =
                    progress::merged(repo, vec![content["item"].clone()], started).remove(0);
            }
            Ok(content)
        }
        "home" => {
            let mut content = v["content"].clone();
            content["libraries"]
                .as_array()
                .ok_or("libraries array required")?;
            let started = clock(&v, "requestStartedAt")?;
            for field in ["resume", "nextUp", "latest"] {
                let mut values = progress::merged(repo, items(&content, field)?, started);
                if field == "resume" {
                    progress::filter_resume(repo, &mut values);
                }
                content[field] = json!(values);
            }
            Ok(content)
        }
        "diskHome" => {
            let mut content = v["content"].clone();
            let libraries = content["libraries"]
                .as_array()
                .ok_or("libraries array required")?;
            let resume = items(&content, "resume")?;
            let next = items(&content, "nextUp")?;
            let latest = items(&content, "latest")?;
            let dates = |field: &str| -> Result<Vec<f64>, String> {
                v[field]
                    .as_array()
                    .ok_or_else(|| format!("{field} array required"))?
                    .iter()
                    .map(|d| {
                        d.as_f64()
                            .filter(|d| d.is_finite())
                            .ok_or("finite date required".into())
                    })
                    .collect()
            };
            let rail_dates = dates("railDates")?;
            let library_dates = dates("libraryDates")?;
            let now = clock(&v, "now")?;
            let next = next_up(next, &resume);
            if libraries.is_empty() && resume.is_empty() && next.is_empty() && latest.is_empty() {
                return Ok(Value::Null);
            }
            content["nextUp"] = json!(next);
            let fetched = rail_dates
                .into_iter()
                .reduce(f64::min)
                .or_else(|| library_dates.into_iter().reduce(f64::min))
                .unwrap_or(now);
            Ok(json!({"value":content,"fetchedAt":fetched}))
        }
        "diskPage" => {
            let mut rows = v["rows"].as_array().ok_or("rows array required")?.clone();
            for row in &rows {
                items(row, "items")?;
                integer(row, "startIndex")?;
                integer(row, "limit")?;
                optional_integer(row, "totalRecordCount")?;
            }
            rows.sort_by_key(|row| row["startIndex"].as_i64().unwrap());
            let mut ids = HashSet::new();
            let mut values = vec![];
            let (mut next, mut total, mut full) = (0, None, false);
            for row in rows {
                let start = integer(&row, "startIndex")?;
                if start != next {
                    break;
                }
                let incoming = items(&row, "items")?;
                next = start
                    .checked_add(incoming.len() as i64)
                    .ok_or("page offset overflow")?;
                total = optional_integer(&row, "totalRecordCount")?;
                full =
                    integer(&row, "limit")? > 0 && incoming.len() as i64 >= integer(&row, "limit")?;
                values.extend(incoming.into_iter().filter(|i| ids.insert(item_id(i))));
            }
            Ok(page(values, total, next, full))
        }
        "page" => {
            let incoming = items(&v, "items")?;
            let start = integer(&v, "startIndex")?;
            let limit = integer(&v, "limit")?;
            let total = optional_integer(&v, "totalRecordCount")?;
            let started = clock(&v, "requestStartedAt")?;
            let count = incoming.len() as i64;
            let (values, total, next) = if start == 0 {
                (incoming, total, count)
            } else {
                let previous = if v["previous"].is_null() {
                    page(vec![], None, 0, false)
                } else {
                    v["previous"].clone()
                };
                validate_page(&previous)?;
                let mut values = items(&previous, "items")?;
                let mut ids: HashSet<_> = values.iter().map(item_id).collect();
                values.extend(incoming.into_iter().filter(|i| ids.insert(item_id(i))));
                (
                    values,
                    total.or(optional_integer(&previous, "totalCount")?),
                    integer(&previous, "nextStartIndex")?
                        .max(start.checked_add(count).ok_or("page offset overflow")?),
                )
            };
            Ok(page(
                progress::merged(repo, values, started),
                total,
                next,
                count >= limit,
            ))
        }
        _ => Err(format!("unknown composition operation {method}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn item(id: &str) -> Value {
        json!({"id":id,"year":i64::MAX})
    }
    fn invoke(r: &Repository, method: &str, v: Value) -> Value {
        call(r, method, &json!({"payloadJSON":v.to_string()})).unwrap()
    }
    #[test]
    fn page_recovery_keeps_contiguity_duplicate_rules_and_signed_counts() {
        let r = Repository::default();
        let rows = json!({"rows":[
            {"items":[item("e\u{301}"),item("last")],"startIndex":2,"limit":2,"totalRecordCount":null},
            {"items":[item("é"),item("é")],"startIndex":0,"limit":2,"totalRecordCount":i64::MAX},
            {"items":[item("gap")],"startIndex":5,"limit":1}]});
        let recovered = invoke(&r, "diskPage", rows);
        assert_eq!(
            recovered,
            page(vec![item("é"), item("last")], None, 4, true)
        );
        let result = invoke(
            &r,
            "page",
            json!({"items":[item("é"),item("new")],"previous":recovered,"startIndex":7,"limit":2,"requestStartedAt":1,"totalRecordCount":i64::MAX}),
        );
        assert_eq!(result["nextStartIndex"], 9);
        assert_eq!(result["totalCount"], i64::MAX);
        assert_eq!(result["items"].as_array().unwrap().len(), 3);
        let first = invoke(
            &r,
            "page",
            json!({"items":[item("é"),item("é")],"startIndex":0,"limit":0,"requestStartedAt":1}),
        );
        assert_eq!(first["items"].as_array().unwrap().len(), 2);
        assert_eq!(first["lastPageWasFull"], true);
    }
    #[test]
    fn home_restore_and_detail_decisions_keep_native_boundaries() {
        let r = Repository::default();
        let home = json!({"libraries":[],"resume":[item("é")],"nextUp":[item("e\u{301}"),item("other"),item("other")],"latest":[]});
        let disk = invoke(
            &r,
            "diskHome",
            json!({"content":home,"railDates":[3,5],"libraryDates":[1],"now":9}),
        );
        assert_eq!(disk["fetchedAt"].as_f64(), Some(3.0));
        assert_eq!(disk["value"]["nextUp"].as_array().unwrap().len(), 2);
        assert_eq!(
            invoke(
                &r,
                "defaultSeason",
                json!({"seasons":[{"id":"special","seasonNumber":0},{"id":"nil"}]})
            ),
            "nil"
        );
        assert_eq!(
            invoke(
                &r,
                "detailPlan",
                json!({"kindHint":"series","item":{"kind":"boxSet"}})
            ),
            "series"
        );
        assert_eq!(
            invoke(&r, "detailPlan", json!({"item":{"kind":"series"}})),
            "retrySeries"
        );
        assert_eq!(
            invoke(
                &r,
                "detailPlan",
                json!({"previous":{"item":{"kind":"boxSet"}},"item":{"kind":"movie"}})
            ),
            "members"
        );
    }
    #[test]
    fn composition_observes_progress_and_rejects_overflow_without_mutation() {
        let mut r = Repository::default();
        r.call("progress.beginFinal", &json!({"payloadJSON":json!({"item":item("é"),"positionSeconds":42,"recordedAt":5}).to_string()})).unwrap();
        let result = invoke(
            &r,
            "page",
            json!({"items":[item("e\u{301}")],"startIndex":0,"limit":1,"requestStartedAt":4}),
        );
        assert_eq!(
            result["items"][0]["playState"]["positionSeconds"].as_f64(),
            Some(42.0)
        );
        let before = r.buckets.clone();
        let result = call(
            &r,
            "page",
            &json!({"payloadJSON":json!({"items":[item("id")],"startIndex":i64::MAX,"limit":1,"requestStartedAt":4}).to_string()}),
        );
        assert!(result.is_err());
        assert_eq!(r.buckets.len(), before.len());
        for (name, bucket) in before {
            assert_eq!(r.buckets[&name].values, bucket.values);
            assert_eq!(r.buckets[&name].recency, bucket.recency);
        }
    }
}
