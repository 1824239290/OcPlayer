//! Bangumi.sqlite repository and progress policy, compatible with Apple GRDB.
use crate::StoreError;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub struct BangumiStore {
    connection: Connection,
}

impl BangumiStore {
    pub fn open(path: &str) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", true)?;
        if path != ":memory:" {
            connection.pragma_update(None, "journal_mode", "WAL")?;
        }
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS grdb_migrations(identifier TEXT PRIMARY KEY)",
        )?;
        for (name, sql) in [
            (
                "createBangumiSchemaV1",
                include_str!("../../../schema/bangumi_v1.sql"),
            ),
            (
                "addEpisodesSyncedAt",
                "ALTER TABLE subjects ADD COLUMN episodes_synced_at INTEGER NOT NULL DEFAULT 0",
            ),
        ] {
            let tx =
                rusqlite::Transaction::new_unchecked(&connection, TransactionBehavior::Immediate)?;
            let applied = tx
                .query_row(
                    "SELECT 1 FROM grdb_migrations WHERE identifier=?1",
                    [name],
                    |r| r.get::<_, i64>(0),
                )
                .optional()?
                .is_some();
            if !applied {
                tx.execute_batch(sql)?;
                tx.execute("INSERT INTO grdb_migrations(identifier) VALUES(?1)", [name])?;
            }
            tx.commit()?;
        }
        Ok(Self { connection })
    }

    pub fn call(&self, method: &str, args: &Value) -> Result<Value, StoreError> {
        let read = matches!(
            method,
            "subjects"
                | "subject"
                | "episodes"
                | "episodeCounts"
                | "progressSubjects"
                | "progressSubject"
                | "progressCounts"
                | "collectionCounts"
                | "collectionSubjects"
                | "missingEpisodes"
                | "staleEpisodeProgress"
                | "subjectID"
                | "syncTargets"
        );
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

fn int(args: &Value, key: &str) -> Result<i64, StoreError> {
    args[key]
        .as_i64()
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be an integer")))
}
fn array<'a>(args: &'a Value, key: &str) -> Result<&'a Vec<Value>, StoreError> {
    args[key]
        .as_array()
        .ok_or_else(|| StoreError::InvalidRequest(format!("{key} must be an array")))
}
fn now(args: &Value) -> Result<i64, StoreError> {
    int(args, "now")
}
fn blob(row: &rusqlite::Row<'_>, key: &str) -> rusqlite::Result<Option<Value>> {
    Ok(row
        .get::<_, Option<Vec<u8>>>(key)?
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(|v| !v.is_null()))
}
fn number(row: &rusqlite::Row<'_>, key: &str) -> rusqlite::Result<i64> {
    Ok(row.get::<_, Option<i64>>(key)?.unwrap_or_default())
}
fn text(row: &rusqlite::Row<'_>, key: &str) -> rusqlite::Result<String> {
    Ok(row.get::<_, Option<String>>(key)?.unwrap_or_default())
}
fn airtime() -> Value {
    json!({"date":"","month":0,"weekday":0,"year":0})
}
fn rating() -> Value {
    json!({"count":[],"total":0,"score":0,"rank":0})
}
fn interest() -> Value {
    json!({"comment":"","epStatus":0,"volStatus":0,"private":false,"rate":0,"tags":[],"type":2,"updatedAt":0})
}
fn valid_interest(v: &Value) -> bool {
    v.is_object()
        && v["comment"].is_string()
        && v["tags"].is_array()
        && v["private"].is_boolean()
        && ["epStatus", "volStatus", "rate", "type", "updatedAt"]
            .iter()
            .all(|k| v[k].as_i64().is_some())
}
fn valid_blob(key: &str, v: &Value) -> bool {
    match key {
        "interest" => {
            valid_interest(v)
                && (0..=5).contains(&v["type"].as_i64().unwrap_or(-1))
                && v["tags"]
                    .as_array()
                    .is_some_and(|a| a.iter().all(Value::is_string))
        }
        "collection" => v
            .as_object()
            .is_some_and(|o| o.values().all(|v| v.as_i64().is_some())),
        "metaTags" => v.as_array().is_some_and(|a| a.iter().all(Value::is_string)),
        "infobox" => v
            .as_array()
            .is_some_and(|a| a.iter().all(|v| v["key"].is_string())),
        "tags" => v.is_array(),
        "platform" => {
            v.is_object()
                && ["alias", "type", "typeCN"].iter().all(|k| v[k].is_string())
                && v["id"].as_i64().is_some()
                && ["searchString", "wikiTpl"]
                    .iter()
                    .all(|k| v[k].is_null() || v[k].is_string())
                && (v["sortKeys"].is_null()
                    || v["sortKeys"]
                        .as_array()
                        .is_some_and(|a| a.iter().all(Value::is_string)))
        }
        _ => v.is_object(),
    }
}

