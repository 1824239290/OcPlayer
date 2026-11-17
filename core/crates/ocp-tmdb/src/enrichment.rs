//! Complete enrichment continuations, cache freshness, single-flight ownership
//! and bounded batch scheduling. Hosts execute the yielded effects.
use crate::matcher::{self, Item};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub const AIRING_REFRESH_SECONDS: f64 = 86400.0;
pub const AIRING_GRACE_SECONDS: f64 = 7.0 * 86400.0;
pub const BATCH_WIDTH: usize = 4;
pub const MEMBER_LIMIT: usize = 3;

fn decode<T: for<'d> Deserialize<'d>>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|e| e.to_string())
}
fn key(raw: &str) -> Result<String, String> {
    let p: Vec<_> = raw.split('/').filter(|s| !s.is_empty()).collect();
    let id = |s: &str| {
        s.parse::<i64>()
            .map_err(|_| "invalid entity key".to_owned())
    };
    match p.as_slice() {
        [kind, n] if ["movie", "tv", "collection"].contains(kind) => {
            Ok(format!("{kind}/{}", id(n)?))
        }
        ["tv", n, "season", s] => Ok(format!("tv/{}/season/{}", id(n)?, id(s)?)),
        _ => Err("invalid entity key".into()),
    }
}
fn tv_id(raw: &str) -> Option<i64> {
    let raw = key(raw).ok()?;
    let p: Vec<_> = raw.split('/').collect();
    (p.len() == 2 && p[0] == "tv")
        .then(|| p[1].parse().ok())
        .flatten()
}
fn validate_item(item: &Item) -> Result<(), String> {
    matcher::invoke(&json!({"operation":"providerID","item":{
        "name":item.name,"kind":item.kind,"tmdbID":item.tmdb_id
    }}))
    .map(|_| ())
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Link {
    entity_key: String,
    source: String,
    confidence: f64,
}
impl Link {
    fn validate(&mut self) -> Result<(), String> {
        self.entity_key = key(&self.entity_key)?;
        if !["providerID", "search", "manual"].contains(&self.source.as_str())
            || !self.confidence.is_finite()
        {
            return Err("invalid link".into());
        }
        Ok(())
    }
}
#[derive(Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct Cache {
    present: bool,
    fetched_at: f64,
    expires_at: f64,
    air_dates: Option<Vec<Option<f64>>>,
    now: f64,
    start_of_today: f64,
}
impl Cache {
    fn validate(&self) -> Result<(), String> {
        if [
            self.fetched_at,
            self.expires_at,
            self.now,
            self.start_of_today,
        ]
        .iter()
        .any(|n| !n.is_finite())
            || self
                .air_dates
                .iter()
                .flatten()
                .flatten()
                .any(|n| !n.is_finite())
        {
            return Err("invalid cache clock".into());
        }
        Ok(())
    }
    fn airing(&self) -> bool {
        let Some(dates) = &self.air_dates else {
            return false;
        };
        dates.is_empty()
            || dates
                .iter()
                .any(|d| d.is_none_or(|d| d >= self.start_of_today))
            || dates
                .iter()
                .flatten()
                .copied()
                .reduce(f64::max)
                .is_some_and(|last| self.now - last < AIRING_GRACE_SECONDS)
    }
    fn fresh(&self) -> bool {
        self.present
            && if self.airing() {
                self.now - self.fetched_at < AIRING_REFRESH_SECONDS
            } else {
                self.now < self.expires_at
            }
    }
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    mode: String,
    configured: bool,
    item: Option<Item>,
    series_link: Option<Link>,
    entity_key: Option<String>,
    season_number: Option<i64>,
    #[serde(default)]
    members: Vec<Item>,
    #[serde(default)]
    cancelled: bool,
}
#[derive(Clone)]
struct Engine {
    config: Config,
    step: u64,
    phase: String,
    effect: Value,
    outcome: Option<Value>,
    link: Option<Link>,
    selected_key: Option<String>,
    had_payload: bool,
    members: Vec<i64>,
    index: usize,
    saw_response: bool,
    seasons: Vec<i64>,
    fetched: i64,
}
impl Engine {
    fn begin(mut config: Config) -> Result<Self, String> {
        if ![
            "refresh",
            "collection",
            "season",
            "bind",
            "seasons",
            "contribution",
        ]
        .contains(&config.mode.as_str())
        {
            return Err("invalid enrichment mode".into());
        }
        if let Some(item) = &config.item {
            validate_item(item)?;
        }
        if ["refresh", "collection", "seasons", "contribution"].contains(&config.mode.as_str())
            && config.item.is_none()
        {
            return Err("item required".into());
        }
        for item in &config.members {
            validate_item(item)?;
        }
        if let Some(link) = &mut config.series_link {
            link.validate()?;
        }
        if let Some(raw) = &config.entity_key {
            config.entity_key = Some(key(raw)?);
        }
        if config.mode == "bind" && config.entity_key.is_none() {
            return Err("entityKey required".into());
        }
        if config.mode == "season" && config.season_number.is_none() {
            return Err("seasonNumber required".into());
        }
        let mut e = Self {
            config,
            step: 0,
            phase: String::new(),
            effect: Value::Null,
            outcome: None,
            link: None,
            selected_key: None,
            had_payload: false,
            members: vec![],
            index: 0,
            saw_response: false,
            seasons: vec![],
            fetched: 0,
        };
        match e.config.mode.as_str() {
            "contribution" => {
                if e.config.cancelled {
                    e.done("notEntered");
                } else if !["movie", "series"]
                    .contains(&e.config.item.as_ref().unwrap().kind.as_str())
                {
                    e.done("unsupported");
                } else {
                    e.emit("contributionRefresh", "refresh", json!({}));
                }
            }
            "bind" => {
                e.selected_key = e.config.entity_key.clone();
                e.emit(
                    "bindSave",
                    "saveLink",
                    json!({"entityKey":e.selected_key,"source":"manual","confidence":1.0}),
                );
            }
            "seasons" => e.emit("seasonsLink", "link", json!({})),
            _ if !e.config.configured => e.done("noMatch"),
            "refresh" => e.emit("freshLink", "link", json!({})),
            "collection" => e.emit("collectionLink", "link", json!({})),
            "season" => {
                if let Some(id) = e
                    .config
                    .series_link
                    .as_ref()
                    .and_then(|l| tv_id(&l.entity_key))
                {
                    e.selected_key = Some(format!(
                        "tv/{id}/season/{}",
                        e.config.season_number.unwrap()
                    ));
                    e.cache("seasonCache");
                } else {
                    e.done("noMatch");
                }
            }
            _ => unreachable!(),
        }
        Ok(e)
    }
    fn emit(&mut self, phase: &str, kind: &str, args: Value) {
        self.phase = phase.into();
        self.effect = json!({"kind":kind,"arguments":args});
    }
    fn done(&mut self, kind: &str) {
        self.effect = Value::Null;
        self.outcome = Some(json!({"kind":kind,"didFetch":kind=="fetched","seasons":self.fetched}));
    }
    fn cache(&mut self, phase: &str) {
        self.emit(phase, "cache", json!({"entityKey":self.selected_key}));
    }
    fn fetch(&mut self, phase: &str) {
        self.emit(phase, "fetch", json!({"entityKey":self.selected_key}));
    }
    fn select_link(&mut self, mut link: Option<Link>) -> Result<(), String> {
        if let Some(l) = &mut link {
            l.validate()?;
        }
        let item = self.config.item.as_ref().unwrap();
        let authoritative = ["movie", "series"].contains(&item.kind.as_str())
            && matcher::provider_id(item.tmdb_id.as_deref()).is_some();
        if link
            .as_ref()
            .is_none_or(|l| l.source == "search" && authoritative)
        {
            self.emit("matched", "match", json!({}));
        } else {
            self.selected_key = link.as_ref().map(|l| l.entity_key.clone());
            self.emit(
                "hadPayload",
                "hasPayload",
                json!({"entityKey":self.selected_key}),
            );
        }
        Ok(())
    }
    fn collection_members(&mut self) {
        self.members = self
            .config
            .members
            .iter()
            .filter(|i| i.kind == "movie")
            .filter_map(|i| matcher::provider_id(i.tmdb_id.as_deref()))
            .take(MEMBER_LIMIT)
            .collect();
        self.next_member();
    }
    fn next_member(&mut self) {
        if let Some(id) = self.members.get(self.index).copied() {
            self.emit("member", "member", json!({"id":id}));
        } else {
            self.done(if self.saw_response || self.members.is_empty() {
                "noMatch"
            } else {
                "failed"
            });
        }
    }
    fn next_season(&mut self, cancelled: bool) {
        if cancelled || self.index >= self.seasons.len() {
            self.done("finished");
            return;
        }
        let id = self
            .link
            .as_ref()
            .and_then(|l| tv_id(&l.entity_key))
            .unwrap();
        self.selected_key = Some(format!("tv/{id}/season/{}", self.seasons[self.index]));
        self.cache("seriesSeasonCache");
    }
    fn advance(&mut self, value: Value, cancelled: bool) -> Result<(), String> {
        match self.phase.as_str() {
            "freshLink" => {
                let mut link: Option<Link> = decode(value)?;
                if let Some(l) = &mut link {
                    l.validate()?;
                }
                self.link = link;
                if self.link.is_some() {
                    self.selected_key = self.link.as_ref().map(|l| l.entity_key.clone());
                    self.cache("freshCache");
                } else {
                    self.emit("selectLink", "link", json!({}));
                }
            }
            "freshCache" => {
                let cache: Cache = decode(value)?;
                cache.validate()?;
                if cache.fresh() {
                    self.done("skipped");
                } else {
                    self.emit("selectLink", "link", json!({}));
                }
            }
            "selectLink" => self.select_link(decode(value)?)?,
            "matched" => {
                let mut link: Option<Link> = decode(value)?;
                if let Some(l) = &mut link {
                    l.validate()?;
                }
                if let Some(link) = link.filter(|l| l.confidence >= matcher::AUTO_APPLY_THRESHOLD) {
                    self.selected_key = Some(link.entity_key.clone());
                    self.emit("saveLink", "saveLink", json!(link));
                } else {
                    self.done("noMatch");
                }
            }
            "saveLink" => self.emit(
                "hadPayload",
                "hasPayload",
                json!({"entityKey":self.selected_key}),
            ),
            "hadPayload" => {
                self.had_payload = decode(value)?;
                self.fetch("refreshFetch");
            }
            "refreshFetch" => {
                let ok: bool = decode(value)?;
                self.done(if ok {
                    "fetched"
                } else if self.had_payload {
                    "skipped"
                } else {
                    "failed"
                });
            }
            "collectionLink" => {
                let mut link: Option<Link> = decode(value)?;
                if let Some(l) = &mut link {
                    l.validate()?;
                }
                self.link = link;
                if self
                    .link
                    .as_ref()
                    .is_some_and(|l| l.entity_key.starts_with("collection/"))
                {
                    self.selected_key = self.link.as_ref().map(|l| l.entity_key.clone());
                    self.cache("collectionCache");
                } else {
                    self.collection_after_cache();
                }
            }
            "collectionCache" => {
                let cache: Cache = decode(value)?;
                cache.validate()?;
                if cache.present && cache.now < cache.expires_at {
                    self.done("skipped");
                } else {
                    self.collection_after_cache();
                }
            }
            "member" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Member {
                    success: bool,
                    #[serde(rename = "collectionID")]
                    collection_id: Option<i64>,
                }
                let member: Member = decode(value)?;
                if member.success {
                    self.saw_response = true;
                    if let Some(id) = member.collection_id {
                        self.selected_key = Some(format!("collection/{id}"));
                        self.emit("collectionSave","saveLink",json!({"entityKey":self.selected_key,"source":"providerID","confidence":1.0}));
                        return Ok(());
                    }
                }
                self.index += 1;
                self.next_member();
            }
            "collectionSave" | "bindSave" => self.fetch("plainFetch"),
            "plainFetch" => {
                let ok: bool = decode(value)?;
                self.done(if ok { "fetched" } else { "failed" });
            }
            "seasonCache" => {
                let cache: Cache = decode(value)?;
                cache.validate()?;
                if cache.fresh() {
                    self.done("skipped");
                } else {
                    self.fetch("plainFetch");
                }
            }
            "seasonsLink" => {
                let mut link: Option<Link> = decode(value)?;
                if let Some(l) = &mut link {
                    l.validate()?;
                }
                self.link = link;
                if self
                    .link
                    .as_ref()
                    .and_then(|l| tv_id(&l.entity_key))
                    .is_some()
                {
                    self.selected_key = self.link.as_ref().map(|l| l.entity_key.clone());
                    self.emit(
                        "seasonsPayload",
                        "seriesPayload",
                        json!({"entityKey":self.selected_key}),
                    );
                } else {
                    self.done("finished");
                }
            }
            "seasonsPayload" => {
                self.seasons = decode::<Option<Vec<i64>>>(value)?.unwrap_or_default();
                self.next_season(cancelled);
            }
            "seriesSeasonCache" => {
                let cache: Cache = decode(value)?;
                cache.validate()?;
                if cache.fresh() {
                    self.index += 1;
                    self.next_season(cancelled);
                } else {
                    self.fetch("seriesSeasonFetch");
                }
            }
            "seriesSeasonFetch" => {
                let ok: bool = decode(value)?;
                self.fetched += i64::from(ok);
                self.index += 1;
                self.next_season(cancelled);
            }
            "contributionRefresh" => {
                let result: String = decode(value)?;
                if !["skipped", "fetched", "noMatch", "failed"].contains(&result.as_str()) {
                    return Err("invalid refresh outcome".into());
                }
                self.phase = result.clone();
                if self.config.item.as_ref().unwrap().kind == "series"
                    && ["fetched", "skipped"].contains(&result.as_str())
                {
                    self.emit(
                        &format!("contributionSeasons:{result}"),
                        "seasons",
                        json!({}),
                    );
                } else {
                    self.done(&result);
                }
            }
            phase if phase.starts_with("contributionSeasons:") => {
                let kind = phase.trim_start_matches("contributionSeasons:").to_owned();
                self.fetched = decode(value)?;
                if self.fetched < 0 {
                    return Err("invalid season count".into());
                }
                self.done(&kind);
            }
            _ => return Err("invalid flow phase".into()),
        }
        Ok(())
    }
    fn collection_after_cache(&mut self) {
        if self.link.as_ref().is_some_and(|l| l.source == "manual") {
            self.selected_key = self.link.as_ref().map(|l| l.entity_key.clone());
            self.fetch("plainFetch");
        } else {
            self.collection_members();
        }
    }
    fn response(&self, id: &str) -> Value {
        json!({"flowID":id,"step":self.step,"effect":self.effect,"outcome":self.outcome})
    }
}

