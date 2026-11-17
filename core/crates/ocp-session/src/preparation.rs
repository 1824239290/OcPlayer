//! Retained leaf resolution and complete source negotiation. Native objects are
//! opaque keys; host calls supply metadata, URLs and the final presentation effect.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Item {
    pub key: String,
    pub id: String,
    pub kind: String,
    pub name: String,
    pub series_id: Option<String>,
    pub series_name: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    #[serde(default)]
    pub played: bool,
    pub position_seconds: Option<f64>,
}
impl Item {
    fn valid(&self) -> bool {
        !self.key.is_empty() && self.position_seconds.is_none_or(f64::is_finite)
    }
    fn title(&self) -> String {
        if self.kind == "episode" {
            if let Some(episode) = self.episode_number {
                let label = self
                    .season_number
                    .map(|s| format!("S{s}E{episode}"))
                    .unwrap_or_else(|| format!("E{episode}"));
                return format!(
                    "{} {label}",
                    self.series_name.as_ref().unwrap_or(&self.name)
                );
            }
        }
        self.name.clone()
    }
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub key: String,
    pub id: String,
    pub supports_direct_play: Option<bool>,
    pub supports_direct_stream: Option<bool>,
}
pub fn preferred_source(sources: &[Source]) -> Option<usize> {
    sources
        .iter()
        .position(|s| s.supports_direct_play == Some(true))
        .or_else(|| {
            sources
                .iter()
                .position(|s| s.supports_direct_stream == Some(true))
        })
        .or_else(|| (!sources.is_empty()).then_some(0))
}
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Resolve,
    Open,
    Next,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub item: Item,
    pub mode: Mode,
    pub resume_seconds: Option<f64>,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub token: u64,
    pub sequence: u64,
    pub effect: Option<&'static str>,
    pub arguments: Value,
    pub done: bool,
    pub result: Value,
}
#[derive(Debug, Clone, Copy)]
enum Stage {
    Home,
    Members,
    Episodes,
    Window,
    Resolved,
    Info,
    Primary,
    Alternate,
    FallbackNotice,
    Fallback,
    Ready,
}
#[derive(Clone)]
struct Flow {
    token: u64,
    sequence: u64,
    mode: Mode,
    original: Item,
    item: Item,
    input_resume: Option<f64>,
    stage: Stage,
    sources: Vec<Source>,
    preferred: Option<usize>,
    session_id: Option<String>,
    primary_uri: Option<String>,
    next_alternate: usize,
    active_alternate: Option<usize>,
    alternates: Vec<Value>,
    original_failure: Option<String>,
}
impl Flow {
    fn effect(
        &mut self,
        stage: Stage,
        effect: &'static str,
        arguments: Value,
    ) -> Result<Step, String> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("preparation sequence exhausted")?;
        self.stage = stage;
        Ok(Step {
            token: self.token,
            sequence: self.sequence,
            effect: Some(effect),
            arguments,
            done: false,
            result: Value::Null,
        })
    }
    fn done(&self, result: Value) -> Step {
        Step {
            token: self.token,
            sequence: self.sequence,
            effect: None,
            arguments: Value::Null,
            done: true,
            result,
        }
    }
    fn resolve(&mut self) -> Result<Step, String> {
        if matches!(self.mode, Mode::Next) {
            if self.item.kind != "episode"
                || self.item.series_id.is_none()
                || self.item.season_number == Some(0)
            {
                return Ok(self.empty());
            }
            return self.effect(
                Stage::Window,
                "episodeWindow",
                json!({
                    "itemKey":self.item.key,"seriesId":self.item.series_id,
                    "startItemId":self.item.id,"limit":6
                }),
            );
        }
        match self.item.kind.as_str() {
            "boxSet" => self.effect(
                Stage::Members,
                "collectionMembers",
                json!({"itemId":self.item.id,"itemKey":self.item.key,"recursive":false}),
            ),
            "series" => self.effect(
                Stage::Home,
                "home",
                json!({"itemId":self.item.id,"itemKey":self.item.key}),
            ),
            _ => self.resolved(),
        }
    }
    fn effective_resume(&self) -> Option<f64> {
        if self.item.id == self.original.id {
            self.input_resume
        } else {
            self.item.position_seconds
        }
    }
    fn resolved(&mut self) -> Result<Step, String> {
        if matches!(self.mode, Mode::Resolve | Mode::Next) {
            return self.effect(
                Stage::Ready,
                "ready",
                json!({"status":"resolved","itemKey":self.item.key}),
            );
        }
        self.effect(Stage::Resolved,"resolved",json!({"itemKey":self.item.key,"title":self.item.title(),"resumeSeconds":self.effective_resume()}))
    }
    fn empty(&self) -> Step {
        let error = match self.original.kind.as_str() {
            "boxSet" => "这个合集里还没有可播放的内容",
            "series" => "该剧没有可播放的剧集",
            _ => "这个条目没有可播放的内容",
        };
        self.done(json!({"status":"noContent","title":self.original.name,"error":error}))
    }
    fn url(&mut self, stage: Stage, role: &str, source: Option<usize>) -> Result<Step, String> {
        let candidate = source.map(|i| &self.sources[i]);
        self.effect(
            stage,
            "streamURL",
            json!({"role":role,"itemKey":self.item.key,"itemId":self.item.id,
            "sourceKey":candidate.map(|s|&s.key),"mediaSourceId":candidate.map(|s|&s.id),
            "playSessionId":if role=="fallback" {None} else {self.session_id.as_ref()}}),
        )
    }
    fn next_alternate(&mut self) -> Result<Step, String> {
        let selected_id = self.preferred.map(|i| self.sources[i].id.clone());
        while self.next_alternate < self.sources.len() {
            let index = self.next_alternate;
            self.next_alternate += 1;
            if selected_id.as_deref() == Some(self.sources[index].id.as_str()) {
                continue;
            }
            self.active_alternate = Some(index);
            return self.url(Stage::Alternate, "alternate", Some(index));
        }
        self.ready(false)
    }
    fn ready(&mut self, fallback: bool) -> Result<Step, String> {
        self.effect(Stage::Ready,"ready",json!({"status":"prepared","itemKey":self.item.key,"title":self.item.title(),
            "resumeSeconds":self.effective_resume(),"uri":self.primary_uri,"fallback":fallback,
            "sourceKey":if fallback {None} else {self.preferred.map(|i|&self.sources[i].key)},"alternates":self.alternates}))
    }
    fn resume(&mut self, response: Value) -> Result<Step, String> {
        match self.stage {
            Stage::Home => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase", deny_unknown_fields)]
                struct Home {
                    next_up: Vec<Item>,
                    resume: Vec<Item>,
                }
                let home: Home = serde_json::from_value(response).map_err(|e| e.to_string())?;
                validate_items(&home.next_up)?;
                validate_items(&home.resume)?;
                if let Some(item) = home
                    .next_up
                    .into_iter()
                    .chain(home.resume)
                    .find(|i| i.series_id.as_deref() == Some(self.item.id.as_str()))
                {
                    self.item = item;
                    return self.resolved();
                }
                self.effect(
                    Stage::Episodes,
                    "episodes",
                    json!({"seriesId":self.item.id,"seasonId":null}),
                )
            }
            Stage::Window => {
                let items: Vec<Item> =
                    serde_json::from_value(response).map_err(|e| e.to_string())?;
                validate_items(&items)?;
                if let Some(index) = items.iter().position(|item| item.id == self.item.id) {
                    if let Some(next) = items[index + 1..]
                        .iter()
                        .find(|item| item.season_number != Some(0))
                    {
                        self.item = next.clone();
                        return self.resolved();
                    }
                }
                Ok(self.empty())
            }
            Stage::Members | Stage::Episodes => {
                let items: Vec<Item> =
                    serde_json::from_value(response).map_err(|e| e.to_string())?;
                validate_items(&items)?;
                let candidates: Vec<_> = items
                    .iter()
                    .filter(|i| {
                        if matches!(self.stage, Stage::Members) {
                            matches!(i.kind.as_str(), "movie" | "episode")
                        } else {
                            i.season_number != Some(0)
                        }
                    })
                    .collect();
                if let Some(item) = candidates.iter().find(|i| !i.played).or(candidates.first()) {
                    self.item = (*item).clone();
                    return self.resolved();
                }
                if matches!(self.stage, Stage::Members) {
                    if let Some(item) = items.iter().find(|i| i.kind == "series") {
                        self.item = item.clone();
                        return self.resolve();
                    }
                }
                Ok(self.empty())
            }
            Stage::Resolved => {
                if response != json!(true) {
                    return Err("resolved acknowledgement must be true".into());
                }
                self.effect(
                    Stage::Info,
                    "playbackInfo",
                    json!({"itemKey":self.item.key,"itemId":self.item.id}),
                )
            }
            Stage::Info => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase", deny_unknown_fields)]
                struct Info {
                    play_session_id: Option<String>,
                    sources: Vec<Source>,
                }
                let info: Info = serde_json::from_value(response).map_err(|e| e.to_string())?;
                validate_sources(&info.sources)?;
                self.session_id = info.play_session_id;
                self.sources = info.sources;
                self.preferred = preferred_source(&self.sources);
                self.url(Stage::Primary, "primary", self.preferred)
            }
            Stage::Primary | Stage::Fallback | Stage::Alternate => {
                let uri = response
                    .as_str()
                    .ok_or("streamURL response must be a string")?
                    .to_owned();
                match self.stage {
                    Stage::Primary => {
                        self.primary_uri = Some(uri);
                        self.next_alternate()
                    }
                    Stage::Fallback => {
                        self.primary_uri = Some(uri);
                        self.ready(true)
                    }
                    Stage::Alternate => {
                        let source = &self.sources[self.active_alternate.unwrap()];
                        self.alternates
                            .push(json!({"key":source.key,"id":source.id,"uri":uri}));
                        self.next_alternate()
                    }
                    _ => unreachable!(),
                }
            }
            Stage::FallbackNotice => {
                if response != json!(true) {
                    return Err("fallback acknowledgement must be true".into());
                }
                self.url(Stage::Fallback, "fallback", None)
            }
            Stage::Ready => {
                if response != json!(true) {
                    return Err("ready acknowledgement must be true".into());
                }
                Ok(self.done(json!({"status":"completed"})))
            }
        }
    }
    fn fail(&mut self, message: String, cancelled: bool) -> Result<Step, String> {
        if cancelled {
            return Ok(self.done(json!({"status":"cancelled"})));
        }
        match self.stage {
            Stage::Info|Stage::Primary=>{
                self.original_failure=Some(message.clone());
                self.effect(Stage::FallbackNotice,"fallback",json!({"itemKey":self.item.key,"error":message}))
            }
            Stage::Alternate=>self.next_alternate(),
            Stage::Fallback=>Ok(self.done(json!({"status":"failed","phase":"playback","title":self.item.title(),
                "error":format!("播放信息获取失败：{}",self.original_failure.as_deref().unwrap_or(&message))}))),
            Stage::Home|Stage::Members|Stage::Episodes|Stage::Window=>Ok(self.done(json!({"status":"failed","phase":"resolve","title":self.original.name,"error":format!("剧集加载失败：{message}")}))),
            _=>Ok(self.done(json!({"status":"failed","phase":"presentation","title":self.item.title(),"error":message}))),
        }
    }
}
fn validate_items(items: &[Item]) -> Result<(), String> {
    let mut keys = HashSet::new();
    for item in items {
        if !item.valid() || !keys.insert(&item.key) {
            return Err("invalid or duplicate item key".into());
        }
    }
    Ok(())
}
pub fn validate_sources(sources: &[Source]) -> Result<(), String> {
    let mut keys = HashSet::new();
    for source in sources {
        if source.key.is_empty() || !keys.insert(&source.key) {
            return Err("invalid or duplicate source key".into());
        }
    }
    Ok(())
}
#[derive(Default)]
pub struct Directory {
    flows: HashMap<u64, Flow>,
    next_token: u64,
}
impl Directory {
    pub fn active(&self) -> usize {
        self.flows.len()
    }
    pub fn invalidate(&mut self) {
        self.flows.clear();
    }
    pub fn cancel(&mut self, token: u64) -> bool {
        self.flows.remove(&token).is_some()
    }
    pub fn start(&mut self, request: Request) -> Result<Step, String> {
        if !request.item.valid() || request.resume_seconds.is_some_and(|v| !v.is_finite()) {
            return Err("invalid item or resume position".into());
        }
        let token = self
            .next_token
            .checked_add(1)
            .ok_or("preparation token exhausted")?;
        let mut flow = Flow {
            token,
            sequence: 0,
            mode: request.mode,
            original: request.item.clone(),
            item: request.item,
            input_resume: request.resume_seconds,
            stage: Stage::Ready,
            sources: Vec::new(),
            preferred: None,
            session_id: None,
            primary_uri: None,
            next_alternate: 0,
            active_alternate: None,
            alternates: Vec::new(),
            original_failure: None,
        };
        let step = flow.resolve()?;
        if !step.done && self.flows.len() >= 128 {
            return Err("too many playback preparation flows".into());
        }
        self.next_token = token;
        if !step.done {
            self.flows.insert(token, flow);
        }
        Ok(step)
    }
    pub fn validate(&self, token: u64, sequence: u64) -> Result<(), String> {
        match self.flows.get(&token) {
            Some(flow) if flow.sequence == sequence => Ok(()),
            _ => Err("playback preparation retired".into()),
        }
    }
    pub fn resume(&mut self, token: u64, sequence: u64, response: Value) -> Result<Step, String> {
        self.validate(token, sequence)?;
        let mut flow = self.flows[&token].clone();
        let step = flow.resume(response)?;
        if step.done {
            self.flows.remove(&token);
        } else {
            self.flows.insert(token, flow);
        }
        Ok(step)
    }
    pub fn fail(
        &mut self,
        token: u64,
        sequence: u64,
        message: String,
        cancelled: bool,
    ) -> Result<Step, String> {
        self.validate(token, sequence)?;
        let mut flow = self.flows[&token].clone();
        let step = flow.fail(message, cancelled)?;
        if step.done {
            self.flows.remove(&token);
        } else {
            self.flows.insert(token, flow);
        }
        Ok(step)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn item(key: &str, kind: &str) -> Item {
        Item {
            key: key.into(),
            id: key.into(),
            kind: kind.into(),
            name: "剧集".into(),
            series_id: None,
            series_name: None,
            season_number: None,
            episode_number: None,
            played: false,
            position_seconds: None,
        }
    }
    fn start(d: &mut Directory, i: Item, mode: Mode) -> Step {
        d.start(Request {
            item: i,
            mode,
            resume_seconds: Some(11.0),
        })
        .unwrap()
    }
    fn resume(d: &mut Directory, s: &Step, v: Value) -> Step {
        d.resume(s.token, s.sequence, v).unwrap()
    }
    fn value(i: Item) -> Value {
        json!({"key":i.key,"id":i.id,"kind":i.kind,"name":i.name,"seriesId":i.series_id,"seriesName":i.series_name,"seasonNumber":i.season_number,"episodeNumber":i.episode_number,"played":i.played,"positionSeconds":i.position_seconds})
    }
    #[test]
    fn continuation_uses_bounded_server_window_and_first_current_anchor() {
        let mut d = Directory::default();
        let mut current = item("current", "episode");
        current.series_id = Some("series".into());
        current.season_number = Some(1);
        let step = start(&mut d, current, Mode::Next);
        assert_eq!(step.effect, Some("episodeWindow"));
        assert_eq!(step.arguments["limit"], 6);
        assert_eq!(step.arguments["startItemId"], "current");
        let mut special = item("special", "episode");
        special.season_number = Some(0);
        let mut next = item("next", "episode");
        next.played = true;
        next.season_number = Some(2);
        next.episode_number = Some(i64::MAX);
        let ready = resume(
            &mut d,
            &step,
            json!([
                value(item("before", "episode")),
                value(item("current", "episode")),
                value(special),
                value(next)
            ]),
        );
        assert_eq!(ready.effect, Some("ready"));
        assert_eq!(ready.arguments["itemKey"], "next");
        d.validate(ready.token, ready.sequence).unwrap();
        assert!(resume(&mut d, &ready, json!(true)).done);
        assert_eq!(d.active(), 0);
    }
    #[test]
    fn continuation_noop_and_unanchored_windows_do_not_leave_leases() {
        for (kind, series, season) in [
            ("movie", Some("series"), Some(1)),
            ("episode", None, Some(1)),
            ("episode", Some("series"), Some(0)),
        ] {
            let mut d = Directory::default();
            let mut current = item("current", kind);
            current.series_id = series.map(str::to_owned);
            current.season_number = season;
            assert!(start(&mut d, current, Mode::Next).done);
            assert_eq!(d.active(), 0);
        }
        let mut saturated = Directory::default();
        for index in 0..128 {
            start(
                &mut saturated,
                item(&format!("active-{index}"), "movie"),
                Mode::Resolve,
            );
        }
        assert!(start(&mut saturated, item("noop", "movie"), Mode::Next).done);
        assert_eq!(saturated.active(), 128);
        for window in [
            json!([]),
            json!([value(item("missing", "episode"))]),
            json!([value(item("current", "episode"))]),
        ] {
            let mut d = Directory::default();
            let mut current = item("current", "episode");
            current.series_id = Some("series".into());
            let step = start(&mut d, current, Mode::Next);
            assert!(resume(&mut d, &step, window).done);
            assert_eq!(d.active(), 0);
        }
    }
    #[test]
    fn continuation_invalid_and_retired_results_cannot_consume_new_work() {
        let mut d = Directory::default();
        let mut current = item("current", "episode");
        current.series_id = Some("series".into());
        let step = start(&mut d, current.clone(), Mode::Next);
        assert!(d
            .resume(step.token, step.sequence, json!([{"key":"bad"}]))
            .is_err());
        d.validate(step.token, step.sequence).unwrap();
        let failed = d
            .fail(
                step.token,
                step.sequence,
                "original window failure".into(),
                false,
            )
            .unwrap();
        assert!(failed.done);
        assert_eq!(failed.result["phase"], "resolve");
        let old = start(&mut d, current.clone(), Mode::Next);
        d.invalidate();
        let fresh = start(&mut d, current, Mode::Next);
        assert!(d.resume(old.token, old.sequence, json!([])).is_err());
        assert!(!d.cancel(old.token));
        d.validate(fresh.token, fresh.sequence).unwrap();
    }

    #[test]
    fn full_source_order_skips_only_bad_alternate_and_preserves_identity() {
        let mut d = Directory::default();
        let s = start(&mut d, item("leaf", "movie"), Mode::Open);
        assert_eq!(s.effect, Some("resolved"));
        let s = resume(&mut d, &s, json!(true));
        assert_eq!(s.effect, Some("playbackInfo"));
        let sources = json!([{"key":"a","id":"a","supportsDirectPlay":false},{"key":"b","id":"b","supportsDirectPlay":true},{"key":"duplicate","id":"b"},{"key":"c","id":"c"}]);
        let s = resume(
            &mut d,
            &s,
            json!({"playSessionId":"session","sources":sources}),
        );
        assert_eq!(s.arguments["sourceKey"], "b");
        let s = resume(&mut d, &s, json!("primary"));
        assert_eq!(s.arguments["sourceKey"], "a");
        let s = d
            .fail(s.token, s.sequence, "alternate error".into(), false)
            .unwrap();
        assert_eq!(s.arguments["sourceKey"], "c");
        let s = resume(&mut d, &s, json!("alternate"));
        assert_eq!(s.effect, Some("ready"));
        assert_eq!(
            s.arguments["alternates"],
            json!([{"key":"c","id":"c","uri":"alternate"}])
        );
        assert_eq!(s.arguments["resumeSeconds"], 11.0);
        assert_eq!(d.active(), 1);
        let done = resume(&mut d, &s, json!(true));
        assert!(done.done);
        assert_eq!(d.active(), 0);
    }
    #[test]
    fn collection_series_reads_home_then_uses_new_item_position_and_exact_title() {
        let mut d = Directory::default();
        let s = start(&mut d, item("box", "boxSet"), Mode::Open);
        assert_eq!(s.arguments["recursive"], false);
        let s = resume(&mut d, &s, json!([value(item("series", "series"))]));
        assert_eq!(s.effect, Some("home"));
        let mut episode = item("episode", "episode");
        episode.series_id = Some("series".into());
        episode.series_name = Some("剧".into());
        episode.season_number = Some(i64::MAX);
        episode.episode_number = Some(i64::MAX);
        episode.position_seconds = Some(1.25);
        let s = resume(&mut d, &s, json!({"nextUp":[value(episode)],"resume":[]}));
        assert_eq!(
            s.arguments["title"],
            "剧 S9223372036854775807E9223372036854775807"
        );
        assert_eq!(s.arguments["resumeSeconds"], 1.25);
    }
    #[test]
    fn episodes_filter_specials_and_choose_first_unwatched_without_reordering() {
        let mut d = Directory::default();
        let s = start(&mut d, item("series", "series"), Mode::Resolve);
        let s = resume(&mut d, &s, json!({"nextUp":[],"resume":[]}));
        let mut special = item("special", "episode");
        special.season_number = Some(0);
        let mut watched = item("watched", "episode");
        watched.played = true;
        let s = resume(
            &mut d,
            &s,
            json!([
                value(special),
                value(watched),
                value(item("first", "episode")),
                value(item("later", "episode"))
            ]),
        );
        assert_eq!(s.arguments["itemKey"], "first");
    }
    #[test]
    fn info_and_primary_failures_use_direct_fallback_and_original_failure() {
        for fail_primary in [false, true] {
            let mut d = Directory::default();
            let s = start(&mut d, item("movie", "movie"), Mode::Open);
            let mut s = resume(&mut d, &s, json!(true));
            if fail_primary {
                s = resume(&mut d, &s, json!({"sources":[],"playSessionId":"old"}));
            }
            let s = d
                .fail(s.token, s.sequence, "original".into(), false)
                .unwrap();
            assert_eq!(s.effect, Some("fallback"));
            let s = resume(&mut d, &s, json!(true));
            assert!(s.arguments["playSessionId"].is_null());
            assert!(s.arguments["mediaSourceId"].is_null());
            let s = d
                .fail(s.token, s.sequence, "fallback error".into(), false)
                .unwrap();
            assert_eq!(s.result["error"], "播放信息获取失败：original");
            assert_eq!(d.active(), 0);
        }
    }
    #[test]
    fn wrong_receipts_and_responses_are_nonconsuming_and_invalidation_retires_ready() {
        let mut d = Directory::default();
        let s = start(&mut d, item("leaf", "movie"), Mode::Open);
        assert!(d.resume(s.token, s.sequence, json!(false)).is_err());
        d.validate(s.token, s.sequence).unwrap();
        let next = resume(&mut d, &s, json!(true));
        assert!(d.resume(s.token, s.sequence, json!(true)).is_err());
        assert!(d
            .resume(
                next.token,
                next.sequence,
                json!({"sources":[{"key":"x","id":"x"},{"key":"x","id":"y"}]})
            )
            .is_err());
        d.validate(next.token, next.sequence).unwrap();
        d.invalidate();
        assert!(d.validate(next.token, next.sequence).is_err());
        let new = start(&mut d, item("new", "audio"), Mode::Resolve);
        assert!(new.token > s.token);
        assert!(!d.cancel(s.token));
        assert_eq!(d.active(), 1);
        let cancelled = d
            .fail(new.token, new.sequence, "cancel".into(), true)
            .unwrap();
        assert_eq!(cancelled.result["status"], "cancelled");
        assert_eq!(d.active(), 0);
    }
    #[test]
    fn bounds_and_exhaustion_fail_before_mutation_and_explicit_cleanup_works() {
        let mut d = Directory::default();
        for _ in 0..128 {
            start(&mut d, item("leaf", "movie"), Mode::Resolve);
        }
        assert!(d
            .start(Request {
                item: item("extra", "movie"),
                mode: Mode::Open,
                resume_seconds: None
            })
            .is_err());
        assert_eq!(d.active(), 128);
        d.invalidate();
        d.next_token = u64::MAX;
        assert!(d
            .start(Request {
                item: item("extra", "movie"),
                mode: Mode::Open,
                resume_seconds: None
            })
            .is_err());
        assert_eq!(d.active(), 0);
        let mut d = Directory::default();
        let s = start(&mut d, item("leaf", "movie"), Mode::Open);
        d.flows.get_mut(&s.token).unwrap().sequence = u64::MAX;
        assert!(d.resume(s.token, u64::MAX, json!(true)).is_err());
        d.validate(s.token, u64::MAX).unwrap();
    }
    #[test]
    fn empty_result_and_same_id_resume_match_native_fallback() {
        let mut d = Directory::default();
        let s = start(&mut d, item("box", "boxSet"), Mode::Open);
        let s = resume(&mut d, &s, json!([]));
        assert_eq!(s.result["error"], "这个合集里还没有可播放的内容");
        let mut series = item("series", "series");
        series.position_seconds = Some(99.0);
        let s = start(&mut d, series, Mode::Open);
        let mut leaf = item("opaque", "episode");
        leaf.id = "series".into();
        leaf.series_id = Some("series".into());
        leaf.position_seconds = Some(55.0);
        let s = resume(&mut d, &s, json!({"nextUp":[value(leaf)],"resume":[]}));
        assert_eq!(s.arguments["resumeSeconds"], 11.0);
    }
}