fn subject_type(t: i64) -> i64 {
    if [0, 1, 2, 3, 4, 6].contains(&t) {
        t
    } else {
        0
    }
}
fn episode_type(t: i64) -> i64 {
    if (0..=6).contains(&t) {
        t
    } else {
        0
    }
}

#[derive(Clone)]
struct Subject {
    data: Value,
    alias: String,
    ctype: i64,
    collected: i64,
    synced: i64,
}
impl Subject {
    fn new(id: i64) -> Self {
        Self {
            data: json!({"id":id,"airtime":airtime(),"collection":{},"eps":0,"infobox":[],"info":"","locked":false,"metaTags":[],"tags":[],"name":"","nameCN":"","nsfw":false,"platform":{"alias":"","id":0,"searchString":"","sortKeys":[],"type":"","typeCN":"","wikiTpl":""},"rating":rating(),"redirect":0,"series":false,"seriesEntry":0,"summary":"","type":0,"volumes":0}),
            alias: String::new(),
            ctype: 0,
            collected: 0,
            synced: 0,
        }
    }
    fn merge(&mut self, incoming: &Value, slim: bool, authoritative: bool) {
        let fields: &[&str] = if slim {
            &["locked", "metaTags", "name", "nameCN", "nsfw", "type"]
        } else {
            &[
                "airtime",
                "collection",
                "eps",
                "infobox",
                "info",
                "locked",
                "metaTags",
                "tags",
                "name",
                "nameCN",
                "nsfw",
                "platform",
                "rating",
                "series",
                "summary",
                "type",
                "volumes",
            ]
        };
        let defaults = Self::new(self.data["id"].as_i64().unwrap_or_default()).data;
        for key in fields {
            self.data[key] = incoming
                .get(key)
                .cloned()
                .unwrap_or_else(|| defaults[key].clone());
        }
        for key in if slim {
            &["images", "info", "rating"][..]
        } else {
            &["images"][..]
        } {
            if let Some(value) = incoming.get(key).filter(|v| !v.is_null()) {
                self.data[key] = value.clone();
            }
        }
        if let Some(value) = incoming.get("interest").filter(|v| v.is_object()) {
            let mut next = if slim {
                self.data
                    .get("interest")
                    .filter(|v| valid_interest(v))
                    .cloned()
                    .unwrap_or_else(interest)
            } else {
                value.clone()
            };
            if slim {
                for key in ["comment", "rate", "tags", "type", "updatedAt"] {
                    next[key] = value[key].clone();
                }
            }
            self.ctype = next["type"].as_i64().unwrap_or_default();
            self.collected = next["updatedAt"].as_i64().unwrap_or_default();
            self.data["interest"] = next;
        } else if !slim && authoritative {
            self.data.as_object_mut().unwrap().remove("interest");
            self.ctype = 0;
            self.collected = 0;
        }
    }
}
fn read_subject(r: &rusqlite::Row<'_>) -> rusqlite::Result<Subject> {
    let mut s = Subject::new(number(r, "subject_id")?);
    for (key, column) in [
        ("airtime", "airtime_data"),
        ("collection", "collection_data"),
        ("images", "images_data"),
        ("infobox", "infobox_data"),
        ("metaTags", "meta_tags_data"),
        ("tags", "tags_data"),
        ("platform", "platform_data"),
        ("rating", "rating_data"),
        ("interest", "interest_data"),
    ] {
        if let Some(v) = blob(r, column)? {
            if valid_blob(key, &v) {
                s.data[key] = v;
            }
        }
    }
    for (key, column) in [("eps", "eps"), ("volumes", "volumes")] {
        s.data[key] = json!(number(r, column)?);
    }
    s.data["type"] = json!(subject_type(number(r, "type")?));
    for (key, column) in [("locked", "locked"), ("nsfw", "nsfw"), ("series", "series")] {
        s.data[key] = json!(number(r, column)? != 0);
    }
    for (key, column) in [
        ("name", "name"),
        ("nameCN", "name_cn"),
        ("summary", "summary"),
        ("info", "info"),
    ] {
        s.data[key] = json!(text(r, column)?);
    }
    s.alias = text(r, "alias")?;
    s.ctype = number(r, "ctype")?;
    s.collected = number(r, "collected_at")?;
    s.synced = number(r, "episodes_synced_at")?;
    Ok(s)
}
fn get_subject(db: &Connection, id: i64) -> Result<Option<Subject>, StoreError> {
    Ok(db
        .query_row(
            "SELECT * FROM subjects WHERE subject_id=?1",
            [id],
            read_subject,
        )
        .optional()?)
}
fn encode(value: &Value) -> Result<Option<Vec<u8>>, StoreError> {
    if value.is_null() {
        Ok(None)
    } else {
        Ok(Some(serde_json::to_vec(value)?))
    }
}
fn save_subject(db: &Connection, s: &Subject) -> Result<(), StoreError> {
    let d = &s.data;
    db.execute("INSERT INTO subjects(subject_id,airtime_data,collection_data,eps,images_data,infobox_data,locked,meta_tags_data,tags_data,name,name_cn,nsfw,platform_data,rating_data,series,summary,type,volumes,info,alias,ctype,collected_at,interest_data)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)
      ON CONFLICT(subject_id) DO UPDATE SET airtime_data=excluded.airtime_data,collection_data=excluded.collection_data,eps=excluded.eps,images_data=excluded.images_data,infobox_data=excluded.infobox_data,locked=excluded.locked,meta_tags_data=excluded.meta_tags_data,tags_data=excluded.tags_data,name=excluded.name,name_cn=excluded.name_cn,nsfw=excluded.nsfw,platform_data=excluded.platform_data,rating_data=excluded.rating_data,series=excluded.series,summary=excluded.summary,type=excluded.type,volumes=excluded.volumes,info=excluded.info,alias=excluded.alias,ctype=excluded.ctype,collected_at=excluded.collected_at,interest_data=excluded.interest_data",
      params![int(d,"id")?,encode(&d["airtime"])?,encode(&d["collection"])?,d["eps"].as_i64().unwrap_or_default(),encode(&d["images"])?,encode(&d["infobox"])?,d["locked"].as_bool().unwrap_or(false),encode(&d["metaTags"])?,encode(&d["tags"])?,d["name"].as_str().unwrap_or(""),d["nameCN"].as_str().unwrap_or(""),d["nsfw"].as_bool().unwrap_or(false),encode(&d["platform"])?,encode(&d["rating"])?,d["series"].as_bool().unwrap_or(false),d["summary"].as_str().unwrap_or(""),d["type"].as_i64().unwrap_or_default(),d["volumes"].as_i64().unwrap_or_default(),d["info"].as_str().unwrap_or(""),s.alias,s.ctype,s.collected,encode(&d["interest"]) ?])?;
    Ok(())
}
#[derive(Clone)]
struct Episode {
    data: Value,
    status: i64,
    collected: i64,
}
impl Episode {
    fn new(item: &Value) -> Result<Self, StoreError> {
        let mut e = Self {
            data: json!({"id":int(item,"id")?,"subjectID":int(item,"subjectID")?,"type":0,"sort":0.0,"name":"","nameCN":"","duration":"","airdate":"","comment":0,"disc":0}),
            status: 0,
            collected: 0,
        };
        e.merge(item, false);
        Ok(e)
    }
    fn merge(&mut self, item: &Value, authoritative: bool) {
        for key in [
            "subjectID",
            "type",
            "sort",
            "name",
            "nameCN",
            "duration",
            "airdate",
            "comment",
            "disc",
        ] {
            if let Some(v) = item.get(key) {
                self.data[key] = v.clone();
            }
        }
        if let Some(sort) = self.data["sort"].as_f64() {
            self.data["sort"] = json!(sort as f32);
        }
        if let Some(desc) = item["desc"].as_str().filter(|s| !s.is_empty()) {
            self.data["desc"] = json!(desc);
        }
        if let Some(c) = item.get("collection").filter(|v| v.is_object()) {
            self.status = c["status"].as_i64().unwrap_or_default();
            if let Some(t) = c["updatedAt"].as_i64() {
                self.collected = t;
            }
        } else if authoritative {
            self.status = 0;
            self.collected = 0;
        }
    }
    fn dto(&self) -> Value {
        let mut d = self.data.clone();
        let mut c = json!({"status":self.status});
        if self.collected != 0 {
            c["updatedAt"] = json!(self.collected);
        }
        d["collection"] = c;
        d
    }
}
fn read_episode(r: &rusqlite::Row<'_>) -> rusqlite::Result<Episode> {
    let sort = r.get::<_, Option<f64>>("sort")?.unwrap_or_default() as f32;
    let mut d = json!({"id":number(r,"episode_id")?,"subjectID":number(r,"subject_id")?,"type":episode_type(number(r,"type")?),"sort":sort,"name":text(r,"name")?,"nameCN":text(r,"name_cn")?,"duration":text(r,"duration")?,"airdate":text(r,"airdate")?,"comment":number(r,"comment")?,"disc":number(r,"disc")?});
    let desc = text(r, "desc")?;
    if !desc.is_empty() {
        d["desc"] = json!(desc);
    }
    Ok(Episode {
        data: d,
        status: number(r, "status")?,
        collected: number(r, "collected_at")?,
    })
}
fn get_episode(db: &Connection, id: i64) -> Result<Option<Episode>, StoreError> {
    Ok(db
        .query_row(
            "SELECT * FROM episodes WHERE episode_id=?1",
            [id],
            read_episode,
        )
        .optional()?)
}
fn save_episode(db: &Connection, e: &Episode) -> Result<(), StoreError> {
    let d = &e.data;
    db.execute("INSERT INTO episodes(episode_id,subject_id,type,sort,name,name_cn,duration,airdate,comment,disc,desc,status,collected_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
      ON CONFLICT(episode_id) DO UPDATE SET subject_id=excluded.subject_id,type=excluded.type,sort=excluded.sort,name=excluded.name,name_cn=excluded.name_cn,duration=excluded.duration,airdate=excluded.airdate,comment=excluded.comment,disc=excluded.disc,desc=excluded.desc,status=excluded.status,collected_at=excluded.collected_at",
      params![int(d,"id")?,int(d,"subjectID")?,int(d,"type")?,d["sort"].as_f64().unwrap_or_default(),d["name"].as_str().unwrap_or(""),d["nameCN"].as_str().unwrap_or(""),d["duration"].as_str().unwrap_or(""),d["airdate"].as_str().unwrap_or(""),d["comment"].as_i64().unwrap_or_default(),d["disc"].as_i64().unwrap_or_default(),d["desc"].as_str().unwrap_or(""),e.status,e.collected])?;
    Ok(())
}
fn progress_window(sorted: &[Episode], size: i64) -> Vec<Episode> {
    let size = size.max(1) as usize;
    let Some(next) = sorted.iter().find(|e| e.status == 0) else {
        return sorted[sorted.len().saturating_sub(size)..].to_vec();
    };
    let sort = next.data["sort"].as_f64().unwrap_or_default();
    let pool = size - 1;
    let before: Vec<_> = sorted
        .iter()
        .filter(|e| e.data["sort"].as_f64().unwrap_or_default() < sort)
        .collect();
    let before = &before[before.len().saturating_sub(pool)..];
    let after: Vec<_> = sorted
        .iter()
        .filter(|e| e.data["sort"].as_f64().unwrap_or_default() > sort)
        .take(pool)
        .collect();
    let half_before = pool / 2;
    let half_after = pool - half_before;
    let (b, a) = if before.len() < half_before {
        (before.len(), after.len().min(size - before.len() - 1))
    } else if after.len() < half_after {
        (before.len().min(size - after.len() - 1), after.len())
    } else {
        (half_before, half_after)
    };
    before[before.len() - b..]
        .iter()
        .copied()
        .chain([next])
        .chain(after[..a].iter().copied())
        .cloned()
        .collect()
}
fn query_episodes(
    db: &Connection,
    sql: &str,
    keys: impl rusqlite::Params,
) -> Result<Vec<Episode>, StoreError> {
    let mut stmt = db.prepare(sql)?;
    let rows = stmt
        .query_map(keys, read_episode)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}
