//! Complete resumable automatic/manual loading policy. Adapters execute effects;
//! Core owns ordering, budgets, ranking, cache decisions and intro precedence.
use crate::{
    cache::{EpisodeMatch, IntroHint},
    identity::{self, IDs, Identity},
    intro,
    policy::{self, TargetContext, TargetKind},
    Candidate,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, time::Instant};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct FlowError(pub String);
fn invalid(s: impl Into<String>) -> FlowError {
    FlowError(s.into())
}
fn decode<T: for<'d> Deserialize<'d>>(value: Value) -> Result<T, FlowError> {
    serde_json::from_value(value).map_err(|e| invalid(e.to_string()))
}
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Context {
    #[serde(default)]
    file_name: String,
    anime_title: Option<String>,
    original_title: Option<String>,
    episode_number: Option<i64>,
    season_number: Option<i64>,
    tmdb_id: Option<i64>,
    series_tmdb_id: Option<i64>,
    #[serde(rename = "malID")]
    mal_id: Option<i64>,
    #[serde(rename = "anilistID")]
    anilist_id: Option<i64>,
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    is_movie: bool,
    special: Option<policy::SpecialTarget>,
    file_size: Option<i64>,
    duration_seconds: Option<i64>,
    #[serde(default)]
    allows_cached_match_reuse: bool,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    mode: String,
    #[serde(default = "player_delivery")]
    delivery: String,
    #[serde(default)]
    context: Context,
    #[serde(default)]
    force_rematch: bool,
    #[serde(default = "default_budget")]
    budget_seconds: f64,
    #[serde(default)]
    has_aliases: bool,
    #[serde(default)]
    has_learning: bool,
    match_value: Option<EpisodeMatch>,
}
fn player_delivery() -> String {
    "player".to_owned()
}
fn default_budget() -> f64 {
    30.0
}
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Failure {
    kind: String,
    status: Option<i64>,
    message: Option<String>,
}
impl Failure {
    fn gateway_down(&self) -> bool {
        match self.kind.as_str() {
            "businessError" | "invalidRequest" | "decodingFailed" => false,
            "httpStatus" => self.status.is_none_or(|s| !(400..500).contains(&s)),
            "network" | "rateLimited" | "notConfigured" | "unauthorized" | "forbidden" => true,
            _ => false,
        }
    }
    fn message(&self) -> String {
        match self.kind.as_str() {
            "notConfigured" => "弹幕网关未配置",
            "unauthorized" => "网关 API Key 无效",
            "forbidden" => "网关拒绝了请求（API Key 无效或已被限制）",
            "rateLimited" => "弹幕请求额度已用完",
            "businessError" => return self.message.clone().unwrap_or("弹幕服务返回错误".into()),
            "decodingFailed" => "弹幕服务返回了无法解析的数据",
            "network" => "弹幕网络请求失败",
            "httpStatus" => "弹幕服务暂时不可用",
            "invalidRequest" => return self.message.clone().unwrap_or_default(),
            _ => "弹幕加载失败",
        }
        .into()
    }
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reply {
    #[serde(default)]
    value: Value,
    #[serde(default)]
    error: Option<Failure>,
    current: bool,
    #[serde(default)]
    cancelled: bool,
    now_seconds: Option<f64>,
}
#[derive(Deserialize)]
struct FlowCandidate {
    #[serde(flatten)]
    candidate: Candidate,
    #[serde(rename = "animeId")]
    anime_id: Option<i64>,
}
#[derive(Clone)]
struct Engine {
    config: Config,
    target: TargetContext,
    clean_title: Option<String>,
    match_value: Option<EpisodeMatch>,
    step: u64,
    effect: Value,
    outcome: Option<Value>,
    created: Instant,
    last_now: f64,
    budget_start: f64,
    clock_override: bool,
    tier: u8,
    query: usize,
    hash: Option<String>,
    fingerprint_failed: bool,
    gateway_down: bool,
    tier_error: Option<Failure>,
    budget_cut: bool,
    tiers_attempted: u8,
    detecting_intro: bool,
    has_payload: bool,
    comment_count: u64,
    detected: Option<IntroHint>,
    hint: Option<IntroHint>,
    candidates: Vec<String>,
    ids: IDs,
}
impl Engine {
    fn begin(mut config: Config) -> Result<Self, FlowError> {
        if !matches!(config.mode.as_str(), "automatic" | "manual")
            || !matches!(config.delivery.as_str(), "player" | "data")
            || !config.budget_seconds.is_finite()
        {
            return Err(invalid("invalid mode or budgetSeconds"));
        }
        if config.mode == "manual" && config.match_value.is_none() {
            return Err(invalid("manual matchValue required"));
        }
        if config.mode == "manual" {
            config.force_rematch = true;
        }
        let parsed = crate::parse_filename(&config.context.file_name);
        let title = config
            .context
            .anime_title
            .clone()
            .filter(|s| !s.is_empty())
            .or_else(|| (!parsed.title.is_empty()).then_some(parsed.title.clone()));
        let target = TargetContext {
            anime_title: title,
            episode_number: config.context.episode_number.or(parsed.episode_number),
            season_number: config.context.season_number.or(parsed.season_number),
            is_final: config.context.is_final || parsed.is_final,
            special: config.context.special.clone(),
            kind: if config.context.is_movie {
                TargetKind::Movie
            } else {
                TargetKind::Episode
            },
        };
        let matched = config.match_value.clone();
        let mut engine = Self {
            config,
            target,
            clean_title: (!parsed.title.is_empty()).then_some(parsed.title),
            match_value: matched,
            step: 0,
            effect: Value::Null,
            outcome: None,
            created: Instant::now(),
            last_now: 0.0,
            budget_start: 0.0,
            clock_override: false,
            tier: 0,
            query: 0,
            hash: None,
            fingerprint_failed: false,
            gateway_down: false,
            tier_error: None,
            budget_cut: false,
            tiers_attempted: 0,
            detecting_intro: true,
            has_payload: false,
            comment_count: 0,
            detected: None,
            hint: None,
            candidates: vec![],
            ids: IDs::default(),
        };
        if engine.config.mode == "manual" {
            engine.emit("remember", json!({"match":engine.match_value}));
        } else if engine.config.force_rematch {
            engine.emit("clearForce", json!({}));
        } else {
            engine.emit("claim", json!({}));
        }
        Ok(engine)
    }
    fn emit(&mut self, kind: &str, args: Value) {
        self.effect = json!({"kind":kind,"arguments":args});
    }
    fn finish(&mut self, outcome: Value) {
        self.outcome = Some(outcome);
        self.effect = Value::Null;
    }
    fn fail(&mut self, message: &str) {
        self.finish(json!({"kind":"failed","message":message}));
    }
    fn check_current(&mut self, current: bool) -> bool {
        if !current {
            self.fail("播放已切换");
            false
        } else {
            true
        }
    }
    fn budget_open(&mut self, now: f64) -> bool {
        let now = if self.clock_override {
            now
        } else {
            self.created.elapsed().as_secs_f64()
        };
        if self.config.budget_seconds > 0.0 && now - self.budget_start >= self.config.budget_seconds
        {
            self.budget_cut = true;
            false
        } else {
            true
        }
    }
    fn episode_queries(&self) -> Vec<Option<String>> {
        if self.target.special.is_some() {
            vec![None]
        } else if let Some(n) = self.target.episode_number {
            vec![Some(n.to_string()), None]
        } else {
            vec![None]
        }
    }
    fn next_tier(&mut self, now: f64) -> Result<(), FlowError> {
        loop {
            self.tier += 1;
            self.query = 0;
            if self.gateway_down || self.tier > 4 {
                return self.unmatched();
            }
            // Native checks the budget before each tier's optional-context gate.
            if !self.budget_open(now) {
                continue;
            }
            let eligible = match self.tier {
                1 => self.hash.is_some(),
                2 => self.config.context.tmdb_id.is_some(),
                3 => self
                    .target
                    .anime_title
                    .as_ref()
                    .is_some_and(|s| !s.is_empty()),
                4 => self.clean_title.is_some() && self.clean_title != self.target.anime_title,
                _ => false,
            };
            if !eligible {
                continue;
            }
            self.tiers_attempted += 1;
            return self.next_query(now);
        }
    }
    fn next_query(&mut self, now: f64) -> Result<(), FlowError> {
        if self.tier == 1 {
            if !self.budget_open(now) {
                return self.next_tier(now);
            }
            let c = &self.config.context;
            self.emit(
                "match",
                json!({"fileName":c.file_name,"fileHash":self.hash,"fileSize":c.file_size,
                "videoDuration":c.duration_seconds,"matchMode":"hashAndFileName"}),
            );
            return Ok(());
        }
        let queries = if self.tier == 2 {
            let mut queries = vec![(0, self.episode_queries()[0].clone())];
            if self.target.episode_number.is_some() && self.target.special.is_none() {
                queries.push((0, None));
            }
            queries.push((1, None));
            queries
        } else {
            self.episode_queries()
                .into_iter()
                .map(|ep| (0, ep))
                .collect()
        };
        let Some((kind, episode)) = queries.get(self.query) else {
            return self.next_tier(now);
        };
        let title = if self.tier == 3 {
            self.target.anime_title.clone()
        } else {
            self.clean_title.clone()
        };
        if self.tier != 2 && title.as_ref().is_none_or(|s| identity::trim(s).is_empty()) {
            return self.next_tier(now);
        }
        if !self.budget_open(now) {
            return self.next_tier(now);
        }
        self.emit("search",json!({"tmdbId":if self.tier==2 {self.config.context.tmdb_id}else{None},
            "tmdbIdType":kind,"anime":if self.tier==2 {None}else{title.map(|s|identity::trim(&s).to_owned())},"episode":episode}));
        Ok(())
    }
    fn unmatched(&mut self) -> Result<(), FlowError> {
        if self.config.force_rematch {
            self.emit("forget", json!({}));
        } else {
            self.finish_unmatched();
        }
        Ok(())
    }
    fn finish_unmatched(&mut self) {
        if self.fingerprint_failed {
            self.fail("无法读取媒体指纹，请手动选择弹幕");
        } else if self.budget_cut && self.tier_error.is_none() {
            self.fail("弹幕匹配超时，请重试");
        } else if let Some(error) = &self.tier_error {
            let message = if error.kind == "other" {
                "弹幕网络请求失败，请检查网络后重试".into()
            } else {
                error.message()
            };
            self.fail(&message);
        } else {
            self.finish(json!({"kind":"noMatch"}));
        }
    }
    fn match_value(&self) -> &EpisodeMatch {
        self.match_value.as_ref().expect("matched loading phase")
    }
    fn matched(&mut self, value: EpisodeMatch) {
        self.match_value = Some(value);
        self.emit("remember", json!({"match":self.match_value}));
    }
    fn name(&self) -> String {
        let m = self.match_value();
        let parts: Vec<_> = [m.anime_title.as_deref(), m.episode_title.as_deref()]
            .into_iter()
            .flatten()
            .map(identity::trim)
            .filter(|s| !s.is_empty())
            .collect();
        if parts.is_empty() {
            "弹弹play".into()
        } else {
            parts.join(" · ")
        }
    }
    fn anime_id(&self) -> Option<i64> {
        let m = self.match_value();
        m.anime_id
            .or_else(|| (m.episode_id >= 10_000).then_some(m.episode_id / 10_000))
    }
    fn complete(&mut self) {
        self.finish(json!({"kind":if self.has_payload {"loaded"}else{"empty"},"episodeID":self.match_value().episode_id,
            "commentCount":self.comment_count,"title":self.name(),"introHint":self.hint}));
    }
    fn after_delivery(&mut self) {
        if self.config.force_rematch {
            self.community();
        } else {
            self.emit("cachedIntro", json!({}));
        }
    }
    fn select_hint(&mut self, hint: IntroHint) {
        self.hint = Some(hint);
        self.emit("persistIntro", json!({"hint":self.hint}));
    }
    fn after_community(&mut self) {
        if !self.config.force_rematch && self.config.has_learning {
            if let Some(id) = self.anime_id() {
                self.emit("promoted", json!({"animeID":id}));
                return;
            }
        }
        self.siblings();
    }
    fn siblings(&mut self) {
        if let Some(id) = self.anime_id() {
            self.emit("siblings", json!({"animeID":id}));
        } else {
            self.use_detected();
        }
    }
    fn use_detected(&mut self) {
        if let Some(hint) = self.detected.clone() {
            self.select_hint(hint);
        } else {
            self.complete();
        }
    }
    fn community(&mut self) {
        let c = &self.config.context;
        if c.episode_number.is_none_or(|n| n < 1) {
            self.after_community();
            return;
        }
        let m = self.match_value();
        self.candidates = [
            m.anime_title.as_ref().or(c.anime_title.as_ref()),
            c.original_title.as_ref(),
        ]
        .into_iter()
        .flatten()
        .map(|s| identity::trim(s).to_owned())
        .filter(|s| !s.is_empty())
        .collect();
        if self.config.has_aliases && !self.candidates.is_empty() {
            self.emit("aliases", json!({"title":self.candidates[0]}));
        } else {
            self.resolve_ids();
        }
    }
    fn resolve_ids(&mut self) {
        let c = &self.config.context;
        let identity = Identity {
            mal_id: c.mal_id,
            anilist_id: c.anilist_id,
            title: self.candidates.first().cloned(),
            alternative_titles: self.candidates.iter().skip(1).cloned().collect(),
            season_number: c.season_number,
            year: None,
        };
        self.emit(
            "resolveIDs",
            json!({"identity":identity,"forceRefresh":self.config.force_rematch}),
        );
    }
    fn sources(&mut self) {
        let c = &self.config.context;
        let mut sources = Vec::new();
        for (provider, id) in [
            ("aniSkip", self.ids.mal_id),
            ("animeSkip", self.ids.anilist_id),
            ("theIntroDB", c.series_tmdb_id),
        ] {
            if let Some(id) = id {
                sources.push(
                    json!({"provider":provider,"id":id,"episodeNumber":c.episode_number,
                "seasonNumber":c.season_number,"durationSeconds":c.duration_seconds}),
                );
            }
        }
        self.emit("sources", json!({"sources":sources}));
    }
    fn advance(&mut self, reply: Reply) -> Result<(), FlowError> {
        let now = reply
            .now_seconds
            .unwrap_or_else(|| self.created.elapsed().as_secs_f64());
        if !now.is_finite() || now < self.last_now {
            return Err(invalid("nowSeconds must be finite and monotonic"));
        }
        self.last_now = now;
        self.clock_override = reply.now_seconds.is_some();
        if reply.cancelled {
            self.fail("已取消");
            return Ok(());
        }
        let kind = self.effect["kind"].as_str().unwrap().to_owned();
        if let Some(error) = reply.error {
            match kind.as_str() {
                "clearForce" => {}
                "fingerprint" => {
                    self.fingerprint_failed = true;
                    self.budget_start = now;
                    return self.next_tier(now);
                }
                "match" | "search" => {
                    if !self.check_current(reply.current) {
                        return Ok(());
                    }
                    self.gateway_down = error.gateway_down();
                    self.tier_error = Some(error);
                    return self.next_tier(now);
                }
                _ => {
                    if self.check_current(reply.current) {
                        self.fail(&error.message());
                    }
                    return Ok(());
                }
            }
        }
        let value = reply.value;
        match kind.as_str() {
            "clearForce" => self.emit("claim", json!({})),
            "claim" => {
                if !self.check_current(reply.current) {
                    return Ok(());
                }
                if !self.config.force_rematch && self.config.context.allows_cached_match_reuse {
                    self.emit("cachedMatch", json!({}));
                } else {
                    self.emit("fingerprint", json!({}));
                }
            }
            "cachedMatch" => {
                let matched: Option<EpisodeMatch> = decode(value)?;
                if let Some(m) = matched {
                    if self.check_current(reply.current) {
                        self.match_value = Some(m);
                        self.emit("detectIntro", json!({}));
                    }
                } else {
                    self.emit("fingerprint", json!({}));
                }
            }
            "fingerprint" => {
                self.hash = decode(value)?;
                self.fingerprint_failed = self.hash.is_none();
                self.budget_start = now;
                if self.check_current(reply.current) {
                    self.next_tier(now)?;
                }
            }
            "match" | "search" => {
                if !self.check_current(reply.current) {
                    return Ok(());
                }
                let candidates: Vec<FlowCandidate> =
                    decode(value.get("candidates").cloned().unwrap_or(json!([])))?;
                let chosen = if kind == "match" && value["isMatched"] == true {
                    (!candidates.is_empty()).then_some(0)
                } else {
                    policy::select(
                        &candidates
                            .iter()
                            .map(|v| v.candidate.clone())
                            .collect::<Vec<_>>(),
                        &self.target,
                    )
                    .map(|v| v.index)
                };
                if let Some(index) = chosen {
                    let c = &candidates[index].candidate;
                    self.matched(EpisodeMatch {
                        episode_id: c.episode_id,
                        shift_seconds: if kind == "match" {
                            c.shift.unwrap_or(0)
                        } else {
                            0
                        },
                        anime_id: candidates[index].anime_id,
                        anime_title: c.anime_title.clone(),
                        episode_title: c.episode_title.clone(),
                    });
                } else if kind == "match" {
                    self.next_tier(now)?;
                } else {
                    self.query += 1;
                    self.next_query(now)?;
                }
            }
            "forget" => {
                if self.check_current(reply.current) {
                    self.finish_unmatched();
                }
            }
            "remember" => {
                if self.check_current(reply.current) {
                    self.emit("detectIntro", json!({}));
                }
            }
            "detectIntro" => {
                let hint: Option<IntroHint> = decode(value)?;
                self.detecting_intro = self.config.force_rematch || hint.is_none();
                self.emit("cachedComments", json!({}));
            }
            "cachedComments" => self.emit(
                if value["hit"] == true {
                    "render"
                } else {
                    "comments"
                },
                json!({"detectingIntro":self.detecting_intro}),
            ),
            "comments" => self.emit("persistComments", json!({})),
            "persistComments" => {
                self.emit("render", json!({"detectingIntro":self.detecting_intro}))
            }
            "render" => {
                self.has_payload = value["hasEntries"] == true || value["hasJSON"] == true;
                self.comment_count = value["commentCount"]
                    .as_u64()
                    .ok_or_else(|| invalid("commentCount required"))?;
                self.detected = decode(
                    value
                        .get("detectedIntroHint")
                        .cloned()
                        .unwrap_or(Value::Null),
                )?;
                if self.check_current(reply.current) {
                    if self.config.delivery == "data" {
                        self.after_delivery();
                    } else {
                        self.emit("waitReady", json!({"timeoutSeconds":30}));
                    }
                }
            }
            "waitReady" => {
                if !self.check_current(reply.current) {
                    return Ok(());
                }
                if value != true {
                    self.fail("视频未就绪，弹幕未装载");
                } else {
                    self.emit("inject",json!({"replace":self.has_payload,"name":self.name(),"shiftSeconds":self.match_value().shift_seconds}));
                }
            }
            "inject" => {
                if !self.check_current(reply.current) {
                    return Ok(());
                }
                if value != true {
                    self.fail("视频未就绪，弹幕未装载");
                } else {
                    self.after_delivery();
                }
            }
            "cachedIntro" => {
                let hint: Option<IntroHint> = decode(value)?;
                if let Some(hint) = hint {
                    self.hint = Some(hint);
                    self.complete();
                } else {
                    self.community();
                }
            }
            "aliases" => {
                let aliases: Vec<String> = decode(value)?;
                self.candidates.extend(aliases);
                self.resolve_ids();
            }
            "resolveIDs" => {
                self.ids = decode(value)?;
                self.sources();
            }
            "sources" => {
                let intervals: Vec<intro::Interval> = decode(value)?;
                if let Some(best) = intro::select_intervals(&intervals) {
                    self.select_hint(IntroHint {
                        start_seconds: best.start,
                        end_seconds: best.end,
                        evidence_count: best.votes as i64,
                        source: best.source,
                    });
                } else {
                    self.after_community();
                }
            }
            "promoted" => {
                let hint: Option<IntroHint> = decode(value)?;
                if let Some(hint) = hint {
                    self.select_hint(hint);
                } else {
                    self.siblings();
                }
            }
            "siblings" => {
                let hints: Vec<IntroHint> = decode(value)?;
                if let Some(hint) = intro::sibling_hint(&hints) {
                    self.select_hint(hint);
                } else {
                    self.use_detected();
                }
            }
            "persistIntro" => {
                if self.check_current(reply.current) {
                    self.complete();
                }
            }
            _ => return Err(invalid("unknown pending effect")),
        }
        Ok(())
    }
    fn response(&self, id: &str) -> Value {
        json!({"flowID":id,"step":self.step,"effect":self.effect,"outcome":self.outcome,
        "match":self.match_value,"diagnostics":{"budgetDidCut":self.budget_cut,"tiersAttempted":self.tiers_attempted,"fingerprintFailed":self.fingerprint_failed}})
    }
}
#[derive(Default)]
pub struct Directory {
    flows: HashMap<String, Engine>,
    started: u64,
    finished: u64,
}
impl Directory {
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, FlowError> {
        if method == "stats" {
            return Ok(
                json!({"active":self.flows.len(),"capacity":64,"started":self.started,"finished":self.finished}),
            );
        }
        let id = args
            .get("flowID")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty() && v.len() <= 256)
            .ok_or_else(|| invalid("flowID required (1..256 bytes)"))?;
        if method == "close" {
            return Ok(json!({"closed":self.flows.remove(id).is_some()}));
        }
        let raw = args
            .get("payloadJSON")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("payloadJSON required"))?;
        let value: Value = serde_json::from_str(raw).map_err(|e| invalid(e.to_string()))?;
        let engine = match method {
            "begin" => {
                if self.flows.contains_key(id) {
                    return Err(invalid("flowID already active"));
                }
                if self.flows.len() >= 64 {
                    return Err(invalid("too many active flows"));
                }
                Engine::begin(decode(value)?)?
            }
            "advance" => {
                let mut engine = self
                    .flows
                    .get(id)
                    .cloned()
                    .ok_or_else(|| invalid("flowID not active"))?;
                let step = args
                    .get("step")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| invalid("step required"))?;
                if step != engine.step {
                    return Err(invalid("stale flow step"));
                }
                engine.advance(decode(value)?)?;
                engine.step += 1;
                engine
            }
            _ => return Err(invalid("unknown flow command")),
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
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> Value {
        json!({"mode":"automatic","context":{"fileName":"Clean - 01.mkv","animeTitle":"Local","episodeNumber":1,"tmdbId":42},"budgetSeconds":30})
    }
    fn begin(config: Value) -> (Directory, Value) {
        let mut directory = Directory::default();
        let response = directory
            .call(
                "begin",
                &json!({"flowID":"test","payloadJSON":config.to_string()}),
            )
            .unwrap();
        (directory, response)
    }
    fn advance(directory: &mut Directory, state: &mut Value, value: Value, now: f64) {
        *state = directory
            .call(
                "advance",
                &json!({"flowID":"test","step":state["step"],
            "payloadJSON":json!({"current":true,"value":value,"nowSeconds":now}).to_string()}),
            )
            .unwrap();
    }
    fn kind(state: &Value) -> &str {
        state["effect"]["kind"].as_str().unwrap()
    }
    #[test]
    fn data_delivery_reuses_cache_and_resolves_intro_without_player_effects() {
        let (mut d, mut s) = begin(
            json!({"mode":"automatic","delivery":"data","context":{"allowsCachedMatchReuse":true}}),
        );
        advance(&mut d, &mut s, Value::Null, 0.0);
        assert_eq!(kind(&s), "cachedMatch");
        advance(
            &mut d,
            &mut s,
            json!({"episodeID":50001,"shiftSeconds":1}),
            0.0,
        );
        advance(&mut d, &mut s, Value::Null, 0.0);
        advance(&mut d, &mut s, json!({"hit":true}), 0.0);
        assert_eq!(kind(&s), "render");
        advance(
            &mut d,
            &mut s,
            json!({"hasEntries":true,"commentCount":3}),
            0.0,
        );
        assert_eq!(kind(&s), "cachedIntro");
        advance(
            &mut d,
            &mut s,
            json!({"endSeconds":90,"evidenceCount":2,"source":"learned"}),
            0.0,
        );
        assert_eq!(s["outcome"]["kind"], "loaded");
        assert_eq!(s["outcome"]["introHint"]["source"], "learned");
        assert_eq!(d.call("stats", &json!({})).unwrap()["active"], 0);
    }
    #[test]
    fn manual_data_delivery_forces_detection_and_preserves_empty_outcome() {
        let (mut d, mut s) = begin(
            json!({"mode":"manual","delivery":"data","matchValue":{"episodeID":50001,"shiftSeconds":0}}),
        );
        advance(&mut d, &mut s, Value::Null, 0.0);
        advance(
            &mut d,
            &mut s,
            json!({"endSeconds":90,"evidenceCount":2,"source":"aniskip"}),
            0.0,
        );
        advance(&mut d, &mut s, json!({"hit":true}), 0.0);
        assert_eq!(s["effect"]["arguments"]["detectingIntro"], true);
        advance(
            &mut d,
            &mut s,
            json!({"hasEntries":false,"hasJSON":false,"commentCount":4,"detectedIntroHint":{"endSeconds":130,"evidenceCount":3}}),
            0.0,
        );
        assert_eq!(kind(&s), "siblings");
        advance(&mut d, &mut s, json!([]), 0.0);
        assert_eq!(kind(&s), "persistIntro");
        advance(&mut d, &mut s, Value::Null, 0.0);
        assert_eq!(s["outcome"]["kind"], "empty");
        assert_eq!(s["outcome"]["commentCount"], 4);
        assert_eq!(s["outcome"]["introHint"]["endSeconds"], 130.0);
    }
    #[test]
    fn waterfall_keeps_eight_requests_and_finishes_without_false_budget_cut() {
        let (mut d, mut s) = begin(config());
        assert_eq!(kind(&s), "claim");
        advance(&mut d, &mut s, Value::Null, 0.0);
        assert_eq!(kind(&s), "fingerprint");
        advance(&mut d, &mut s, json!("hash"), 1.0);
        let mut requests = vec![];
        while s["outcome"].is_null() {
            requests.push(s["effect"].clone());
            advance(&mut d, &mut s, json!({"candidates":[]}), 2.0);
        }
        assert_eq!(requests.len(), 8);
        assert_eq!(requests[0]["kind"], "match");
        assert_eq!(requests[1]["arguments"]["tmdbIdType"], 0);
        assert_eq!(requests[3]["arguments"]["tmdbIdType"], 1);
        assert_eq!(requests[4]["arguments"]["anime"], "Local");
        assert_eq!(requests[6]["arguments"]["anime"], "Clean");
        assert_eq!(s["outcome"]["kind"], "noMatch");
        assert_eq!(s["diagnostics"]["budgetDidCut"], false);
        assert_eq!(d.flows.len(), 0);
    }
    #[test]
    fn budget_starts_after_fingerprint_and_only_cuts_pending_work() {
        let mut c = config();
        c["budgetSeconds"] = json!(0.25);
        let (mut d, mut s) = begin(c);
        advance(&mut d, &mut s, Value::Null, 0.0);
        advance(&mut d, &mut s, json!("hash"), 100.0);
        assert_eq!(kind(&s), "match");
        advance(&mut d, &mut s, json!({"candidates":[]}), 100.12);
        assert_eq!(kind(&s), "search");
        advance(&mut d, &mut s, json!({"candidates":[]}), 100.25);
        assert_eq!(s["outcome"]["message"], "弹幕匹配超时，请重试");
        assert_eq!(s["diagnostics"]["budgetDidCut"], true);
    }
    #[test]
    fn step_and_invalid_reply_leave_continuation_intact() {
        let (mut d, s) = begin(config());
        for reply in [
            json!({"current":true,"nowSeconds":-1}),
            json!({"current":"bad"}),
        ] {
            assert!(d
                .call(
                    "advance",
                    &json!({"flowID":"test","step":0,"payloadJSON":reply.to_string()})
                )
                .is_err());
            assert_eq!(d.flows["test"].response("test"), s);
        }
        assert!(d
            .call(
                "advance",
                &json!({"flowID":"test","step":1,"payloadJSON":"{}"})
            )
            .is_err());
        assert!(d
            .call(
                "begin",
                &json!({"flowID":"test","payloadJSON":config().to_string()})
            )
            .is_err());
        assert_eq!(
            d.call("close", &json!({"flowID":"test"})).unwrap()["closed"],
            true
        );
    }
    #[test]
    fn cancellation_and_stale_revision_stop_before_next_effect() {
        for reply in [
            json!({"current":true,"cancelled":true}),
            json!({"current":false}),
        ] {
            let (mut d, s) = begin(config());
            let end = d
                .call(
                    "advance",
                    &json!({"flowID":"test","step":s["step"],"payloadJSON":reply.to_string()}),
                )
                .unwrap();
            assert_eq!(end["outcome"]["kind"], "failed");
            assert!(end["effect"].is_null());
            assert!(d.flows.is_empty());
        }
    }
    #[test]
    fn gateway_error_policy_keeps_parameter_failures_eligible_for_fallback() {
        for (kind, status, down) in [
            ("httpStatus", Some(404), false),
            ("httpStatus", Some(503), true),
            ("decodingFailed", None, false),
            ("invalidRequest", None, false),
            ("businessError", None, false),
            ("network", None, true),
            ("unauthorized", None, true),
        ] {
            assert_eq!(
                Failure {
                    kind: kind.into(),
                    status,
                    message: None
                }
                .gateway_down(),
                down
            );
        }
    }
    #[test]
    fn manual_injects_before_sources_and_uses_native_anime_bit_segment() {
        let (mut d, mut s) = begin(
            json!({"mode":"manual","matchValue":{"episodeID":84190003,"shiftSeconds":7,"animeTitle":" Show "},
            "context":{"episodeNumber":3,"malID":42,"originalTitle":"Original"},"hasAliases":true,"hasLearning":true}),
        );
        for (expected, value) in [
            ("remember", Value::Null),
            ("detectIntro", Value::Null),
            ("cachedComments", json!({"hit":true})),
            ("render", json!({"hasEntries":true,"commentCount":10})),
            ("waitReady", json!(true)),
            ("inject", json!(true)),
        ] {
            assert_eq!(kind(&s), expected);
            advance(&mut d, &mut s, value, 0.0);
        }
        assert_eq!(kind(&s), "aliases");
        assert_eq!(s["effect"]["arguments"]["title"], "Show");
        advance(&mut d, &mut s, json!(["Alias"]), 0.0);
        assert_eq!(kind(&s), "resolveIDs");
        advance(&mut d, &mut s, json!({"malID":42,"anilistID":43}), 0.0);
        assert_eq!(kind(&s), "sources");
        advance(&mut d, &mut s, json!([]), 0.0);
        assert_eq!(kind(&s), "siblings");
        assert_eq!(s["effect"]["arguments"]["animeID"], 8419);
    }
}
