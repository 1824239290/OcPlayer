//! Shared media cache operations. Payloads retain the Apple Codable wire format
//! and unknown metadata; only progress and indexed fields are interpreted here.
use crate::{Store, StoreError};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

const VERSION: i64 = 1;

impl Store {
    pub fn cache_call(&self, method: &str, args: &Value) -> Result<Value, StoreError> {
        if method == "cache.vacuum" {
            self.connection.execute_batch("VACUUM")?;
            return Ok(Value::Null);
        }
        let read = matches!(
            method,
            "cache.hasContent"
                | "cache.item"
                | "cache.items"
                | "cache.posterCandidates"
                | "cache.libraries"
                | "cache.rail"
                | "cache.home"
                | "cache.page"
                | "cache.pages"
                | "cache.mediaFileInfo"
                | "cache.seasons"
                | "cache.episodes"
                | "cache.itemCount"
                | "cache.tmdbPayload"
                | "cache.tmdbLink"
                | "cache.tmdbLinkCount"
        );
        // IMMEDIATE serializes read/modify/write with other SQLite clients (GRDB).
        let tx = rusqlite::Transaction::new_unchecked(
            &self.connection,
            if read {
                TransactionBehavior::Deferred
            } else {
                TransactionBehavior::Immediate
            },
        )?;
        let result = dispatch(&tx, method, args)?;
        tx.commit()?;
        Ok(result)
    }
}

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, StoreError> {
    args[key]
        .as_str()
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be a string")))
}
fn array_arg<'a>(args: &'a Value, key: &str) -> Result<&'a Vec<Value>, StoreError> {
    args[key]
        .as_array()
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be an array")))
}
fn int_arg(args: &Value, key: &str) -> Result<i64, StoreError> {
    args[key]
        .as_i64()
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be an integer")))
}
fn time_arg(args: &Value, key: &str) -> Result<f64, StoreError> {
    args[key]
        .as_f64()
        .filter(|v| v.is_finite() && *v >= i64::MIN as f64 && *v < i64::MAX as f64)
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be a finite timestamp")))
}
fn payload(
    row: &rusqlite::Row<'_>,
    version: usize,
    data: usize,
) -> rusqlite::Result<Option<Value>> {
    if row.get::<_, Option<i64>>(version)? != Some(VERSION) {
        return Ok(None);
    }
    let bytes = row.get::<_, Option<Vec<u8>>>(data)?;
    Ok(bytes
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(Value::is_object))
}
fn cached_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<Option<Value>> {
    Ok(payload(row, 0, 1)?.map(|p| json!({"payload": p,
        "fetchedAt": row.get::<_, i64>(2).ok(), "progressFetchedAt": row.get::<_, Option<i64>>(3).ok().flatten()})))
}
fn load_item(db: &Connection, tenant: &str, id: &str) -> Result<Option<Value>, StoreError> {
    Ok(db.query_row("SELECT payload_version,payload,fetched_at,progress_fetched_at FROM item WHERE tenant_id=?1 AND item_id=?2",
        params![tenant,id], cached_item).optional()?.flatten())
}
fn load_payload(db: &Connection, tenant: &str, id: &str) -> Result<Option<Value>, StoreError> {
    Ok(load_item(db, tenant, id)?.map(|r| r["payload"].clone()))
}
fn upsert_item(
    db: &Connection,
    tenant: &str,
    item: &Value,
    now: i64,
    fresh: bool,
) -> Result<(), StoreError> {
    let id = str_arg(item, "id")?;
    let kind = item["kind"].as_str().unwrap_or("other");
    let state = &item["playState"];
    db.execute("INSERT INTO item(tenant_id,item_id,kind,name,year,series_id,season_id,season_number,episode_number,played,played_percentage,position_seconds,fetched_at,progress_fetched_at,payload_version,payload)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,1,?15)
        ON CONFLICT(tenant_id,item_id) DO UPDATE SET kind=excluded.kind,name=excluded.name,year=excluded.year,series_id=excluded.series_id,season_id=excluded.season_id,season_number=excluded.season_number,episode_number=excluded.episode_number,played=excluded.played,played_percentage=excluded.played_percentage,position_seconds=excluded.position_seconds,fetched_at=excluded.fetched_at,progress_fetched_at=excluded.progress_fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",
        params![tenant,id,kind,item["name"].as_str(),item["year"].as_i64(),item["seriesID"].as_str(),item["seasonID"].as_str(),item["seasonNumber"].as_i64(),item["episodeNumber"].as_i64(),state["played"].as_bool(),state["percentage"].as_f64(),state["positionSeconds"].as_f64(),now,fresh.then_some(now),serde_json::to_vec(item)?])?;
    Ok(())
}
fn set_state(
    db: &Connection,
    tenant: &str,
    id: &str,
    item: &Value,
    now: i64,
) -> Result<(), StoreError> {
    let state = &item["playState"];
    db.execute("UPDATE item SET played=?3,played_percentage=?4,position_seconds=?5,progress_fetched_at=?6,payload=?7 WHERE tenant_id=?1 AND item_id=?2",
        params![tenant,id,state["played"].as_bool(),state["percentage"].as_f64(),state["positionSeconds"].as_f64(),now,serde_json::to_vec(item)?])?;
    Ok(())
}
#[derive(Clone)]
struct LocalProgress {
    item: Value,
    recorded: f64,
    confirmed: Option<f64>,
    completed: bool,
}
impl LocalProgress {
    fn protects(&self, started: f64) -> bool {
        self.confirmed.is_none_or(|t| started <= t)
    }
    fn completion(&self) -> bool {
        self.completed
            && self.confirmed.is_some()
            && self.item["playState"]["played"] == true
            && self.item["playState"]["positionSeconds"].as_f64() == Some(0.0)
    }
    fn json(&self) -> Value {
        json!({"item":self.item,"recordedAt":self.recorded,"confirmedAt":self.confirmed,"completed":self.completed})
    }
}
fn local_records(
    db: &Connection,
    tenant: &str,
) -> Result<HashMap<String, LocalProgress>, StoreError> {
    let mut statement = db.prepare("SELECT p.item_id,p.recorded_at,p.confirmed_at,p.completed,p.payload_version,p.payload,i.payload_version,i.payload FROM local_progress p LEFT JOIN item i ON p.tenant_id=i.tenant_id AND p.item_id=i.item_id WHERE p.tenant_id=?1")?;
    let rows = statement.query_map([tenant], |r| {
        let Some(item) = payload(r, 4, 5)? else {
            return Ok(None);
        };
        let mut metadata = payload(r, 6, 7)?.unwrap_or_else(|| item.clone());
        metadata["playState"] = item["playState"].clone();
        Ok(Some((
            r.get::<_, String>(0)?,
            LocalProgress {
                item: metadata,
                recorded: r.get(1)?,
                confirmed: r.get(2)?,
                completed: r.get(3)?,
            },
        )))
    })?;
    Ok(rows
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect())
}
fn save_local(
    db: &Connection,
    tenant: &str,
    id: &str,
    record: &LocalProgress,
) -> Result<(), StoreError> {
    db.execute("INSERT INTO local_progress(tenant_id,item_id,recorded_at,confirmed_at,completed,payload_version,payload) VALUES(?1,?2,?3,?4,?5,1,?6)
        ON CONFLICT(tenant_id,item_id) DO UPDATE SET recorded_at=excluded.recorded_at,confirmed_at=excluded.confirmed_at,completed=excluded.completed,payload_version=excluded.payload_version,payload=excluded.payload",
        params![tenant,id,record.recorded,record.confirmed,record.completed,serde_json::to_vec(&record.item)?])?;
    Ok(())
}
fn reconcile(
    db: &Connection,
    tenant: &str,
    items: &[Value],
    rail: Option<&str>,
    started: f64,
    now: f64,
) -> Result<Vec<Value>, StoreError> {
    let mut pending = local_records(db, tenant)?;
    let mut merged = items.to_vec();
    for item in &mut merged {
        let id = str_arg(item, "id")?.to_owned();
        let Some(record) = pending.get_mut(&id) else {
            continue;
        };
        let local = &record.item["playState"];
        let remote = &item["playState"];
        if record.confirmed.is_none()
            && started >= record.recorded
            && local.is_object()
            && remote.is_object()
        {
            let same = local["played"] == remote["played"]
                && local["positionSeconds"]
                    .as_f64()
                    .zip(remote["positionSeconds"].as_f64())
                    .is_some_and(|(l, r)| (l - r).abs() < 1.0);
            let finished = record.completed && remote["played"] == true;
            if same || finished {
                if finished {
                    record.item["playState"] = remote.clone();
                }
                record.confirmed = Some(now);
            }
        }
        if record.protects(started) {
            item["playState"] = record.item["playState"].clone();
        }
        record.item = item.clone();
        save_local(db, tenant, &id, record)?;
    }
    if rail == Some("resume") {
        merged.retain(|i| {
            !pending
                .get(i["id"].as_str().unwrap_or(""))
                .is_some_and(LocalProgress::completion)
        });
        let mut ids: HashSet<String> = merged
            .iter()
            .filter_map(|i| i["id"].as_str().map(str::to_owned))
            .collect();
        let mut missing: Vec<_> = pending
            .into_values()
            .filter(|r| {
                r.protects(started)
                    && r.item["playState"]["played"] == false
                    && r.item["playState"]["positionSeconds"]
                        .as_f64()
                        .unwrap_or(0.0)
                        > 0.0
                    && !ids.contains(r.item["id"].as_str().unwrap_or(""))
            })
            .collect();
        missing.sort_by(|a, b| {
            b.recorded
                .total_cmp(&a.recorded)
                .then_with(|| a.item["id"].as_str().cmp(&b.item["id"].as_str()))
        });
        for r in missing {
            if ids.insert(str_arg(&r.item, "id")?.to_owned()) {
                merged.push(r.item);
            }
        }
    }
    Ok(merged)
}
fn project(db: &Connection, tenant: &str, items: &mut [Value]) -> Result<(), StoreError> {
    let ids: HashSet<_> = items.iter().filter_map(|i| i["id"].as_str()).collect();
    let mut states = HashMap::new();
    let ids: Vec<_> = ids.into_iter().collect();
    for batch in ids.chunks(900) {
        let placeholders = vec!["(?)"; batch.len()].join(",");
        let sql = format!("WITH requested(item_id) AS (VALUES {placeholders}),scope AS (SELECT ? AS tenant_id) SELECT requested.item_id,COALESCE(i.payload_version,p.payload_version),COALESCE(i.payload,p.payload) FROM requested CROSS JOIN scope LEFT JOIN item i ON i.tenant_id=scope.tenant_id AND i.item_id=requested.item_id LEFT JOIN local_progress p ON p.tenant_id=scope.tenant_id AND p.item_id=requested.item_id");
        let mut stmt = db.prepare(&sql)?;
        let rows = stmt.query_map(
            rusqlite::params_from_iter(batch.iter().copied().chain([tenant])),
            |r| {
                Ok(payload(r, 1, 2)?
                    .filter(|p| p["playState"].is_object())
                    .map(|p| {
                        (
                            r.get::<_, String>(0).unwrap_or_default(),
                            p["playState"].clone(),
                        )
                    }))
            },
        )?;
        for row in rows {
            if let Some((id, state)) = row? {
                states.insert(id, state);
            }
        }
    }
    for item in items {
        if let Some(s) = item["id"].as_str().and_then(|id| states.get(id)) {
            item["playState"] = s.clone();
        }
    }
    Ok(())
}
fn snapshot(db: &Connection, tenant: &str, name: &str) -> Result<Option<Value>, StoreError> {
    let row = db
        .query_row(
            "SELECT payload_version,payload,fetched_at FROM rail WHERE tenant_id=?1 AND rail=?2",
            params![tenant, name],
            |r| {
                Ok(payload(r, 0, 1)?
                    .map(|p| json!({"payload":p,"fetchedAt":r.get::<_,i64>(2).ok()})))
            },
        )
        .optional()?
        .flatten();
    project_snapshot(db, tenant, row)
}
fn project_snapshot(
    db: &Connection,
    tenant: &str,
    mut row: Option<Value>,
) -> Result<Option<Value>, StoreError> {
    if let Some(items) = row
        .as_mut()
        .and_then(|r| r["payload"]["items"].as_array_mut())
    {
        project(db, tenant, items)?;
    }
    Ok(row)
}
fn libraries(db: &Connection, tenant: &str) -> Result<Value, StoreError> {
    let mut stmt =
        db.prepare("SELECT payload,fetched_at FROM library WHERE tenant_id=?1 ORDER BY position")?;
    let rows = stmt.query_map([tenant], |r| {
        let bytes = r.get::<_, Vec<u8>>(0)?;
        Ok(serde_json::from_slice::<Value>(&bytes)
            .ok()
            .map(|p| json!({"payload":p,"fetchedAt":r.get::<_,i64>(1).ok()})))
    })?;
    Ok(json!(rows
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()))
}
fn compact_progress(db: &Connection) -> Result<(), StoreError> {
    let mut stmt=db.prepare("SELECT p.tenant_id,p.item_id,p.payload_version,p.payload FROM local_progress p WHERE p.confirmed_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM item i WHERE i.tenant_id=p.tenant_id AND i.item_id=p.item_id)")?;
    let rows = stmt.query_map([], |r| {
        Ok(payload(r, 2, 3)?.map(|p| {
            (
                r.get::<_, String>(0).unwrap_or_default(),
                r.get::<_, String>(1).unwrap_or_default(),
                p,
            )
        }))
    })?;
    for r in rows {
        if let Some((t, id, p)) = r? {
            let mut compact = json!({"id":p["id"],"name":p["name"],"kind":p["kind"]});
            if let Some(s) = p.get("playState") {
                compact["playState"] = s.clone();
            }
            db.execute(
                "UPDATE local_progress SET payload=?3 WHERE tenant_id=?1 AND item_id=?2",
                params![t, id, serde_json::to_vec(&compact)?],
            )?;
        }
    }
    Ok(())
}