fn query_subjects(
    db: &Connection,
    sql: &str,
    keys: impl rusqlite::Params,
) -> Result<Vec<Subject>, StoreError> {
    let mut stmt = db.prepare(sql)?;
    let rows = stmt
        .query_map(keys, read_subject)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}
fn subjects_by_id(db: &Connection, ids: &[i64]) -> Result<HashMap<i64, Subject>, StoreError> {
    let mut out = HashMap::new();
    for batch in ids.chunks(900) {
        let sql = format!(
            "SELECT * FROM subjects WHERE subject_id IN ({})",
            vec!["?"; batch.len()].join(",")
        );
        for s in query_subjects(db, &sql, rusqlite::params_from_iter(batch))? {
            out.insert(int(&s.data, "id")?, s);
        }
    }
    Ok(out)
}
fn make_progress(
    db: &Connection,
    subjects: Vec<Subject>,
    size: i64,
) -> Result<Vec<Value>, StoreError> {
    let ids: Vec<_> = subjects
        .iter()
        .filter(|s| [2, 6].contains(&s.data["type"].as_i64().unwrap_or_default()))
        .map(|s| int(&s.data, "id"))
        .collect::<Result<_, _>>()?;
    let mut grouped: HashMap<i64, Vec<Episode>> = HashMap::new();
    for batch in ids.chunks(900) {
        let sql = format!(
            "SELECT * FROM episodes WHERE subject_id IN ({}) AND type=0 ORDER BY subject_id,sort",
            vec!["?"; batch.len()].join(",")
        );
        for e in query_episodes(db, &sql, rusqlite::params_from_iter(batch))? {
            grouped
                .entry(int(&e.data, "subjectID")?)
                .or_default()
                .push(e);
        }
    }
    Ok(subjects
        .into_iter()
        .map(|s| {
            let eps = grouped
                .get(&s.data["id"].as_i64().unwrap_or_default())
                .map(|e| {
                    progress_window(e, size)
                        .iter()
                        .map(Episode::dto)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            json!({"subject":s.data,"episodes":eps})
        })
        .collect())
}
fn delete_except(db: &Connection, id: i64, keep: &HashSet<i64>) -> Result<(), StoreError> {
    let mut stmt = db.prepare("SELECT episode_id FROM episodes WHERE subject_id=?1")?;
    let removed = stmt
        .query_map([id], |r| r.get::<_, i64>(0))?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|id| !keep.contains(id))
        .collect::<Vec<_>>();
    for batch in removed.chunks(900) {
        let sql = format!(
            "DELETE FROM episodes WHERE subject_id=?1 AND episode_id IN ({})",
            (2..batch.len() + 2)
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(",")
        );
        db.execute(
            &sql,
            rusqlite::params_from_iter([id].into_iter().chain(batch.iter().copied())),
        )?;
    }
    Ok(())
}
fn dispatch(db: &Connection, method: &str, args: &Value) -> Result<Value, StoreError> {
    match method {
        "saveSubject"|"saveSlimSubject"=>{
            let item=&args["item"];let id=int(item,"id")?;let previous=get_subject(db,id)?;let created=previous.is_none();let mut s=previous.unwrap_or_else(||Subject::new(id));
            s.merge(item,method=="saveSlimSubject",args["authoritativeInterest"].as_bool().unwrap_or(false));save_subject(db,&s)?;Ok(json!(created))
        }
        "saveSubjects"=>{
            let items=array(args,"items")?;let mut order=Vec::new();let mut merged:HashMap<i64,Value>=HashMap::new();
            for item in items{let id=int(item,"id")?;if let Some(old)=merged.get_mut(&id){let images=old.get("images").cloned();let interest=old.get("interest").cloned();*old=item.clone();for(key,value)in[("images",images),("interest",interest)]{if old[key].is_null(){if let Some(v)=value{old[key]=v;}}}}else{order.push(id);merged.insert(id,item.clone());}}
            let existing=subjects_by_id(db,&order)?;
            for id in order{let mut s=existing.get(&id).cloned().unwrap_or_else(||Subject::new(id));s.merge(&merged[&id],false,args["authoritativeInterest"].as_bool().unwrap_or(false));save_subject(db,&s)?;}Ok(Value::Null)
        }
        "subject"=>Ok(get_subject(db,int(args,"subjectId")?)?.map(|s|s.data).unwrap_or(Value::Null)),
        "subjects"=>{let ids=array(args,"ids")?.iter().map(|v|v.as_i64().ok_or_else(||StoreError::InvalidRequest("ids must contain integers".into()))).collect::<Result<Vec<_>,_>>()?;Ok(json!(subjects_by_id(db,&ids)?.into_values().map(|s|s.data).collect::<Vec<_>>()))}
        "saveEpisodes"|"replaceEpisodes"=>{
            let id=int(args,"subjectId")?;let items=array(args,"items")?;
            if let Some(slim)=items.first().and_then(|i|i.get("subject")).filter(|v|v.is_object()){
                let sid=int(slim,"id")?;let mut s=get_subject(db,id)?.unwrap_or_else(||Subject::new(sid));s.merge(slim,true,false);save_subject(db,&s)?;
            }
            let episodes=query_episodes(db,"SELECT * FROM episodes WHERE subject_id=?1",[id])?;
            let old:HashMap<_,_>=episodes.into_iter().map(|e|(e.data["id"].as_i64().unwrap_or_default(),e)).collect();
            let authoritative=args["authoritativeCollection"].as_bool().unwrap_or(false);let mut keep=HashSet::new();
            for item in items{let eid=int(item,"id")?;let mut e=old.get(&eid).cloned().map(Ok).unwrap_or_else(||Episode::new(item))?;e.merge(item,authoritative);save_episode(db,&e)?;keep.insert(eid);}
            db.execute("UPDATE subjects SET episodes_synced_at=?2 WHERE subject_id=?1",params![id,now(args)?])?;
            if method=="replaceEpisodes"{delete_except(db,id,&keep)?;}Ok(Value::Null)
        }
        "deleteEpisodesNotIn"=>{
            let keep=array(args,"episodeIds")?.iter().map(|v|v.as_i64().ok_or_else(||StoreError::InvalidRequest("episodeIds must contain integers".into()))).collect::<Result<HashSet<_>,_>>()?;
            delete_except(db,int(args,"subjectId")?,&keep)?;Ok(Value::Null)
        }
        "episodes"=>{
            let mut sql="SELECT * FROM episodes WHERE subject_id=?1".to_owned();let mut keys:Vec<rusqlite::types::Value>=vec![int(args,"subjectId")?.into()];
            if let Some(main)=args["main"].as_bool(){sql.push_str(if main{" AND type=0"}else{" AND type!=0"});}
            if args["uncollectedOnly"].as_bool().unwrap_or(false){sql.push_str(" AND status=0");}
            sql.push_str(if args["sortDesc"].as_bool().unwrap_or(false){" ORDER BY sort DESC"}else{" ORDER BY sort ASC"});
            if let Some(limit)=args["limit"].as_i64(){sql.push_str(" LIMIT ?2");keys.push(limit.into());}
            Ok(json!(query_episodes(db,&sql,rusqlite::params_from_iter(keys))?.iter().map(Episode::dto).collect::<Vec<_>>()))
        }
        "episodeCounts"=>{
            let id=int(args,"subjectId")?;let main=db.query_row("SELECT COUNT(*) FROM episodes WHERE subject_id=?1 AND type=0",[id],|r|r.get::<_,i64>(0))?;
            let other=db.query_row("SELECT COUNT(*) FROM episodes WHERE subject_id=?1 AND type!=0",[id],|r|r.get::<_,i64>(0))?;Ok(json!({"main":main,"other":other}))
        }
        "updateEpisodeCollection"=>{
            let Some(mut e)=get_episode(db,int(args,"episodeId")?)?else{return Ok(Value::Null);};let sid=int(&e.data,"subjectID")?;
            let Some(mut s)=get_subject(db,sid)?else{return Ok(Value::Null);};let time=now(args)?-1;let typ=int(args,"type")?;let batch=args["batch"].as_bool().unwrap_or(false);
            if batch{db.execute("UPDATE episodes SET status=2,collected_at=?2 WHERE subject_id=?1 AND sort<=?3 AND type=0",params![sid,time,e.data["sort"].as_f64().unwrap_or_default()])?;}
            else{e.status=typ;e.collected=time;save_episode(db,&e)?;}
            if batch||e.data["type"]==0{
                let counted=db.query_row("SELECT COUNT(*) FROM episodes WHERE subject_id=?1 AND type=0 AND status=2",[sid],|r|r.get::<_,i64>(0))?;
                let previous=s.data["interest"]["epStatus"].as_i64().unwrap_or_default();
                if (batch||typ==2) && counted<previous{}else if s.data["interest"].is_object(){s.data["interest"]["epStatus"]=json!(counted);}
            }
            if s.data["interest"].is_object(){s.data["interest"]["updatedAt"]=json!(time);}s.collected=time;save_subject(db,&s)?;Ok(json!(sid))
        }
        "updateSubjectCollectionType"|"updateSubjectRating"=>{
            let Some(mut s)=get_subject(db,int(args,"subjectId")?)?else{return Ok(Value::Null);};let rating=method=="updateSubjectRating";let time=now(args)?-if rating{0}else{1};
            if !s.data["interest"].is_object(){s.data["interest"]=interest();if rating{s.ctype=2;}}
            if rating{s.data["interest"]["rate"]=json!(int(args,"rate")?);}else{let typ=int(args,"type")?;s.data["interest"]["type"]=json!(typ);s.ctype=typ;}
            s.data["interest"]["updatedAt"]=json!(time);s.collected=time;save_subject(db,&s)?;Ok(Value::Null)
        }
        "collectionSubjects"=>{
            Ok(json!(query_subjects(db,"SELECT * FROM subjects WHERE type=?1 AND ctype=?2 ORDER BY collected_at DESC LIMIT ?3 OFFSET ?4",params![int(args,"subjectType")?,int(args,"collectionType")?,int(args,"limit")?,int(args,"offset")?])?.into_iter().map(|s|s.data).collect::<Vec<_>>()))
        }
        "collectionCounts"=>{
            let mut stmt=db.prepare("SELECT ctype,COUNT(*) FROM subjects WHERE type=?1 GROUP BY ctype")?;let mut counts=serde_json::Map::new();
            for row in stmt.query_map([int(args,"subjectType")?],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?)))?{let(t,n)=row?;if(0..=5).contains(&t){counts.insert(t.to_string(),json!(n));}}Ok(Value::Object(counts))
        }
        "progressCounts"=>{
            let mut counts=serde_json::Map::new();for t in [0,1,2,6]{let n=db.query_row("SELECT COUNT(*) FROM subjects WHERE ctype=3 AND (?1=0 OR type=?1)",[t],|r|r.get::<_,i64>(0))?;counts.insert(t.to_string(),json!(n));}Ok(Value::Object(counts))
        }
        "progressSubject"=>{let subjects=get_subject(db,int(args,"subjectId")?)?.into_iter().collect();Ok(make_progress(db,subjects,int(args,"episodeWindowSize")?)?.into_iter().next().unwrap_or(Value::Null))}
        "progressSubjects"=>{
            let typ=int(args,"progressTab")?;let search=args["search"].as_str().unwrap_or("");let mut sql="SELECT * FROM subjects WHERE ctype=3 AND (?1=0 OR type=?1)".to_owned();let mut keys:Vec<rusqlite::types::Value>=vec![typ.into()];
            if !search.is_empty(){sql.push_str(" AND (name LIKE ?2 ESCAPE '\\' COLLATE NOCASE OR name_cn LIKE ?2 ESCAPE '\\' COLLATE NOCASE)");keys.push(format!("%{}%",search.replace('%',"\\%").replace('_',"\\_")).into());}
            sql.push_str(" ORDER BY collected_at DESC");let mut subjects=query_subjects(db,&sql,rusqlite::params_from_iter(keys))?;let total=subjects.len();
            if args["sortMode"]=="airTime"{subjects.sort_by(|a,b|{let a=a.data["airtime"]["date"].as_str().unwrap_or("");let b=b.data["airtime"]["date"].as_str().unwrap_or("");match(a.is_empty(),b.is_empty()){(true,false)=>std::cmp::Ordering::Greater,(false,true)=>std::cmp::Ordering::Less,_=>b.cmp(a)}});}
            let offset=int(args,"offset")?.max(0) as usize;let limit=int(args,"limit")?.max(0) as usize;
            let page=subjects.into_iter().skip(offset).take(limit).collect();Ok(json!({"data":make_progress(db,page,int(args,"episodeWindowSize")?)?,"total":total}))
        }
        "syncTargets" => {
            let missing = dispatch(db, "missingEpisodes", args)?;
            let stale = dispatch(db, "staleEpisodeProgress", args)?;
            let mut seen = HashSet::new();
            let mut targets = Vec::new();
            for id in missing.as_array().into_iter().flatten().chain(stale.as_array().into_iter().flatten()) {
                if let Some(id) = id.as_i64() { if seen.insert(id) { targets.push(id); } }
            }
            Ok(json!(targets))
        }
        "missingEpisodes"=>{
            let cutoff=int(args,"staleBefore")?;let mut stmt=db.prepare("SELECT s.subject_id FROM subjects s WHERE s.ctype=3 AND s.type IN (2,6) AND (SELECT COUNT(*) FROM episodes e WHERE e.subject_id=s.subject_id AND e.type=0)<MAX(COALESCE(s.eps,0),1) AND (s.episodes_synced_at=0 OR s.episodes_synced_at<=?1) ORDER BY s.collected_at DESC LIMIT ?2")?;
            let rows=stmt.query_map(params![cutoff,int(args,"limit")?],|r|r.get::<_,i64>(0))?.collect::<Result<Vec<_>,_>>()?; Ok(json!(rows))
        }
        "staleEpisodeProgress"=>{
            let cutoff=int(args,"cooldownBefore")?;let sql="SELECT s.* FROM subjects s WHERE s.ctype=3 AND s.type IN (2,6) AND EXISTS (SELECT 1 FROM episodes e WHERE e.subject_id=s.subject_id AND e.type=0) ORDER BY s.collected_at DESC LIMIT ?1";
            let subjects=query_subjects(db,sql,[int(args,"limit")?])?;let mut ids=Vec::new();for s in subjects{let id=int(&s.data,"id")?;if s.collected>s.synced{ids.push(id);continue;}let watched=db.query_row("SELECT COUNT(*) FROM episodes WHERE subject_id=?1 AND type=0 AND status=2",[id],|r|r.get::<_,i64>(0))?;if watched!=s.data["interest"]["epStatus"].as_i64().unwrap_or_default() && s.synced<=cutoff{ids.push(id);}}Ok(json!(ids))
        }
        "subjectID"=>Ok(json!(db.query_row("SELECT subject_id FROM episodes WHERE episode_id=?1",[int(args,"episodeId")?],|r|r.get::<_,i64>(0)).optional()?)),
        "clearAccountLocalState"=>{db.execute("DELETE FROM subjects",[])?;db.execute("DELETE FROM episodes",[])?;Ok(Value::Null)}
        _=>Err(StoreError::InvalidRequest(format!("unknown Bangumi store command: {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn subject(id: i64, watched: i64) -> Value {
        json!({"id":id,"name":"Subject","type":2,"eps":1905,"interest":{"comment":"","epStatus":watched,"volStatus":0,"private":false,"rate":0,"tags":[],"type":3,"updatedAt":1}})
    }
    fn episode(id: i64, owner: i64, sort: f64) -> Value {
        json!({"id":id,"subjectID":owner,"type":0,"sort":sort,"name":"Episode","nameCN":"","duration":"","airdate":"","comment":0,"disc":0})
    }
    #[test]
    fn sync_targets_use_complete_snapshot_and_deduplicate_overlapping_candidates() {
        let store = BangumiStore::open(":memory:").unwrap();
        let mut one = subject(1, 0);
        one["interest"]["updatedAt"] = json!(4);
        let mut two = subject(2, 5);
        two["interest"]["updatedAt"] = json!(5);
        store
            .call("saveSubjects", &json!({"items":[one,two]}))
            .unwrap();
        store
            .call(
                "saveEpisodes",
                &json!({"subjectId":2,"items":[episode(1,2,1.0)],"now":10}),
            )
            .unwrap();
        let targets = store
            .call(
                "syncTargets",
                &json!({"limit":200,"staleBefore":20,"cooldownBefore":20}),
            )
            .unwrap();
        assert_eq!(targets, json!([2, 1]));
    }

    #[test]
    fn pruning_more_than_one_parameter_batch_preserves_all_retained_ids() {
        let store = BangumiStore::open(":memory:").unwrap();
        store
            .call("saveSubject", &json!({"item":subject(1,0)}))
            .unwrap();
        let episodes: Vec<_> = (1..=1905).map(|id| episode(id, 1, id as f64)).collect();
        store
            .call(
                "saveEpisodes",
                &json!({"subjectId":1,"items":episodes,"now":10}),
            )
            .unwrap();
        store
            .call(
                "saveEpisodes",
                &json!({"subjectId":2,"items":[episode(2000,2,1.0)],"now":10}),
            )
            .unwrap();
        let ids: Vec<_> = (1..=1701).collect();
        store
            .call(
                "deleteEpisodesNotIn",
                &json!({"subjectId":1,"episodeIds":ids}),
            )
            .unwrap();
        let read = store.call("episodes", &json!({"subjectId":1})).unwrap();
        assert_eq!(read.as_array().unwrap().len(), 1701);
        assert_eq!(read[1700]["id"], 1701);
        assert_eq!(
            store.call("episodes", &json!({"subjectId":2})).unwrap()[0]["id"],
            2000
        );
    }
    #[test]
    fn failed_full_episode_replacement_rolls_back_metadata_progress_and_sync_time() {
        let store = BangumiStore::open(":memory:").unwrap();
        store
            .call("saveSubject", &json!({"item":subject(1,5)}))
            .unwrap();
        store
            .call(
                "saveEpisodes",
                &json!({"subjectId":1,"items":[episode(1,1,1.0)],"now":10}),
            )
            .unwrap();
        let err = store.call(
            "replaceEpisodes",
            &json!({"subjectId":1,"items":[episode(2,1,2.0),{"id":3}],"now":20}),
        );
        assert!(err.is_err());
        assert_eq!(
            store.call("episodes", &json!({"subjectId":1})).unwrap()[0]["id"],
            1
        );
        assert_eq!(
            get_subject(&store.connection, 1).unwrap().unwrap().synced,
            10
        );
    }
    #[test]
    fn fractional_batch_includes_selected_episode_and_local_derived_count_is_monotonic() {
        let store = BangumiStore::open(":memory:").unwrap();
        store
            .call("saveSubject", &json!({"item":subject(1,12)}))
            .unwrap();
        store
            .call(
                "saveEpisodes",
                &json!({"subjectId":1,"items":[episode(1,1,0.5),episode(2,1,0.7)],"now":10}),
            )
            .unwrap();
        store
            .call(
                "updateEpisodeCollection",
                &json!({"episodeId":2,"type":2,"batch":true,"now":20}),
            )
            .unwrap();
        let eps = store.call("episodes", &json!({"subjectId":1})).unwrap();
        assert!(eps
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e["collection"]["status"] == 2));
        assert_eq!(
            store.call("subject", &json!({"subjectId":1})).unwrap()["interest"]["epStatus"],
            12
        );
        store
            .call(
                "updateEpisodeCollection",
                &json!({"episodeId":2,"type":0,"now":30}),
            )
            .unwrap();
        assert_eq!(
            store.call("subject", &json!({"subjectId":1})).unwrap()["interest"]["epStatus"],
            1
        );
    }
}
