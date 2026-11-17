//! Cache-only continuations share the same projection identity and read effects.
use super::*;
fn commit(f: &mut Flow, effect: &str, value: Value, fetched: f64, remember: Value) -> Value {
    f.result = json!({"value":value,"fetchedAt":fetched,"source":"disk"});
    let field = match effect {
        "commitCachedHome" => "homeSnapshot",
        "commitCachedItem" => "itemSnapshot",
        "commitCachedDetail" => "detailSnapshot",
        "commitCachedPage" => "pageSnapshot",
        _ => "episodeSnapshot",
    };
    let mut args = json!({"itemID":f.input["itemID"],"seriesID":f.input["seriesID"],"seasonID":f.input["seasonID"],"descriptor":f.input["descriptor"],"items":remember});
    args[field] = f.result.clone();
    f.effect(effect, args)
}
fn detail_commit(f: &mut Flow) -> Result<Value, String> {
    let remember = f.content["seasons"]
        .as_array()
        .ok_or("seasons required")?
        .iter()
        .chain(
            f.content["episodes"]
                .as_array()
                .ok_or("episodes required")?,
        )
        .chain(
            f.content["collectionMembers"]
                .as_array()
                .ok_or("members required")?,
        )
        .cloned()
        .collect::<Vec<_>>();
    Ok(commit(
        f,
        "commitCachedDetail",
        f.content.clone(),
        clock(&f.parts, "fetchedAt")?,
        json!(remember),
    ))
}
pub(super) fn begin(f: &mut Flow, repo: &mut Repository) -> Result<Value, String> {
    let (bucket, key) = match f.kind.as_str() {
        "cachedHome" => ("home", json!("home")),
        "cachedItem" => ("items", f.input["itemID"].clone()),
        "cachedDetail" => ("details", f.input["itemID"].clone()),
        "cachedPage" => ("pages", f.input["descriptor"].clone()),
        "cachedEpisodes" => (
            "episodes",
            json!({"seriesID":f.input["seriesID"],"seasonID":f.input["seasonID"]}),
        ),
        _ => return Err("invalid cached kind".into()),
    };
    let entry = repo.call(
        "get",
        &json!({"bucket":bucket,"payloadJSON":json!({"key":key}).to_string()}),
    )?;
    if !entry.is_null() {
        return Ok(f.done(
            json!({"value":entry["value"],"fetchedAt":entry["fetchedAt"],"source":"memory"}),
        ));
    }
    Ok(match f.kind.as_str() {
        "cachedHome" => f.effect("readCachedHome", json!({})),
        "cachedPage" => f.effect(
            "readCachedPages",
            json!({"descriptor":f.input["descriptor"],"key":f.input["key"]}),
        ),
        "cachedEpisodes" => f.effect(
            "readCachedEpisodes",
            json!({"seriesID":f.input["seriesID"],"seasonID":f.input["seasonID"]}),
        ),
        _ => f.effect("readCachedItem", json!({"itemID":f.input["itemID"]})),
    })
}
pub(super) fn advance(
    f: &mut Flow,
    repo: &Repository,
    response: Value,
    now: f64,
) -> Result<Value, String> {
    match f.phase.as_str() {
        "readCachedHome" => {
            if response.is_null() {
                return Ok(f.done(Value::Null));
            }
            let disk = compose(repo, "diskHome", response)?;
            if disk.is_null() {
                return Ok(f.done(Value::Null));
            }
            let value = disk["value"].clone();
            let remember = value["resume"]
                .as_array()
                .unwrap()
                .iter()
                .chain(value["nextUp"].as_array().unwrap())
                .chain(value["latest"].as_array().unwrap())
                .cloned()
                .collect::<Vec<_>>();
            Ok(commit(
                f,
                "commitCachedHome",
                value,
                clock(&disk, "fetchedAt")?,
                json!(remember),
            ))
        }
        "readCachedItem" => {
            if response.is_null() {
                return Ok(f.done(Value::Null));
            }
            item(&response["item"])?;
            let fetched = clock(&response, "fetchedAt")?;
            if f.kind == "cachedItem" {
                return Ok(commit(
                    f,
                    "commitCachedItem",
                    response["item"].clone(),
                    fetched,
                    json!([]),
                ));
            }
            f.parts = response;
            f.content = blank_detail(f.parts["item"].clone());
            if f.content["item"]["kind"] == "series" && f.input["hasStore"] == true {
                Ok(f.effect("readCachedSeasons", json!({"seriesID":f.input["itemID"]})))
            } else if f.content["item"]["kind"] == "boxSet" {
                Ok(f.effect(
                    "readCachedMembers",
                    json!({"descriptor":collection(&f.input["itemID"]),"limit":200}),
                ))
            } else {
                detail_commit(f)
            }
        }
        "readCachedSeasons" => {
            let seasons = if response.is_null() {
                json!([])
            } else {
                response
            };
            items(&seasons)?;
            let season = compose(repo, "defaultSeason", json!({"seasons":seasons}))?;
            f.content["seasons"] = seasons;
            if season.is_null() {
                return detail_commit(f);
            }
            f.content["episodesSeasonID"] = season.clone();
            Ok(f.effect(
                "readDetailCachedEpisodes",
                json!({"seriesID":f.input["itemID"],"seasonID":season}),
            ))
        }
        "readDetailCachedEpisodes" => {
            let episodes = if response.is_null() {
                json!([])
            } else {
                response
            };
            items(&episodes)?;
            f.content["episodes"] = episodes;
            detail_commit(f)
        }
        "readCachedMembers" => {
            if !response.is_null() {
                items(&response["value"]["items"])?;
                f.content["collectionMembers"] = response["value"]["items"].clone();
                if !response["value"]["totalCount"].is_null() {
                    response["value"]["totalCount"]
                        .as_i64()
                        .ok_or("totalCount must be Int64")?;
                    f.content["collectionMembersTotalCount"] =
                        response["value"]["totalCount"].clone();
                }
            }
            detail_commit(f)
        }
        "readCachedPages" => {
            if response.is_null() {
                return Ok(f.done(Value::Null));
            }
            let rows = response.as_array().ok_or("rows array required")?;
            if rows.is_empty() {
                return Ok(f.done(Value::Null));
            }
            let content = compose(repo, "diskPage", json!({"rows":response}))?;
            let fetched = rows
                .iter()
                .map(|row| clock(row, "fetchedAt"))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .reduce(f64::min)
                .unwrap_or(now);
            if content["items"].as_array().unwrap().is_empty() {
                return Ok(f.done(Value::Null));
            }
            Ok(commit(
                f,
                "commitCachedPage",
                content.clone(),
                fetched,
                content["items"].clone(),
            ))
        }
        "readCachedEpisodes" => {
            if response.is_null() {
                return Ok(f.done(Value::Null));
            }
            items(&response)?;
            if response.as_array().unwrap().is_empty() {
                return Ok(f.done(Value::Null));
            }
            Ok(commit(
                f,
                "commitCachedEpisodes",
                response.clone(),
                now,
                response,
            ))
        }
        "commitCachedHome"
        | "commitCachedItem"
        | "commitCachedDetail"
        | "commitCachedPage"
        | "commitCachedEpisodes" => Ok(f.done(f.result.clone())),
        _ => Err("invalid cached effect".into()),
    }
}