fn dispatch(db: &Connection, method: &str, args: &Value) -> Result<Value, StoreError> {
    let tenant = if matches!(
        method,
        "cache.itemCount"
            | "cache.evictItems"
            | "cache.clearAll"
            | "cache.saveTMDbPayload"
            | "cache.tmdbPayload"
            | "cache.evictExpiredTMDb"
    ) {
        args["tenantId"].as_str().unwrap_or("")
    } else {
        str_arg(args, "tenantId")?
    };
    let now = || time_arg(args, "now");
    match method {
        "cache.touchTenant" => {
            let time=now()? as i64;
            db.execute("INSERT INTO tenant(tenant_id,kind,server_name,first_seen_at,last_seen_at) VALUES(?1,?2,?3,?4,?4) ON CONFLICT(tenant_id) DO UPDATE SET kind=excluded.kind,server_name=excluded.server_name,last_seen_at=excluded.last_seen_at",params![str_arg(args,"tenantId")?,str_arg(args,"kind")?,args["serverName"].as_str(),time])?;
            Ok(Value::Null)
        }
        "cache.hasContent" => Ok(json!(db.query_row("SELECT 1 FROM item WHERE tenant_id=?1 LIMIT 1",[tenant],|r|r.get::<_,i64>(0)).optional()?.is_some())),
        "cache.saveItems" => {
            let items=array_arg(args,"items")?; let rail=args["rail"].as_str(); let time=now()?;
            let merged=reconcile(db,tenant,items,rail,time_arg(args,"requestStartedAt")?,time)?;
            for item in &merged { upsert_item(db,tenant,item,time as i64,args["progressFresh"].as_bool().unwrap_or(true))?; }
            if let Some(name)=rail { save_rail(db,tenant,name,&merged,time as i64)?; }
            Ok(json!(merged))
        }
        "cache.item" => Ok(load_item(db,tenant,str_arg(args,"itemId")?)?.unwrap_or(Value::Null)),
        "cache.items" => {
            let ids=array_arg(args,"ids")?; let mut by_id=HashMap::new();
            for batch in ids.chunks(900) {
                let mut keys=vec![tenant]; for id in batch { keys.push(id.as_str().ok_or_else(||StoreError::InvalidRequest("ids must contain strings".into()))?); }
                let sql=format!("SELECT payload_version,payload,fetched_at,progress_fetched_at,item_id FROM item WHERE tenant_id=? AND item_id IN ({})",vec!["?";batch.len()].join(","));
                let mut stmt=db.prepare(&sql)?;
                for row in stmt.query_map(rusqlite::params_from_iter(keys),|r|Ok((r.get::<_,String>(4)?,cached_item(r)?)))? { let (id,p)=row?; if let Some(p)=p { by_id.insert(id,p); } }
            }
            Ok(json!(ids.iter().filter_map(|id|id.as_str().and_then(|id|by_id.get(id)).cloned()).collect::<Vec<_>>()))
        }
        "cache.posterCandidates" => {
            let limit=int_arg(args,"limit")?.max(0); let scan=limit.saturating_mul(8).max(240);
            let mut stmt=db.prepare("SELECT payload_version,payload,fetched_at,progress_fetched_at FROM item WHERE tenant_id=?1 AND kind IN ('movie','series') ORDER BY fetched_at DESC,item_id LIMIT ?2")?;
            let rows=stmt.query_map(params![tenant,scan],cached_item)?;
            let mut out=Vec::new(); for r in rows { if let Some(p)=r? { if !p["payload"]["primaryImageTag"].is_null() && (out.len() as i64)<limit { out.push(p); } } }
            Ok(json!(out))
        }
        "cache.updatePlayState" | "cache.recordPlaybackProgress" => {
            let time=now()?;
            let supplied=&args["item"];
            let id=if method=="cache.updatePlayState" { str_arg(args,"itemId")? } else { str_arg(supplied,"id")? };
            let local=local_records(db,tenant)?.remove(id);
            if let Some(ref r)=local { if r.recorded>time && r.item["playState"].is_object() {
                return Ok(json!({"state":r.item["playState"],"newerRecord":r.json()}));
            } }
            let stored=load_payload(db,tenant,id)?;
            let mut item=stored.clone().or_else(||supplied.is_object().then(||supplied.clone())).unwrap_or_else(||json!({"id":id,"name":id,"kind":"other"}));
            item["id"]=json!(id);
            let completed;
            if method=="cache.updatePlayState" {
                if !args["state"].is_object() { return Err(StoreError::InvalidRequest("state must be an object".into())); }
                item["playState"]=args["state"].clone(); completed=false;
            } else {
                let position=time_arg(args,"positionSeconds")?;
                if position<0.0 { return Err(StoreError::InvalidRequest("positionSeconds must be nonnegative".into())); }
                let duration=args["durationSeconds"].as_f64();
                let previous=stored.as_ref().map(|i|&i["playState"]).filter(|p|p.is_object())
                    .or_else(||local.as_ref().map(|r|&r.item["playState"]).filter(|p|p.is_object())).unwrap_or(&supplied["playState"]);
                let played=previous["played"].as_bool().unwrap_or(false);
                let percentage=if played {1.0} else { duration.filter(|d|*d>0.0).map(|d|(position/d).clamp(0.0,1.0)).unwrap_or_else(||previous["percentage"].as_f64().unwrap_or(0.0)) };
                let mut state=json!({"played":played,"percentage":percentage,"positionSeconds":position});
                if let Some(v)=previous.get("unplayedCount") { state["unplayedCount"]=v.clone(); }
                item["playState"]=state;
                completed=duration.is_some_and(|d|d>0.0 && position>=(d-2.0).max(0.0));
            }
            if method=="cache.recordPlaybackProgress" && stored.is_none() { upsert_item(db,tenant,&item,time as i64,true)?; }
            else { set_state(db,tenant,id,&item,time as i64)?; }
            let record=LocalProgress{item:item.clone(),recorded:time,confirmed:(method=="cache.updatePlayState").then_some(time),completed};
            save_local(db,tenant,id,&record)?;
            Ok(json!({"state":item["playState"],"newerRecord":null}))
        }
        "cache.saveLibraries" => {
            db.execute("DELETE FROM library WHERE tenant_id=?1",[tenant])?;
            let time=now()? as i64;
            for (index,p) in array_arg(args,"libraries")?.iter().enumerate() {
                db.execute("INSERT INTO library(tenant_id,library_id,position,fetched_at,payload) VALUES(?1,?2,?3,?4,?5)",params![tenant,str_arg(p,"id")?,index as i64,time,serde_json::to_vec(p)?])?;
            }
            Ok(Value::Null)
        }
        "cache.libraries" => libraries(db,tenant),
        "cache.saveRail" => { save_rail(db,tenant,str_arg(args,"rail")?,array_arg(args,"items")?,now()? as i64)?; Ok(Value::Null) }
        "cache.rail" => Ok(snapshot(db,tenant,str_arg(args,"rail")?)?.unwrap_or(Value::Null)),
        "cache.home" => {
            let mut rails=serde_json::Map::new();
            for name in ["resume","nextUp","latest"] { if let Some(r)=snapshot(db,tenant,name)? { rails.insert(name.into(),r); } }
            Ok(json!({"libraries":libraries(db,tenant)?,"rails":rails}))
        }
        "cache.savePage" => {
            let k=&args["key"];
            db.execute("INSERT INTO page(tenant_id,parent_id,kinds,sort_key,watch_state,search_term,start_index,limit_value,fetched_at,payload_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,1,?10) ON CONFLICT(tenant_id,parent_id,kinds,sort_key,watch_state,search_term,start_index,limit_value) DO UPDATE SET fetched_at=excluded.fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",
                params![tenant,str_arg(k,"parentID")?,str_arg(k,"kinds")?,str_arg(k,"sortKey")?,str_arg(k,"watchState")?,str_arg(k,"searchTerm")?,int_arg(k,"startIndex")?,int_arg(k,"limit")?,now()? as i64,serde_json::to_vec(&args["payload"])?])?;
            Ok(Value::Null)
        }
        "cache.page" | "cache.pages" => {
            let k=&args["key"]; let single=method=="cache.page";
            let sql=format!("SELECT payload_version,payload,fetched_at,start_index,limit_value FROM page WHERE tenant_id=?1 AND parent_id=?2 AND kinds=?3 AND sort_key=?4 AND watch_state=?5 AND search_term=?6 {} ORDER BY start_index,limit_value",if single {"AND start_index=?7 AND limit_value=?8"} else {""});
            let mut stmt=db.prepare(&sql)?;
            let mut keys: Vec<rusqlite::types::Value>=vec![tenant.to_owned().into(),str_arg(k,"parentID")?.to_owned().into(),str_arg(k,"kinds")?.to_owned().into(),str_arg(k,"sortKey")?.to_owned().into(),str_arg(k,"watchState")?.to_owned().into(),str_arg(k,"searchTerm")?.to_owned().into()];
            if single {keys.push(int_arg(k,"startIndex")?.into()); keys.push(int_arg(k,"limit")?.into());}
            let rows=stmt.query_map(rusqlite::params_from_iter(keys),|r|Ok(payload(r,0,1)?.map(|p|json!({"payload":p,"fetchedAt":r.get::<_,i64>(2).ok(),"startIndex":r.get::<_,i64>(3).ok(),"limit":r.get::<_,i64>(4).ok()}))))?;
            let mut pages=Vec::new(); for r in rows { if let Some(p)=project_snapshot(db,tenant,r?)? { pages.push(p); } }
            Ok(if single { pages.into_iter().next().unwrap_or(Value::Null) } else { json!(pages) })
        }
        "cache.saveMediaFileInfo" => {
            db.execute("INSERT INTO media_file_info(tenant_id,item_id,fetched_at,payload_version,payload) VALUES(?1,?2,?3,1,?4) ON CONFLICT(tenant_id,item_id) DO UPDATE SET fetched_at=excluded.fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",params![tenant,str_arg(args,"itemId")?,now()? as i64,serde_json::to_vec(&args["payload"])?])?;
            Ok(Value::Null)
        }
        "cache.mediaFileInfo" => Ok(db.query_row("SELECT payload_version,payload,fetched_at FROM media_file_info WHERE tenant_id=?1 AND item_id=?2",params![tenant,str_arg(args,"itemId")?],|r|Ok(payload(r,0,1)?.map(|p|json!({"payload":p,"fetchedAt":r.get::<_,i64>(2).ok()})))).optional()?.flatten().unwrap_or(Value::Null)),
        "cache.seasons" | "cache.episodes" => {
            let sql=if method=="cache.seasons" {"SELECT payload_version,payload FROM item WHERE tenant_id=?1 AND series_id=?2 AND kind='season' ORDER BY season_number IS NULL,season_number"} else {"SELECT payload_version,payload FROM item WHERE tenant_id=?1 AND series_id=?2 AND kind='episode' AND (season_id=?3 OR season_id IS NULL) ORDER BY episode_number IS NULL,episode_number"};
            let mut keys=vec![tenant,str_arg(args,"seriesId")?]; if method=="cache.episodes" { keys.push(str_arg(args,"seasonId")?); }
            let mut stmt=db.prepare(sql)?; let rows=stmt.query_map(rusqlite::params_from_iter(keys),|r|payload(r,0,1))?;
            Ok(json!(rows.collect::<Result<Vec<_>,_>>()?.into_iter().flatten().collect::<Vec<_>>()))
        }
        "cache.itemCount" => {
            let t=args["tenantId"].as_str(); let kind=args["kind"].as_str();
            Ok(json!(db.query_row("SELECT COUNT(*) FROM item WHERE (?1 IS NULL OR tenant_id=?1) AND (?2 IS NULL OR kind=?2)",params![t,kind],|r|r.get::<_,i64>(0))?))
        }
        "cache.evictItems" => {
            let max=int_arg(args,"maxItems")?.max(0);
            let total=db.query_row("SELECT COUNT(*) FROM item",[],|r|r.get::<_,i64>(0))?;
            let excess=(total-max).max(0);
            db.execute("DELETE FROM item WHERE (tenant_id,item_id) IN (SELECT tenant_id,item_id FROM item ORDER BY fetched_at ASC LIMIT ?1)",[excess])?;
            compact_progress(db)?; Ok(json!(excess))
        }
        "cache.clear" | "cache.clearAll" => {
            for table in ["local_progress","item","library","rail","page","media_file_info"] {
                if method=="cache.clear" {db.execute(&format!("DELETE FROM {table} WHERE tenant_id=?1"),[str_arg(args,"tenantId")?])?;}
                else {db.execute(&format!("DELETE FROM {table}"),[])?;}
            }
            if method=="cache.clearAll" {db.execute("DELETE FROM tenant",[])?;}
            Ok(Value::Null)
        }
        "cache.saveTMDbPayload" => {
            let time=now()?; let lifetime=time_arg(args,"lifetime")?.max(0.0);
            let expires=time+lifetime;
            if expires>=i64::MAX as f64 { return Err(StoreError::InvalidRequest("TMDB expiry overflows".into())); }
            db.execute("INSERT INTO tmdb_entity(entity_key,language,kind,tmdb_id,season_number,fetched_at,expires_at,payload_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,1,?8) ON CONFLICT(entity_key,language) DO UPDATE SET kind=excluded.kind,tmdb_id=excluded.tmdb_id,season_number=excluded.season_number,fetched_at=excluded.fetched_at,expires_at=excluded.expires_at,payload_version=excluded.payload_version,payload=excluded.payload",params![str_arg(args,"entityKey")?,str_arg(args,"language")?,str_arg(args,"kind")?,int_arg(args,"tmdbId")?,args["seasonNumber"].as_i64(),time as i64,expires as i64,serde_json::to_vec(&args["payload"])?])?;
            Ok(Value::Null)
        }
        "cache.tmdbPayload" => Ok(db.query_row("SELECT payload_version,payload,fetched_at,expires_at FROM tmdb_entity WHERE entity_key=?1 AND language=?2",params![str_arg(args,"entityKey")?,str_arg(args,"language")?],|r|Ok(payload(r,0,1)?.map(|p|json!({"payload":p,"fetchedAt":r.get::<_,i64>(2).ok(),"expiresAt":r.get::<_,i64>(3).ok()})))).optional()?.flatten().unwrap_or(Value::Null)),
        "cache.saveTMDbLink" => {
            db.execute("INSERT INTO tmdb_link(tenant_id,item_id,entity_key,source,confidence,linked_at) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(tenant_id,item_id) DO UPDATE SET entity_key=excluded.entity_key,source=excluded.source,confidence=excluded.confidence,linked_at=excluded.linked_at",params![tenant,str_arg(args,"itemId")?,str_arg(args,"entityKey")?,str_arg(args,"source")?,time_arg(args,"confidence")?,now()? as i64])?;
            Ok(Value::Null)
        }
        "cache.tmdbLink" => Ok(db.query_row("SELECT entity_key,source,confidence,linked_at FROM tmdb_link WHERE tenant_id=?1 AND item_id=?2",params![tenant,str_arg(args,"itemId")?],|r|Ok(json!({"entityKey":r.get::<_,String>(0)?,"source":r.get::<_,String>(1)?,"confidence":r.get::<_,f64>(2)?,"linkedAt":r.get::<_,i64>(3)?}))).optional()?.unwrap_or(Value::Null)),
        "cache.removeTMDbLink" => { db.execute("DELETE FROM tmdb_link WHERE tenant_id=?1 AND item_id=?2",params![tenant,str_arg(args,"itemId")?])?; Ok(Value::Null) }
        "cache.tmdbLinkCount" => Ok(json!(db.query_row("SELECT COUNT(*) FROM tmdb_link WHERE tenant_id=?1",[tenant],|r|r.get::<_,i64>(0))?)),
        "cache.evictExpiredTMDb" => { let count=db.execute("DELETE FROM tmdb_entity WHERE expires_at<=?1",[now()? as i64])?; Ok(json!(count)) }
        "cache.clearTMDb" => {
            db.execute("DELETE FROM tmdb_link WHERE tenant_id=?1",[tenant])?;
            db.execute("DELETE FROM tmdb_entity WHERE NOT EXISTS (SELECT 1 FROM tmdb_link WHERE tmdb_link.entity_key=tmdb_entity.entity_key)",[])?;
            Ok(Value::Null)
        }
        _ => Err(StoreError::InvalidRequest(format!("unknown cache command: {method}"))),
    }
}
fn save_rail(
    db: &Connection,
    tenant: &str,
    name: &str,
    items: &[Value],
    now: i64,
) -> Result<(), StoreError> {
    db.execute("INSERT INTO rail(tenant_id,rail,fetched_at,payload_version,payload) VALUES(?1,?2,?3,1,?4) ON CONFLICT(tenant_id,rail) DO UPDATE SET fetched_at=excluded.fetched_at,payload_version=excluded.payload_version,payload=excluded.payload",params![tenant,name,now,serde_json::to_vec(&json!({"items":items}))?])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_failure_rolls_back_items_rail_and_progress_confirmation() {
        let store = Store::open(":memory:").unwrap();
        let item = json!({"id":"episode", "name":"Full title", "kind":"episode",
            "futureMetadata":{"value":7}, "playState":{"played":false,"percentage":0.0,"positionSeconds":0.0}});
        store.cache_call("cache.saveItems", &json!({"tenantId":"t", "items":[item], "rail":"resume", "now":10.0,"requestStartedAt":9.0})).unwrap();
        store.cache_call("cache.recordPlaybackProgress", &json!({"tenantId":"t", "item":item,"positionSeconds":25.0,"durationSeconds":100.0,"now":20.125})).unwrap();
        let mut matching = item.clone();
        matching["playState"]["positionSeconds"] = json!(25.0);
        let result = store.cache_call("cache.saveItems", &json!({"tenantId":"t","items":[matching,{"name":"missing id"}],"rail":"resume","now":30.0,"requestStartedAt":21.0}));
        assert!(matches!(result, Err(StoreError::InvalidRequest(_))));
        let p = store.progress("t", "episode").unwrap().unwrap();
        assert_eq!(
            p.confirmed_at, None,
            "failed response must not confirm progress"
        );
        assert_eq!(p.recorded_at, 20.125);
        let read = store
            .cache_call("cache.item", &json!({"tenantId":"t","itemId":"episode"}))
            .unwrap();
        assert_eq!(read["payload"]["futureMetadata"]["value"], 7);
        assert_eq!(read["fetchedAt"], 10);
        assert_eq!(read["payload"]["playState"]["positionSeconds"], 25.0);
        let rail = store
            .cache_call("cache.rail", &json!({"tenantId":"t","rail":"resume"}))
            .unwrap();
        assert_eq!(rail["fetchedAt"], 10);
    }

    #[test]
    fn large_item_and_snapshot_reads_chunk_parameters_and_preserve_requested_order() {
        let store = Store::open(":memory:").unwrap();
        let items: Vec<_> = (0..1905)
            .map(|i| json!({"id":format!("ep-{i}"),"name":format!("Episode {i}"),"kind":"episode"}))
            .collect();
        store
            .cache_call(
                "cache.saveItems",
                &json!({"tenantId":"t","items":items,"now":10.0,"requestStartedAt":9.0}),
            )
            .unwrap();
        store
            .cache_call(
                "cache.saveRail",
                &json!({"tenantId":"t","items":items,"rail":"latest","now":11.0}),
            )
            .unwrap();
        let mut ids: Vec<_> = items.iter().rev().map(|i| i["id"].clone()).collect();
        ids.push(json!("missing"));
        ids.push(ids[0].clone());
        let read = store
            .cache_call("cache.items", &json!({"tenantId":"t","ids":ids}))
            .unwrap();
        assert_eq!(read.as_array().unwrap().len(), 1906);
        assert_eq!(read[0]["payload"]["id"], "ep-1904");
        assert_eq!(read[1905]["payload"]["id"], "ep-1904");
        let rail = store
            .cache_call("cache.rail", &json!({"tenantId":"t","rail":"latest"}))
            .unwrap();
        assert_eq!(rail["payload"]["items"].as_array().unwrap().len(), 1905);
        let other = store
            .cache_call("cache.items", &json!({"tenantId":"other","ids":ids}))
            .unwrap();
        assert!(other.as_array().unwrap().is_empty());
    }

    #[test]
    fn malformed_payload_and_future_versions_are_misses_and_do_not_break_updates() {
        let store = Store::open(":memory:").unwrap();
        store.connection.execute("INSERT INTO item(tenant_id,item_id,kind,fetched_at,payload_version,payload) VALUES('t','one','movie',1,1,?1)",[b"[]".as_slice()]).unwrap();
        assert_eq!(
            store
                .cache_call("cache.item", &json!({"tenantId":"t","itemId":"one"}))
                .unwrap(),
            Value::Null
        );
        store.cache_call("cache.recordPlaybackProgress",&json!({"tenantId":"t","item":{"id":"one","name":"Replacement","kind":"movie"},"now":20.0,"positionSeconds":3.0})).unwrap();
        let item = store
            .cache_call("cache.item", &json!({"tenantId":"t","itemId":"one"}))
            .unwrap();
        assert_eq!(item["payload"]["name"], "Replacement");
        store
            .connection
            .execute("UPDATE item SET payload_version=999", [])
            .unwrap();
        assert_eq!(
            store
                .cache_call("cache.item", &json!({"tenantId":"t","itemId":"one"}))
                .unwrap(),
            Value::Null
        );
        assert!(matches!(
            store.cache_call("cache.item", &json!({"itemId":"one"})),
            Err(StoreError::InvalidRequest(_))
        ));
    }
}
