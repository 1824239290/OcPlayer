//! Retained decoder-independent track workflow. Host effects are acknowledged only
//! after the engine succeeds; reset retires receipts without reusing identifiers.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Track {
    pub id: i64,
    pub kind: String,
    pub source: String,
    #[serde(default)]
    pub selected: bool,
    pub title: Option<String>,
    pub language: Option<String>,
    pub display_name: Option<String>,
    #[serde(default)]
    pub can_remove: bool,
}
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
pub enum Preference {
    #[serde(rename = "zh-Hans")]
    Simplified,
    #[serde(rename = "zh-Hant")]
    Traditional,
    #[serde(rename = "followSource")]
    FollowSource,
    #[serde(rename = "off")]
    Off,
}
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum Selection {
    Keep,
    Disable,
    Select { id: i64 },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Script {
    Simplified,
    Traditional,
    Unknown,
}
fn normalize(value: Option<&str>) -> String {
    value
        .unwrap_or_default()
        .to_lowercase()
        .graphemes(true)
        .map(|g| {
            let c = g.chars().next().unwrap();
            if !unicode_normalization::char::is_combining_mark(c)
                && (c.is_alphabetic() || c.is_numeric())
            {
                g
            } else {
                " "
            }
        })
        .collect()
}
fn contains_token(field: &str, list: &[&str]) -> bool {
    field.split(' ').any(|token| list.contains(&token))
}
fn compact(field: &str) -> String {
    field.split(' ').collect()
}
fn strong(field: &str) -> bool {
    contains_token(field, CHINESE_LANGUAGE_TOKENS)
        || contains_token(field, STRONG_SCRIPT_TOKENS)
        || CHINESE_WORDS
            .iter()
            .any(|word| compact(field).contains(word))
}
fn script(field: &str, weak: bool) -> Script {
    if contains_token(field, SIMPLIFIED_TOKENS) {
        return Script::Simplified;
    }
    if contains_token(field, TRADITIONAL_TOKENS) {
        return Script::Traditional;
    }
    if weak && contains_token(field, WEAK_SIMPLIFIED_TOKENS) {
        return Script::Simplified;
    }
    if weak && contains_token(field, WEAK_TRADITIONAL_TOKENS) {
        return Script::Traditional;
    }
    let value = compact(field);
    if SIMPLIFIED_WORDS.iter().any(|word| value.contains(word)) {
        return Script::Simplified;
    }
    if TRADITIONAL_WORDS.iter().any(|word| value.contains(word)) {
        return Script::Traditional;
    }
    Script::Unknown
}
fn score(track: &Track, display: Option<&str>, preferred: Script) -> Option<u8> {
    let fields = [
        normalize(track.language.as_deref()),
        normalize(track.title.as_deref()),
        normalize(display),
    ];
    if !fields.iter().any(|field| strong(field)) && !contains_token(&fields[1], WEAK_SCRIPT_TOKENS)
    {
        return None;
    }
    let conclusions: Vec<_> = fields
        .iter()
        .enumerate()
        .map(|(i, f)| script(f, i == 1))
        .filter(|s| *s != Script::Unknown)
        .collect();
    let detected = conclusions
        .first()
        .copied()
        .filter(|first| conclusions.iter().all(|s| s == first))
        .unwrap_or(Script::Unknown);
    Some(if detected == preferred {
        120
    } else if detected == Script::Unknown {
        110
    } else {
        105
    })
}
pub fn selection(
    tracks: &[Track],
    preference: Preference,
    current: Option<i64>,
    names: &BTreeMap<String, String>,
) -> Selection {
    let subtitles: Vec<_> = tracks.iter().filter(|t| t.kind == "subtitle").collect();
    if subtitles.is_empty() {
        return Selection::Keep;
    }
    if preference != Preference::Off
        && current.is_none()
        && subtitles.iter().all(|t| t.source == "external")
    {
        return Selection::Select {
            id: subtitles[0].id,
        };
    }
    let preferred = match preference {
        Preference::FollowSource => return Selection::Keep,
        Preference::Off => {
            return if current.is_none() {
                Selection::Keep
            } else {
                Selection::Disable
            }
        }
        Preference::Simplified => Script::Simplified,
        Preference::Traditional => Script::Traditional,
    };
    let get_score = |t: &Track| {
        score(
            t,
            names
                .get(&t.id.to_string())
                .map(String::as_str)
                .or(t.display_name.as_deref()),
            preferred,
        )
    };
    let mut best = None;
    for track in &subtitles {
        if let Some(s) = get_score(track) {
            if best.is_none_or(|(_, old)| s > old) {
                best = Some((track.id, s));
            }
        }
    }
    let Some((id, s)) = best else {
        return Selection::Keep;
    };
    if current == Some(id)
        || current
            .and_then(|c| subtitles.iter().find(|t| t.id == c))
            .and_then(|t| get_score(t))
            == Some(s)
    {
        return Selection::Keep;
    }
    Selection::Select { id }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
pub enum Request {
    Automatic {
        tracks: Vec<Track>,
        preference: Preference,
        current: Option<i64>,
    },
    SelectSubtitle {
        id: Option<i64>,
    },
    SelectAudio {
        id: i64,
    },
    ImportSubtitle {
        path: String,
        name: String,
    },
    AttachSubtitle {
        path: String,
        name: Option<String>,
    },
    RemoveSubtitle {
        track: Track,
    },
}
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum Effect {
    SelectSubtitle { id: Option<i64> },
    SelectAudio { id: i64 },
    AddSubtitle { path: String },
    RemoveSubtitle { id: i64 },
}
#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub manual_choice: bool,
    pub batch_id: Option<String>,
    pub external_names: BTreeMap<String, String>,
    pub pending_operation_id: Option<u64>,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub operation_id: Option<u64>,
    pub effect: Option<Effect>,
    pub snapshot: Snapshot,
}
struct Pending {
    id: u64,
    request: Request,
    imported: Option<i64>,
}
#[derive(Default)]
pub struct TrackFlow {
    snapshot: Snapshot,
    pending: Option<Pending>,
    next_id: u64,
}
impl TrackFlow {
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    fn step(&self, effect: Option<Effect>) -> Step {
        Step {
            operation_id: self.snapshot.pending_operation_id,
            effect,
            snapshot: self.snapshot.clone(),
        }
    }
    pub fn reset(&mut self) -> &Snapshot {
        self.pending = None;
        self.snapshot = Snapshot::default();
        &self.snapshot
    }
    pub fn begin_batch(&mut self, id: String) -> Result<&Snapshot, String> {
        if id.trim().is_empty() {
            return Err("batchId must not be empty".into());
        }
        self.snapshot.batch_id = Some(id);
        Ok(&self.snapshot)
    }
    pub fn end_batch(&mut self, id: &str) -> Result<&Snapshot, String> {
        if self.snapshot.batch_id.as_deref() != Some(id) {
            return Err("track batch retired".into());
        }
        self.snapshot.batch_id = None;
        Ok(&self.snapshot)
    }
    pub fn register_name(&mut self, id: i64, name: String) -> &Snapshot {
        if !name.is_empty() {
            self.snapshot.external_names.insert(id.to_string(), name);
        }
        &self.snapshot
    }
    pub fn begin(&mut self, request: Request) -> Result<Step, String> {
        if self.pending.is_some() {
            return Ok(self.step(None));
        }
        let effect = match &request {
            Request::Automatic {
                tracks,
                preference,
                current,
            } => {
                validate_tracks(tracks)?;
                if self.snapshot.manual_choice || self.snapshot.batch_id.is_some() {
                    return Ok(self.step(None));
                }
                match selection(tracks, *preference, *current, &self.snapshot.external_names) {
                    Selection::Keep => return Ok(self.step(None)),
                    Selection::Disable => Effect::SelectSubtitle { id: None },
                    Selection::Select { id } => Effect::SelectSubtitle { id: Some(id) },
                }
            }
            Request::SelectSubtitle { id } => Effect::SelectSubtitle { id: *id },
            Request::SelectAudio { id } => Effect::SelectAudio { id: *id },
            Request::ImportSubtitle { path, .. } | Request::AttachSubtitle { path, .. } => {
                if path.is_empty() {
                    return Err("subtitle path must not be empty".into());
                }
                Effect::AddSubtitle { path: path.clone() }
            }
            Request::RemoveSubtitle { track } => {
                validate_tracks(std::slice::from_ref(track))?;
                if track.kind != "subtitle" || !track.can_remove {
                    return Ok(self.step(None));
                }
                Effect::RemoveSubtitle { id: track.id }
            }
        };
        let id = self
            .next_id
            .checked_add(1)
            .ok_or("track operation identifier exhausted")?;
        self.next_id = id;
        self.snapshot.pending_operation_id = Some(id);
        self.pending = Some(Pending {
            id,
            request,
            imported: None,
        });
        Ok(self.step(Some(effect)))
    }
    pub fn complete(
        &mut self,
        id: u64,
        success: bool,
        track_id: Option<i64>,
    ) -> Result<Step, String> {
        let pending = self
            .pending
            .as_ref()
            .filter(|p| p.id == id)
            .ok_or("track operation retired")?;
        let adding = matches!(
            pending.request,
            Request::ImportSubtitle { .. } | Request::AttachSubtitle { .. }
        ) && pending.imported.is_none();
        if success && adding && track_id.is_none() {
            return Err("successful add requires trackId".into());
        }
        if track_id.is_some() && (!success || !adding) {
            return Err("trackId is only allowed for successful add".into());
        }
        let next_effect_id =
            if success && matches!(pending.request, Request::ImportSubtitle { .. }) && adding {
                Some(
                    self.next_id
                        .checked_add(1)
                        .ok_or("track operation identifier exhausted")?,
                )
            } else {
                None
            };
        let mut pending = self.pending.take().unwrap();
        if success {
            match &pending.request {
                Request::SelectSubtitle { .. } => self.snapshot.manual_choice = true,
                Request::RemoveSubtitle { track } => {
                    self.snapshot.external_names.remove(&track.id.to_string());
                    if track.selected {
                        self.snapshot.manual_choice = false;
                    }
                }
                Request::AttachSubtitle { name, .. } => {
                    if let Some(name) = name {
                        self.register_name(track_id.unwrap(), name.clone());
                    }
                }
                Request::ImportSubtitle { name, .. } if pending.imported.is_none() => {
                    let added = track_id.unwrap();
                    self.register_name(added, name.clone());
                    pending.imported = Some(added);
                    pending.id = next_effect_id.unwrap();
                    self.next_id = pending.id;
                    self.snapshot.pending_operation_id = Some(pending.id);
                    self.pending = Some(pending);
                    return Ok(self.step(Some(Effect::SelectSubtitle { id: Some(added) })));
                }
                Request::ImportSubtitle { .. } => self.snapshot.manual_choice = true,
                _ => {}
            }
        }
        self.snapshot.pending_operation_id = None;
        Ok(self.step(None))
    }
}
pub fn validate_tracks(tracks: &[Track]) -> Result<(), String> {
    let mut ids = std::collections::HashSet::new();
    for t in tracks {
        if !matches!(t.kind.as_str(), "video" | "audio" | "subtitle")
            || !matches!(t.source.as_str(), "embedded" | "external")
        {
            return Err("invalid track kind or source".into());
        }
        if !ids.insert((t.kind.as_str(), t.id)) {
            return Err("duplicate track identifier".into());
        }
    }
    Ok(())
}
const CHINESE_LANGUAGE_TOKENS: &[&str] = &[
    "zh",
    "zho",
    "chi",
    "chn",
    "cmn",
    "yue",
    "cn",
    "zhcn",
    "zhtw",
    "zhhk",
    "zhsg",
    "zhs",
    "zht",
    "zhhans",
    "zhhant",
    "chinese",
    "mandarin",
    "cantonese",
];
const STRONG_SCRIPT_TOKENS: &[&str] = &[
    "chs",
    "cht",
    "tc",
    "tcl",
    "gb",
    "gb2312",
    "big5",
    "hans",
    "hant",
    "simplified",
    "traditional",
];
const WEAK_SCRIPT_TOKENS: &[&str] = &["sc", "sg", "mo"];
const SIMPLIFIED_TOKENS: &[&str] = &["hans", "cn", "chs", "scl", "gb", "gb2312", "simplified"];
const TRADITIONAL_TOKENS: &[&str] = &[
    "hant",
    "cht",
    "tc",
    "tcl",
    "big5",
    "traditional",
    "tw",
    "hk",
];
const WEAK_SIMPLIFIED_TOKENS: &[&str] = &["sc", "sg"];
const WEAK_TRADITIONAL_TOKENS: &[&str] = &["mo"];
const CHINESE_WORDS: &[&str] = &[
    "中文",
    "中字",
    "简体",
    "繁体",
    "繁體",
    "简中",
    "繁中",
    "国语",
    "國語",
    "华语",
    "華語",
    "汉语",
    "漢語",
    "粤语",
    "粤語",
    "广东话",
    "廣東話",
    "中日",
    "日中",
    "中英",
    "英中",
    "中韩",
    "韩中",
    "简日",
    "日简",
    "繁日",
    "日繁",
    "简英",
    "繁英",
    "简繁",
    "繁简",
];
const SIMPLIFIED_WORDS: &[&str] = &["简", "簡"];
const TRADITIONAL_WORDS: &[&str] = &["繁", "正体", "正體"];

#[cfg(test)]
mod tests {
    use super::*;
    fn track(id: i64, title: &str) -> Track {
        Track {
            id,
            kind: "subtitle".into(),
            source: "embedded".into(),
            selected: false,
            title: Some(title.into()),
            language: None,
            display_name: None,
            can_remove: true,
        }
    }
    #[test]
    fn scoring_respects_field_trust_and_ties() {
        let mut tracks = vec![track(1, "english"), track(2, "繁體"), track(3, "中文")];
        tracks[0].language = Some("sc".into());
        assert_eq!(
            selection(&tracks, Preference::Simplified, None, &Default::default()),
            Selection::Select { id: 3 }
        );
        tracks[2].title = Some("SC".into());
        assert_eq!(
            selection(&tracks, Preference::Simplified, None, &Default::default()),
            Selection::Select { id: 3 }
        );
        tracks.push(track(4, "CHS"));
        assert_eq!(
            selection(
                &tracks,
                Preference::Simplified,
                Some(4),
                &Default::default()
            ),
            Selection::Keep
        );
        tracks[2].language = Some("zh-Hant".into());
        assert_eq!(
            selection(&tracks, Preference::Simplified, None, &Default::default()),
            Selection::Select { id: 4 }
        );
    }
    #[test]
    fn external_fallback_and_off_are_preserved() {
        let mut t = track(i64::MIN, "English");
        t.source = "external".into();
        assert_eq!(
            selection(
                &[t.clone()],
                Preference::FollowSource,
                None,
                &Default::default()
            ),
            Selection::Select { id: i64::MIN }
        );
        assert_eq!(
            selection(&[t], Preference::Off, Some(i64::MIN), &Default::default()),
            Selection::Disable
        );
    }
    #[test]
    fn track_ids_are_scoped_to_kind() {
        let subtitle = track(1, "CHS");
        let mut audio = track(1, "eng");
        audio.kind = "audio".into();
        let tracks = vec![audio, subtitle];
        assert!(validate_tracks(&tracks).is_ok());
        assert_eq!(
            selection(&tracks, Preference::Simplified, None, &Default::default()),
            Selection::Select { id: 1 }
        );
    }
    #[test]
    fn import_commits_name_before_selection_and_failure_keeps_gate_open() {
        let mut flow = TrackFlow::default();
        let start = flow
            .begin(Request::ImportSubtitle {
                path: "/subtitle".into(),
                name: "简体".into(),
            })
            .unwrap();
        let id = start.operation_id.unwrap();
        assert!(flow.complete(id, true, None).is_err());
        let next = flow.complete(id, true, Some(i64::MAX)).unwrap();
        assert!(matches!(
            next.effect,
            Some(Effect::SelectSubtitle { id: Some(i64::MAX) })
        ));
        assert_eq!(next.snapshot.external_names[&i64::MAX.to_string()], "简体");
        assert!(flow.complete(id, true, Some(1)).is_err());
        assert!(flow.complete(id, false, None).is_err());
        let select_id = next.operation_id.unwrap();
        assert!(select_id > id);
        assert!(
            !flow
                .complete(select_id, false, None)
                .unwrap()
                .snapshot
                .manual_choice
        );
        assert!(flow.complete(id, true, None).is_err());
    }
    #[test]
    fn removal_unlocks_manual_only_after_success_and_selected_removal() {
        let mut f = TrackFlow::default();
        let id = f
            .begin(Request::SelectSubtitle { id: None })
            .unwrap()
            .operation_id
            .unwrap();
        f.complete(id, true, None).unwrap();
        let mut t = track(4, "简体");
        t.selected = true;
        f.register_name(4, "简体".into());
        let id = f
            .begin(Request::RemoveSubtitle { track: t.clone() })
            .unwrap()
            .operation_id
            .unwrap();
        f.complete(id, false, None).unwrap();
        assert!(f.snapshot.manual_choice);
        assert!(f.snapshot.external_names.contains_key("4"));
        let id = f
            .begin(Request::RemoveSubtitle { track: t })
            .unwrap()
            .operation_id
            .unwrap();
        f.complete(id, true, None).unwrap();
        assert!(!f.snapshot.manual_choice);
        assert!(!f.snapshot.external_names.contains_key("4"));
    }
    #[test]
    fn reset_and_batches_retire_old_work_without_consuming_current() {
        let mut f = TrackFlow::default();
        let old = f
            .begin(Request::SelectSubtitle { id: Some(4) })
            .unwrap()
            .operation_id
            .unwrap();
        f.reset();
        let new = f
            .begin(Request::SelectSubtitle { id: Some(5) })
            .unwrap()
            .operation_id
            .unwrap();
        assert!(new > old);
        assert!(f.complete(old, true, None).is_err());
        assert_eq!(f.snapshot.pending_operation_id, Some(new));
        f.complete(new, true, None).unwrap();
        f.reset();
        f.begin_batch("new".into()).unwrap();
        assert!(f.end_batch("old").is_err());
        assert_eq!(f.snapshot.batch_id.as_deref(), Some("new"));
        assert!(f
            .begin(Request::Automatic {
                tracks: vec![track(1, "CHS")],
                preference: Preference::Simplified,
                current: None
            })
            .unwrap()
            .effect
            .is_none());
        f.end_batch("new").unwrap();
        assert!(f
            .begin(Request::Automatic {
                tracks: vec![track(1, "CHS")],
                preference: Preference::Simplified,
                current: None
            })
            .unwrap()
            .effect
            .is_some());
    }
    #[test]
    fn reentrant_refresh_cannot_replace_pending_effect() {
        let mut f = TrackFlow::default();
        let id = f
            .begin(Request::SelectAudio { id: 1 })
            .unwrap()
            .operation_id
            .unwrap();
        assert!(f
            .begin(Request::Automatic {
                tracks: vec![track(2, "CHS")],
                preference: Preference::Simplified,
                current: None
            })
            .unwrap()
            .effect
            .is_none());
        assert_eq!(f.snapshot.pending_operation_id, Some(id));
        f.complete(id, false, None).unwrap();
    }
}