#[derive(Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct Failure {
    kind: String,
    message: Option<String>,
    status: Option<i64>,
    retry_after: Option<f64>,
}
impl Failure {
    fn validate(&self) -> Result<(), String> {
        if ![
            "notConfigured",
            "unauthorized",
            "rateLimited",
            "notFound",
            "http",
            "transport",
            "decoding",
        ]
        .contains(&self.kind.as_str())
            || self.kind == "http" && self.status.is_none()
            || ["transport", "decoding"].contains(&self.kind.as_str()) && self.message.is_none()
            || self.retry_after.is_some_and(|n| !n.is_finite())
        {
            Err("invalid fetch failure".into())
        } else {
            Ok(())
        }
    }
}
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    completed: usize,
    total: usize,
    skipped: usize,
    enriched: usize,
    unmatched: usize,
    failed: usize,
    seasons: u64,
    current_title: Option<String>,
}
#[derive(Clone)]
struct Batch {
    items: Vec<Item>,
    next: usize,
    active: HashSet<usize>,
    pending_refill: bool,
    cancelled: bool,
    progress: Progress,
}
impl Batch {
    fn response(&self, id: &str, dispatch: Vec<usize>, started: bool) -> Value {
        json!({"batchID":id,"dispatch":dispatch,"active":self.active.len(),"progress":self.progress,
            "wasCancelled":self.cancelled,"finished":self.active.is_empty() && !self.pending_refill,
            "started":started})
    }
}
#[derive(Default)]
pub struct Directory {
    flows: HashMap<String, Engine>,
    batches: HashMap<String, Batch>,
    fetches: HashMap<String, u64>,
    next_fetch: u64,
    last_failure: Option<Failure>,
    started: u64,
    finished: u64,
}
impl Directory {
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        match method {
            "stats" => {
                return Ok(
                    json!({"active":self.flows.len(),"batches":self.batches.len(),"fetches":self.fetches.len(),"started":self.started,"finished":self.finished,"capacity":256,"batchWidth":BATCH_WIDTH}),
                )
            }
            "failure" => return Ok(json!({"failure":self.last_failure})),
            "policy" => return policy(args),
            "fetch.claim" => {
                #[derive(Deserialize)]
                struct Claim {
                    key: String,
                    language: String,
                }
                let a: Claim = decode(args.clone())?;
                let k = format!("{}|{}", key(&a.key)?, a.language);
                if let Some(id) = self.fetches.get(&k) {
                    return Ok(json!({"owner":false,"ticket":id}));
                }
                if self.fetches.len() >= 256 {
                    return Err("too many active fetches".into());
                }
                self.next_fetch = self
                    .next_fetch
                    .checked_add(1)
                    .ok_or("fetch ticket exhausted")?;
                self.fetches.insert(k, self.next_fetch);
                return Ok(json!({"owner":true,"ticket":self.next_fetch}));
            }
            "fetch.finish" | "fetch.record" => {
                #[derive(Deserialize)]
                struct Finish {
                    ticket: u64,
                    error: Option<Failure>,
                }
                let a: Finish = decode(args.clone())?;
                if let Some(error) = &a.error {
                    error.validate()?;
                }
                let k = self
                    .fetches
                    .iter()
                    .find(|(_, id)| **id == a.ticket)
                    .map(|(k, _)| k.clone())
                    .ok_or("fetch ticket not active")?;
                if method == "fetch.record" {
                    self.last_failure = a.error;
                } else {
                    self.fetches.remove(&k);
                }
                return Ok(json!({"accepted":true}));
            }
            m if m.starts_with("batch.") => {
                return self.batch(m.trim_start_matches("batch."), args)
            }
            _ => {}
        }
        let id = args
            .get("flowID")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or("flowID required")?;
        if method == "close" {
            return Ok(json!({"closed":self.flows.remove(id).is_some()}));
        }
        let raw = args
            .get("payloadJSON")
            .and_then(Value::as_str)
            .ok_or("payloadJSON required")?;
        let value: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
        let engine = match method {
            "begin" => {
                if self.flows.contains_key(id) {
                    return Err("flowID already active".into());
                }
                if self.flows.len() >= 256 {
                    return Err("too many active flows".into());
                }
                Engine::begin(decode(value)?)?
            }
            "advance" => {
                #[derive(Deserialize)]
                struct Reply {
                    value: Value,
                    cancelled: bool,
                }
                let reply: Reply = decode(value)?;
                let mut e = self.flows.get(id).cloned().ok_or("flowID not active")?;
                if args.get("step").and_then(Value::as_u64) != Some(e.step) {
                    return Err("stale flow step".into());
                }
                e.advance(reply.value, reply.cancelled)?;
                e.step += 1;
                e
            }
            _ => return Err("unknown enrichment command".into()),
        };
        let response = engine.response(id);
        if method == "begin" {
            self.started = self.started.saturating_add(1);
        }
        if engine.outcome.is_some() {
            self.flows.remove(id);
            self.finished = self.finished.saturating_add(1);
        } else {
            self.flows.insert(id.into(), engine);
        }
        Ok(response)
    }
    fn batch(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        let id = args
            .get("batchID")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or("batchID required")?;
        if method == "close" {
            return Ok(json!({"closed":self.batches.remove(id).is_some()}));
        }
        if method == "begin" {
            #[derive(Deserialize)]
            struct Begin {
                items: Vec<Item>,
                configured: bool,
            }
            let a: Begin = decode(args.clone())?;
            for i in &a.items {
                validate_item(i)?;
            }
            if self.batches.contains_key(id) {
                return Err("batchID already active".into());
            }
            if self.batches.len() >= 64 {
                return Err("too many active batches".into());
            }
            let total = a.items.len();
            let width = if a.configured {
                BATCH_WIDTH.min(total)
            } else {
                0
            };
            let b = Batch {
                items: a.items,
                next: width,
                active: (0..width).collect(),
                pending_refill: false,
                cancelled: false,
                progress: Progress {
                    total,
                    ..Default::default()
                },
            };
            let response = b.response(id, (0..width).collect(), width > 0);
            if width > 0 {
                self.batches.insert(id.into(), b);
            }
            return Ok(response);
        }
        let mut b = self.batches.get(id).cloned().ok_or("batchID not active")?;
        let mut dispatch = vec![];
        match method {
            "complete" => {
                #[derive(Deserialize)]
                struct Complete {
                    index: usize,
                    outcome: String,
                    seasons: u64,
                }
                let a: Complete = decode(args.clone())?;
                if b.pending_refill || !b.active.remove(&a.index) {
                    return Err("worker not active or refill pending".into());
                }
                let item = &b.items[a.index];
                if a.outcome == "notEntered" {
                    if a.seasons != 0 {
                        return Err("cancelled contribution has seasons".into());
                    }
                    b.progress.current_title = None;
                } else if !["movie", "series"].contains(&item.kind.as_str()) {
                    if a.outcome != "unsupported" || a.seasons != 0 {
                        return Err("invalid unsupported contribution".into());
                    }
                    b.progress.completed += 1;
                    b.progress.current_title = None;
                } else {
                    match a.outcome.as_str() {
                        "skipped" => b.progress.skipped += 1,
                        "fetched" => b.progress.enriched += 1,
                        "noMatch" => b.progress.unmatched += 1,
                        "failed" => b.progress.failed += 1,
                        _ => return Err("invalid worker outcome".into()),
                    }
                    if a.seasons > 0
                        && (item.kind != "series"
                            || !["skipped", "fetched"].contains(&a.outcome.as_str()))
                    {
                        return Err("invalid season contribution".into());
                    }
                    b.progress.completed += 1;
                    b.progress.seasons = b
                        .progress
                        .seasons
                        .checked_add(a.seasons)
                        .ok_or("season total overflow")?;
                    b.progress.current_title = Some(item.name.clone());
                }
                b.pending_refill = true;
            }
            "refill" => {
                let cancelled = args
                    .get("cancelled")
                    .and_then(Value::as_bool)
                    .ok_or("cancelled must be boolean")?;
                if !b.pending_refill {
                    return Err("no completed worker to refill".into());
                }
                b.pending_refill = false;
                b.cancelled |= cancelled;
                if !b.cancelled && b.next < b.items.len() {
                    let n = b.next;
                    b.next += 1;
                    b.active.insert(n);
                    dispatch.push(n);
                }
            }
            _ => return Err("unknown batch command".into()),
        }
        let response = b.response(id, dispatch, true);
        if b.active.is_empty() && !b.pending_refill {
            self.batches.remove(id);
        } else {
            self.batches.insert(id.into(), b);
        }
        Ok(response)
    }
}
fn policy(args: &Value) -> Result<Value, String> {
    match args
        .get("operation")
        .and_then(Value::as_str)
        .ok_or("operation required")?
    {
        "fresh" | "airing" => {
            let c: Cache = decode(args.get("cache").cloned().ok_or("cache required")?)?;
            c.validate()?;
            Ok(json!({"value":if args["operation"]=="fresh"{c.fresh()}else{c.airing()}}))
        }
        "providerID" => {
            let item: Item = decode(args.get("item").cloned().ok_or("item required")?)?;
            validate_item(&item)?;
            Ok(json!({"id":matcher::provider_id(item.tmdb_id.as_deref())}))
        }
        "searchQuery" => {
            let s = args
                .get("query")
                .and_then(Value::as_str)
                .ok_or("query required")?;
            let s = matcher::trim(s);
            Ok(json!({"query":(!s.is_empty()).then_some(s)}))
        }
        _ => Err("unknown enrichment policy".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn item(kind: &str, id: Option<&str>) -> Value {
        json!({"name":"作品","kind":kind,"tmdbID":id})
    }
    fn config(mode: &str) -> Value {
        json!({"mode":mode,"configured":true,"item":item("movie",Some("603"))})
    }
    fn begin(d: &mut Directory, c: Value) -> Value {
        d.call(
            "begin",
            &json!({"flowID":"test","payloadJSON":c.to_string()}),
        )
        .unwrap()
    }
    fn advance(d: &mut Directory, s: &mut Value, v: Value, cancelled: bool) {
        *s=d.call("advance",&json!({"flowID":"test","step":s["step"],"payloadJSON":json!({"value":v,"cancelled":cancelled}).to_string()})).unwrap();
    }
    fn effect(s: &Value) -> &str {
        s["effect"]["kind"].as_str().unwrap()
    }
    fn cache(air: Option<Vec<Option<f64>>>, fetched: f64, expires: f64) -> Value {
        json!({"present":true,"airDates":air,"fetchedAt":fetched,"expiresAt":expires,"now":1000000.0,"startOfToday":950400.0})
    }
    fn link(key: &str, source: &str) -> Value {
        json!({"entityKey":key,"source":source,"confidence":1.0})
    }

    #[test]
    fn airing_refresh_window_is_independent_from_expiration_and_grace_is_strict() {
        for (air, fetched, expires, expected) in [
            (Some(vec![]), 900000.0, 9000000.0, false),
            (Some(vec![None]), 950000.0, 1.0, true),
            (Some(vec![Some(950400.0)]), 950000.0, 9000000.0, true),
            (
                Some(vec![Some(1000000.0 - AIRING_GRACE_SECONDS)]),
                900000.0,
                9000000.0,
                true,
            ),
            (
                Some(vec![Some(1000000.0 - AIRING_GRACE_SECONDS + 1.0)]),
                900000.0,
                9000000.0,
                false,
            ),
            (None, 950000.0, 1000000.0, false),
        ] {
            assert_eq!(
                policy(&json!({"operation":"fresh","cache":cache(air,fetched,expires)})).unwrap()
                    ["value"],
                expected
            );
        }
        assert!(!decode::<Cache>(cache(
            Some(vec![]),
            1000000.0 - AIRING_REFRESH_SECONDS,
            9999999.0
        ))
        .unwrap()
        .fresh());
    }
    #[test]
    fn refresh_uses_fresh_cache_before_authoritative_rematching() {
        let mut d = Directory::default();
        let mut s = begin(&mut d, config("refresh"));
        advance(&mut d, &mut s, link("movie/1", "search"), false);
        assert_eq!(effect(&s), "cache");
        advance(&mut d, &mut s, cache(None, 0.0, 9000000.0), false);
        assert_eq!(s["outcome"]["kind"], "skipped");
        assert!(d.flows.is_empty());
    }
    #[test]
    fn refresh_upgrades_search_links_but_preserves_manual_links_and_failure_cache() {
        for source in ["search", "manual", "providerID"] {
            let mut d = Directory::default();
            let mut s = begin(&mut d, config("refresh"));
            advance(&mut d, &mut s, link("movie/1", source), false);
            advance(&mut d, &mut s, cache(None, 0.0, 1.0), false);
            advance(&mut d, &mut s, link("movie/1", source), false);
            if source == "search" {
                assert_eq!(effect(&s), "match");
                advance(&mut d, &mut s, link("movie/603", "providerID"), false);
                assert_eq!(effect(&s), "saveLink");
                advance(&mut d, &mut s, Value::Null, false);
            }
            assert_eq!(effect(&s), "hasPayload");
            advance(&mut d, &mut s, json!(true), false);
            advance(&mut d, &mut s, json!(false), false);
            assert_eq!(s["outcome"]["kind"], "skipped");
        }
    }
    #[test]
    fn low_confidence_and_unconfigured_paths_never_yield_writes() {
        let mut d = Directory::default();
        let mut s = begin(&mut d, config("refresh"));
        advance(&mut d, &mut s, Value::Null, false);
        advance(&mut d, &mut s, Value::Null, false);
        advance(
            &mut d,
            &mut s,
            json!({"entityKey":"movie/1","source":"search","confidence":0.8}),
            false,
        );
        assert_eq!(s["outcome"]["kind"], "noMatch");
        let mut c = config("refresh");
        c["configured"] = json!(false);
        assert_eq!(begin(&mut d, c)["outcome"]["kind"], "noMatch");
        let mut c = config("bind");
        c["configured"] = json!(false);
        c["entityKey"] = json!("tv/-9223372036854775808/season/9223372036854775807");
        assert_eq!(
            effect(&begin(&mut d, c)),
            "saveLink",
            "manual binds persist without credentials"
        );
    }
    #[test]
    fn collections_keep_three_member_budget_order_and_response_failure_distinction() {
        for responses in [vec![false, false, false], vec![false, true, false]] {
            let mut d = Directory::default();
            let mut c = config("collection");
            c["members"] = json!([
                item("series", Some("1")),
                item("movie", Some("0")),
                item("movie", Some("+9223372036854775807")),
                item("movie", Some("2")),
                item("movie", Some("3")),
                item("movie", Some("4"))
            ]);
            let mut s = begin(&mut d, c);
            advance(&mut d, &mut s, Value::Null, false);
            for (n, success) in responses.iter().enumerate() {
                assert_eq!(effect(&s), "member");
                assert_eq!(
                    s["effect"]["arguments"]["id"],
                    if n == 0 {
                        json!(i64::MAX)
                    } else {
                        json!(n + 1)
                    }
                );
                advance(&mut d, &mut s, json!({"success":success}), false);
            }
            assert_eq!(
                s["outcome"]["kind"],
                if responses.contains(&true) {
                    "noMatch"
                } else {
                    "failed"
                }
            );
        }
        let mut d = Directory::default();
        let mut c = config("collection");
        c["members"] = json!([item("movie", Some("1"))]);
        let mut s = begin(&mut d, c);
        advance(&mut d, &mut s, Value::Null, false);
        advance(
            &mut d,
            &mut s,
            json!({"success":true,"collectionID":i64::MAX}),
            false,
        );
        assert_eq!(
            s["effect"]["arguments"]["entityKey"],
            format!("collection/{}", i64::MAX)
        );
        advance(&mut d, &mut s, Value::Null, false);
        advance(&mut d, &mut s, json!(true), false);
        assert_eq!(s["outcome"]["kind"], "fetched");
    }
    #[test]
    fn seasons_use_parent_tv_and_stop_between_fetches_after_cancellation() {
        let mut d = Directory::default();
        let mut c = config("season");
        c["seasonNumber"] = json!(0);
        c["seriesLink"] = link("movie/1", "manual");
        assert_eq!(begin(&mut d, c)["outcome"]["kind"], "noMatch");
        let mut s = begin(&mut d, config("seasons"));
        advance(&mut d, &mut s, link("tv/100", "providerID"), false);
        advance(&mut d, &mut s, json!([0, 1, 2]), false);
        assert_eq!(s["effect"]["arguments"]["entityKey"], "tv/100/season/0");
        advance(
            &mut d,
            &mut s,
            json!({"present":false,"fetchedAt":0,"expiresAt":0,"now":0,"startOfToday":0}),
            false,
        );
        advance(&mut d, &mut s, json!(true), true);
        assert_eq!(s["outcome"]["seasons"], 1);
        assert!(s["effect"].is_null());
    }
    #[test]
    fn single_flight_is_scoped_by_key_language_and_preserves_completion_order_failures() {
        let mut d = Directory::default();
        let a = d
            .call("fetch.claim", &json!({"key":"movie/1","language":"zh-CN"}))
            .unwrap();
        let b = d
            .call("fetch.claim", &json!({"key":"movie/1","language":"zh-CN"}))
            .unwrap();
        assert_eq!(a["ticket"], b["ticket"]);
        assert_eq!(b["owner"], false);
        let c = d
            .call("fetch.claim", &json!({"key":"movie/1","language":"en-US"}))
            .unwrap();
        assert_ne!(a["ticket"], c["ticket"]);
        d.call(
            "fetch.record",
            &json!({"ticket":a["ticket"],"error":{"kind":"rateLimited","retryAfter":2.5}}),
        )
        .unwrap();
        assert_eq!(
            d.call("failure", &json!({})).unwrap()["failure"]["retryAfter"],
            2.5
        );
        assert_eq!(
            d.call("fetch.claim", &json!({"key":"movie/1","language":"zh-CN"}))
                .unwrap()["ticket"],
            a["ticket"]
        );
        d.call("fetch.finish", &json!({"ticket":a["ticket"]}))
            .unwrap();
        assert!(d
            .call("fetch.finish", &json!({"ticket":a["ticket"]}))
            .is_err());
        d.call("fetch.record", &json!({"ticket":c["ticket"]}))
            .unwrap();
        d.call("fetch.finish", &json!({"ticket":c["ticket"]}))
            .unwrap();
        assert!(d.last_failure.is_none());
        assert!(d
            .call("fetch.claim", &json!({"key":"movie/1","language":"zh-CN"}))
            .unwrap()["owner"]
            .as_bool()
            .unwrap());
    }
    #[test]
    fn batches_refill_after_progress_and_cancel_without_abandoning_active_workers() {
        let mut d = Directory::default();
        let items = vec![item("movie", Some("1")); 10];
        let s = d
            .call(
                "batch.begin",
                &json!({"batchID":"b","configured":true,"items":items}),
            )
            .unwrap();
        assert_eq!(s["dispatch"], json!([0, 1, 2, 3]));
        d.call(
            "batch.complete",
            &json!({"batchID":"b","index":2,"outcome":"fetched","seasons":0}),
        )
        .unwrap();
        assert!(d
            .call(
                "batch.complete",
                &json!({"batchID":"b","index":1,"outcome":"fetched","seasons":0})
            )
            .is_err());
        assert_eq!(
            d.call("batch.refill", &json!({"batchID":"b","cancelled":true}))
                .unwrap()["dispatch"],
            json!([])
        );
        for index in [0, 1, 3] {
            d.call(
                "batch.complete",
                &json!({"batchID":"b","index":index,"outcome":"skipped","seasons":0}),
            )
            .unwrap();
            let s = d
                .call("batch.refill", &json!({"batchID":"b","cancelled":false}))
                .unwrap();
            assert_eq!(s["dispatch"], json!([]));
            assert_eq!(s["wasCancelled"], true);
            if index == 3 {
                assert_eq!(s["progress"]["completed"], 4);
                assert_eq!(s["finished"], true);
            }
        }
        assert!(d.batches.is_empty());
    }
    #[test]
    fn batches_classify_unsupported_pre_cancelled_and_series_season_counts() {
        let mut d = Directory::default();
        let items = json!([
            item("other", None),
            item("movie", None),
            item("series", None)
        ]);
        d.call(
            "batch.begin",
            &json!({"batchID":"b","configured":true,"items":items}),
        )
        .unwrap();
        for (index, outcome, seasons) in [
            (0, "unsupported", 0),
            (1, "notEntered", 0),
            (2, "skipped", 3),
        ] {
            d.call(
                "batch.complete",
                &json!({"batchID":"b","index":index,"outcome":outcome,"seasons":seasons}),
            )
            .unwrap();
            let s = d
                .call("batch.refill", &json!({"batchID":"b","cancelled":false}))
                .unwrap();
            if index == 2 {
                assert_eq!(s["progress"]["completed"], 2);
                assert_eq!(s["progress"]["skipped"], 1);
                assert_eq!(s["progress"]["seasons"], 3);
            }
        }
    }
    #[test]
    fn malformed_replies_duplicate_steps_and_batch_contributions_leave_state_intact() {
        let mut d = Directory::default();
        let s = begin(&mut d, config("refresh"));
        for (step, value) in [
            (1, Value::Null),
            (
                0,
                json!({"entityKey":"tv/not-number","source":"manual","confidence":1}),
            ),
        ] {
            assert!(d.call("advance",&json!({"flowID":"test","step":step,"payloadJSON":json!({"value":value,"cancelled":false}).to_string()})).is_err());
            assert_eq!(d.flows["test"].response("test"), s);
        }
        d.call(
            "batch.begin",
            &json!({"batchID":"b","configured":true,"items":[item("movie",None)]}),
        )
        .unwrap();
        for a in [
            json!({"index":1,"outcome":"failed","seasons":0}),
            json!({"index":0,"outcome":"fetched","seasons":1}),
        ] {
            let mut a = a;
            a["batchID"] = json!("b");
            assert!(d.call("batch.complete", &a).is_err());
            assert_eq!(d.batches["b"].active.len(), 1);
        }
    }
}
