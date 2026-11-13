//! Reference intro detection, source consensus and manual-seek learning.
use crate::{
    cache::{atomic_write, IntroHint, IntroSource},
    DanmakuComment,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::PathBuf,
};
use unicode_segmentation::UnicodeSegmentation;

pub const LANDING_MIN: f64 = 30.0;
pub const LANDING_MAX: f64 = 360.0;
pub const MINIMUM_SEEK: f64 = 5.0;
pub const SNAP_TOLERANCE: f64 = 10.0;
pub const MINIMUM_EPISODES: i64 = 2;
pub const MAX_EVENTS: usize = 200;
const JUMP: [&str; 5] = ["跳伞", "空降", "跳至", "跳到", "空投"];
const LANDING: [&str; 10] = [
    "空降成功",
    "空降完成",
    "已空降",
    "着陆成功",
    "降落成功",
    "感谢指挥",
    "感谢塔台",
    "感谢空降",
    "空降部隊",
    "空降部队",
];
const START: [&str; 4] = ["正片开始", "正片開始", "开始正片", "開始正片"];

fn in_table(c: char, table: &[(u32, u32)]) -> bool {
    let value = c as u32;
    table
        .binary_search_by(|&(lo, hi)| {
            if value < lo {
                std::cmp::Ordering::Greater
            } else if value > hi {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .is_ok()
}
fn number(g: &str) -> bool {
    g.chars()
        .next()
        .is_some_and(|c| in_table(c, crate::intro_unicode::NUMERIC))
}

/// Swift Regex \d consumes numeric Characters (including CJK numeric scalars
/// and combining marks), rather than Rust Regex's decimal-digit scalars.
pub fn timestamp(text: &str) -> Option<f64> {
    let normalized = text.replace('：', ":").replace('．', ".");
    let chars: Vec<_> = normalized.graphemes(true).collect();
    for start in 0..chars.len() {
        if !number(chars[start]) {
            continue;
        }
        let mut first_end = start + 1;
        if first_end < chars.len() && number(chars[first_end]) {
            first_end += 1
        }
        if first_end >= chars.len() || !matches!(chars[first_end], ":" | ".") {
            continue;
        }
        let second_start = first_end + 1;
        if second_start >= chars.len() || !number(chars[second_start]) {
            continue;
        }
        let mut second_end = second_start + 1;
        if second_end < chars.len() && number(chars[second_end]) {
            second_end += 1
        }
        let mut end = second_end;
        let mut third = None;
        if end + 1 < chars.len() && chars[end] == ":" && number(chars[end + 1]) {
            let third_start = end + 1;
            end = third_start + 1;
            if end < chars.len() && number(chars[end]) {
                end += 1
            }
            third = Some(chars[third_start..end].concat());
        }
        // The reference validates only the first regex match, not a later one.
        if (start > 0 && number(chars[start - 1])) || (end < chars.len() && number(chars[end])) {
            return None;
        }
        let minute = chars[start..first_end].concat().parse::<i64>().unwrap_or(0);
        let second = chars[second_start..second_end]
            .concat()
            .parse::<i64>()
            .unwrap_or(0);
        if minute >= 60
            || second >= 60
            || (chars[first_end] == "." && second_end - second_start != 2)
        {
            return None;
        }
        // Retain OcPlayer's existing third-capture interpretation exactly.
        let hour = third.and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
        return Some((hour * 3600 + minute * 60 + second) as f64);
    }
    None
}

fn swift_double(raw: &str) -> Option<f64> {
    if let Ok(n) = raw.parse::<f64>() {
        return n.is_finite().then_some(n);
    }
    let unsigned = raw
        .strip_prefix('-')
        .or_else(|| raw.strip_prefix('+'))
        .unwrap_or(raw);
    if !unsigned.starts_with("0x") && !unsigned.starts_with("0X") {
        return None;
    }
    hexadecimal_double(raw)
}

#[cfg(unix)]
unsafe extern "C" {
    fn strtod_l(
        input: *const std::ffi::c_char,
        end: *mut *mut std::ffi::c_char,
        locale: libc::locale_t,
    ) -> f64;
}
#[cfg(windows)]
unsafe extern "C" {
    fn _create_locale(
        category: libc::c_int,
        name: *const std::ffi::c_char,
    ) -> *mut std::ffi::c_void;
    fn _strtod_l(
        input: *const std::ffi::c_char,
        end: *mut *mut std::ffi::c_char,
        locale: *mut std::ffi::c_void,
    ) -> f64;
}
fn hexadecimal_double(raw: &str) -> Option<f64> {
    static C_LOCALE: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    // C locale is immutable and retained for the process lifetime. Explicit
    // locale selection avoids a player's unrelated global locale changes.
    let locale = *C_LOCALE.get_or_init(|| {
        #[cfg(unix)]
        {
            unsafe {
                libc::newlocale(libc::LC_NUMERIC_MASK, c"C".as_ptr(), std::ptr::null_mut()) as usize
            }
        }
        #[cfg(windows)]
        {
            unsafe { _create_locale(libc::LC_NUMERIC, c"C".as_ptr()) as usize }
        }
    });
    if locale == 0 {
        return None;
    }
    let input = std::ffi::CString::new(raw).ok()?;
    let mut end = std::ptr::null_mut();
    // CString guarantees a live NUL-terminated buffer; the end pointer is
    // compared without dereferencing it. CRT conversion rounds once, retaining
    // sticky tail bits that iterative f64 hex accumulation would discard.
    let value = unsafe {
        #[cfg(unix)]
        {
            strtod_l(input.as_ptr(), &mut end, locale as libc::locale_t)
        }
        #[cfg(windows)]
        {
            _strtod_l(input.as_ptr(), &mut end, locale as *mut std::ffi::c_void)
        }
    };
    let complete = end == unsafe { input.as_ptr().add(raw.len()) } as *mut std::ffi::c_char;
    (complete && value.is_finite()).then_some(value)
}

pub fn comment_fields(p: &str) -> (Option<f64>, Option<String>) {
    let fields: Vec<String> = if p.is_ascii() {
        p.split(',')
            .filter(|s| !s.is_empty())
            .take(4)
            .map(str::to_owned)
            .collect()
    } else {
        let g: Vec<_> = p.graphemes(true).collect();
        g.split(|g| *g == ",")
            .filter(|s| !s.is_empty())
            .take(4)
            .map(|s| s.concat())
            .collect()
    };
    let time = fields
        .first()
        .and_then(|s| swift_double(s))
        .filter(|v| *v >= 0.0);
    let uid = fields
        .get(3)
        .map(|s| {
            s.trim_matches(|c| in_table(c, crate::intro_unicode::WHITESPACE))
                .to_owned()
        })
        .filter(|s| !s.is_empty());
    (time, uid)
}
#[derive(Default)]
struct KeywordScan {
    jump_ends: [Option<usize>; 5],
    landing: bool,
    start: bool,
}
fn scan_keywords(text: &str) -> KeywordScan {
    struct Needles {
        keywords: Vec<&'static [u8]>,
        buckets: [Vec<usize>; 256],
    }
    static NEEDLES: std::sync::OnceLock<Needles> = std::sync::OnceLock::new();
    let needles = NEEDLES.get_or_init(|| {
        let keywords: Vec<_> = JUMP
            .iter()
            .chain(LANDING.iter())
            .chain(START.iter())
            .map(|s| s.as_bytes())
            .collect();
        let mut buckets: [Vec<usize>; 256] = std::array::from_fn(|_| Vec::new());
        for (index, keyword) in keywords.iter().enumerate() {
            buckets[keyword[0] as usize].push(index)
        }
        Needles { keywords, buckets }
    });
    let mut result = KeywordScan::default();
    let mut found = [false; 19];
    let mut remaining = 19;
    // Most comments have no signal. Only build grapheme boundaries after a
    // byte match, retaining the native one-pass scan and rare-hit validation.
    let mut boundaries: Option<HashSet<usize>> = None;
    let bytes = text.as_bytes();
    for (offset, byte) in bytes.iter().enumerate() {
        if remaining == 0 {
            break;
        }
        for &index in &needles.buckets[*byte as usize] {
            let needle = needles.keywords[index];
            if found[index] || !bytes[offset..].starts_with(needle) {
                continue;
            }
            let end = offset + needle.len();
            let boundaries = boundaries.get_or_insert_with(|| {
                let mut bounds: HashSet<_> = text.grapheme_indices(true).map(|(i, _)| i).collect();
                bounds.insert(text.len());
                bounds
            });
            if !boundaries.contains(&offset) || !boundaries.contains(&end) {
                continue;
            }
            found[index] = true;
            remaining -= 1;
            if index < 5 {
                result.jump_ends[index] = Some(end)
            } else if index < 15 {
                result.landing = true
            } else {
                result.start = true
            }
        }
    }
    result
}
pub fn jump_target(text: &str) -> Option<f64> {
    jump_target_with_scan(text, &scan_keywords(text))
}
fn jump_target_with_scan(text: &str, scan: &KeywordScan) -> Option<f64> {
    for end in scan.jump_ends.into_iter().flatten() {
        let window: String = text[end..].graphemes(true).take(12).collect();
        if let Some(value) = timestamp(&window) {
            return Some(value);
        }
    }
    None
}
fn clusters<T>(mut values: Vec<T>, position: impl Fn(&T) -> f64, gap: f64) -> Vec<Vec<T>> {
    values.sort_by(|a, b| position(a).total_cmp(&position(b)));
    let mut clusters: Vec<Vec<T>> = Vec::new();
    for value in values {
        if let Some(last) = clusters.last_mut() {
            if position(&value) - position(last.last().unwrap()) <= gap {
                last.push(value);
                continue;
            }
        }
        clusters.push(vec![value]);
    }
    clusters
}
fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    let mid = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    }
}
fn rounded(value: f64) -> i64 {
    (value * 10.0).round() as i64
}
fn largest(values: Vec<f64>) -> Option<Vec<f64>> {
    let mut best = None;
    for cluster in clusters(values, |v| *v, 25.0) {
        if best
            .as_ref()
            .is_none_or(|b: &Vec<f64>| cluster.len() > b.len())
        {
            best = Some(cluster)
        }
    }
    best
}
pub fn detect(comments: &[DanmakuComment]) -> Option<IntroHint> {
    let mut targets = Vec::new();
    let mut landings = Vec::new();
    let mut starts = Vec::new();
    for comment in comments {
        let (time, uid) = comment_fields(&comment.p);
        let Some(time) = time else { continue };
        let text = &comment.m;
        let scan = scan_keywords(text);
        if let Some(target) = jump_target_with_scan(text, &scan) {
            targets.push((time, target, uid.clone()))
        }
        if scan.landing {
            landings.push((time, uid.clone()))
        }
        if scan.start {
            starts.push((time, uid))
        }
    }
    targets.retain(|v| (30.0..=300.0).contains(&v.1));
    if let Some(cluster) = largest(targets.iter().map(|v| v.1).collect()) {
        let end = median(cluster.clone()).round();
        let confirmed_count = landings
            .iter()
            .chain(&starts)
            .filter(|v| v.0 <= 360.0 && (v.0 - end).abs() <= 15.0)
            .count();
        let distinct: HashSet<_> = cluster.iter().map(|v| rounded(*v)).collect();
        let cluster_posts: Vec<_> = targets
            .iter()
            .filter(|v| distinct.contains(&rounded(v.1)))
            .collect();
        let users: HashSet<_> = cluster_posts.iter().filter_map(|v| v.2.as_ref()).collect();
        if distinct.len() >= if confirmed_count > 0 { 2 } else { 3 }
            || (confirmed_count > 0 && users.len() >= 2)
        {
            let earliest = cluster_posts
                .iter()
                .map(|v| v.0)
                .min_by(f64::total_cmp)
                .unwrap();
            let start = (earliest - 2.0).max(0.0).floor();
            return Some(IntroHint {
                start_seconds: ((20.0..=240.0).contains(&(end - start))).then_some(start),
                end_seconds: end,
                evidence_count: (cluster.len() + confirmed_count) as i64,
                source: IntroSource::Danmaku,
            });
        }
    }
    landings.retain(|v| v.0 <= 360.0);
    let cluster = largest(landings.iter().map(|v| v.0).collect())?;
    if cluster.len() < 3 {
        return None;
    }
    let times: HashSet<_> = cluster.iter().map(|v| rounded(*v)).collect();
    let users: HashSet<_> = landings
        .iter()
        .filter(|v| times.contains(&rounded(v.0)))
        .filter_map(|v| v.1.as_ref())
        .collect();
    let end = median(cluster.clone()).round();
    if users.len() < 2 || !(30.0..=300.0).contains(&end) {
        return None;
    }
    Some(IntroHint {
        start_seconds: None,
        end_seconds: end,
        evidence_count: cluster.len() as i64,
        source: IntroSource::Danmaku,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeekEvent {
    #[serde(rename = "episodeID")]
    pub episode_id: i64,
    pub position: f64,
    pub at: f64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Consensus {
    pub end: f64,
    #[serde(rename = "episodeCount")]
    pub episode_count: usize,
}
pub fn consensus(events: &[SeekEvent], minimum: i64) -> Option<Consensus> {
    let mut best: Option<Vec<SeekEvent>> = None;
    let count = |c: &Vec<SeekEvent>| c.iter().map(|e| e.episode_id).collect::<HashSet<_>>().len();
    for cluster in clusters(events.to_vec(), |e| e.position, SNAP_TOLERANCE) {
        if best
            .as_ref()
            .is_none_or(|b| (count(&cluster), cluster.len()) > (count(b), b.len()))
        {
            best = Some(cluster)
        }
    }
    let best = best?;
    let episode_count = count(&best);
    if (episode_count as i64) < minimum {
        return None;
    }
    let end = median(best.iter().map(|e| e.position).collect());
    (LANDING_MIN..=LANDING_MAX)
        .contains(&end)
        .then_some(Consensus { end, episode_count })
}
pub fn eligible_seek(from: f64, to: f64) -> bool {
    (LANDING_MIN..=LANDING_MAX).contains(&to) && from < to - MINIMUM_SEEK
}
pub fn confirmed_hint(to: f64, current: Option<IntroHint>) -> Option<IntroHint> {
    let mut hint = current?;
    if !matches!(hint.source, IntroSource::Danmaku)
        || (to - hint.end_seconds).abs() > SNAP_TOLERANCE
    {
        return None;
    }
    hint.evidence_count = hint.evidence_count.checked_add(1)?;
    hint.source = IntroSource::Learned;
    Some(hint)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Interval {
    pub source: IntroSource,
    pub start: Option<f64>,
    pub end: f64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelectedInterval {
    pub start: Option<f64>,
    pub end: f64,
    pub votes: usize,
    pub source: IntroSource,
}
fn priority(source: IntroSource) -> u8 {
    match source {
        IntroSource::Aniskip => 5,
        IntroSource::AnimeSkip => 4,
        IntroSource::Learned => 3,
        IntroSource::TheIntroDB => 2,
        IntroSource::Danmaku => 1,
    }
}
pub fn select_intervals(intervals: &[Interval]) -> Option<SelectedInterval> {
    let mut best: Option<Vec<Interval>> = None;
    for cluster in clusters(intervals.to_vec(), |v| v.end, 10.0) {
        if best.as_ref().is_none_or(|b| {
            (cluster.len(), priority(cluster[0].source)) > (b.len(), priority(b[0].source))
        }) {
            best = Some(cluster)
        }
    }
    let best = best?;
    let starts: Vec<_> = best.iter().filter_map(|v| v.start).collect();
    let mut source = best[0].source;
    for v in &best {
        if priority(v.source) > priority(source) {
            source = v.source
        }
    }
    Some(SelectedInterval {
        start: (!starts.is_empty()).then(|| median(starts)),
        end: median(best.iter().map(|v| v.end).collect()),
        votes: best.len(),
        source,
    })
}
pub fn sibling_hint(hints: &[IntroHint]) -> Option<IntroHint> {
    let mut best: Option<Vec<f64>> = None;
    for cluster in clusters(hints.iter().map(|h| h.end_seconds).collect(), |v| *v, 5.0) {
        if best.as_ref().is_none_or(|b| cluster.len() > b.len()) {
            best = Some(cluster)
        }
    }
    let best = best?;
    if best.len() < 2 {
        return None;
    }
    let end = median(best.clone());
    let starts: Vec<_> = hints
        .iter()
        .filter(|h| (h.end_seconds - end).abs() <= 5.0)
        .filter_map(|h| h.start_seconds)
        .collect();
    let start = if starts.len() >= 2
        && starts.iter().copied().max_by(f64::total_cmp)?
            - starts.iter().copied().min_by(f64::total_cmp)?
            <= 5.0
    {
        Some(median(starts))
    } else {
        None
    };
    Some(IntroHint {
        start_seconds: start,
        end_seconds: end,
        evidence_count: best.len() as i64,
        source: IntroSource::Danmaku,
    })
}
fn decode<T: for<'a> Deserialize<'a>>(args: &Value, key: &str) -> Result<T, String> {
    let v = args.get(key).ok_or_else(|| format!("{key} is required"))?;
    let v = if let Some(s) = v.as_str() {
        serde_json::from_str(s).map_err(|e| format!("invalid payload JSON: {e}"))?
    } else {
        v.clone()
    };
    serde_json::from_value(v).map_err(|e| format!("invalid {key}: {e}"))
}
fn text<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{key} is required"))
}
fn id(args: &Value, key: &str) -> Result<i64, String> {
    args.get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| format!("{key} must be a signed integer"))
}
fn finite(args: &Value, key: &str) -> Result<f64, String> {
    args.get(key)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("{key} must be finite"))
}
fn payload(result: Value) -> Value {
    json!({"payloadJSON":result.to_string()})
}
pub fn call(method: &str, args: &Value) -> Result<Value, String> {
    let result = match method {
        "detect" => json!(detect(&decode::<Vec<DanmakuComment>>(args, "payloadJSON")?)),
        "timestamp" => json!(timestamp(text(args, "text")?)),
        "jumpTarget" => json!(jump_target(text(args, "text")?)),
        "commentFields" => {
            let (time, uid) = comment_fields(text(args, "p")?);
            json!({"time":time,"uid":uid})
        }
        "consensus" => {
            let minimum = match args.get("minimumEpisodes") {
                None => MINIMUM_EPISODES,
                Some(_) => id(args, "minimumEpisodes")?,
            };
            json!(consensus(
                &decode::<Vec<SeekEvent>>(args, "payloadJSON")?,
                minimum
            ))
        }
        "eligibleSeek" => json!(eligible_seek(finite(args, "from")?, finite(args, "to")?)),
        "confirmedHint" => json!(confirmed_hint(
            finite(args, "to")?,
            decode::<Option<IntroHint>>(args, "payloadJSON")?
        )),
        "selectIntervals" => json!(select_intervals(&decode::<Vec<Interval>>(
            args,
            "payloadJSON"
        )?)),
        "siblingHint" => json!(sibling_hint(&decode::<Vec<IntroHint>>(
            args,
            "payloadJSON"
        )?)),
        "policy" => {
            json!({"landingMin":LANDING_MIN,"landingMax":LANDING_MAX,"minimumSeekSeconds":MINIMUM_SEEK,"snapToleranceSeconds":SNAP_TOLERANCE,"minimumConsensusEpisodes":MINIMUM_EPISODES,"maxEventsPerAnime":MAX_EVENTS})
        }
        _ => return Err("unknown intro policy operation".to_owned()),
    };
    Ok(payload(result))
}

#[derive(Clone, Serialize, Deserialize)]
struct AnimeLearning {
    events: Vec<SeekEvent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    promoted: Option<IntroHint>,
}
pub struct LearningStore {
    directory: PathBuf,
    cached: Option<HashMap<String, AnimeLearning>>,
    write_failures: u64,
}
impl LearningStore {
    pub fn open(args: &Value) -> Result<Self, String> {
        let directory = PathBuf::from(text(args, "directory")?);
        if !directory.is_absolute() || directory.parent().is_none() {
            return Err("directory must be an absolute learning folder".to_owned());
        }
        let _ = fs::create_dir_all(&directory);
        Ok(Self {
            directory,
            cached: None,
            write_failures: 0,
        })
    }
    fn load(&mut self) -> &mut HashMap<String, AnimeLearning> {
        if self.cached.is_none() {
            self.cached = Some(
                fs::read(self.directory.join("learned-intros.json"))
                    .ok()
                    .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                    .unwrap_or_default(),
            )
        }
        self.cached.as_mut().unwrap()
    }
    fn save(&mut self) -> bool {
        let bytes = serde_json::to_vec(self.load()).ok();
        let saved = bytes.is_some_and(|bytes| {
            atomic_write(&self.directory.join("learned-intros.json"), &bytes).is_ok()
        });
        if !saved {
            self.write_failures = self.write_failures.saturating_add(1)
        }
        saved
    }
    pub fn call(&mut self, method: &str, args: &Value) -> Result<Value, String> {
        let result = match method {
            "record" => {
                let key = id(args, "animeID")?.to_string();
                let event: SeekEvent = decode(args, "payloadJSON")?;
                let learning = self.load().entry(key).or_insert_with(|| AnimeLearning {
                    events: vec![],
                    promoted: None,
                });
                learning.events.push(event);
                if learning.events.len() > MAX_EVENTS {
                    learning.events.drain(..learning.events.len() - MAX_EVENTS);
                }
                json!(self.save())
            }
            "promote" => {
                let key = id(args, "animeID")?.to_string();
                let hint = decode(args, "payloadJSON")?;
                self.load()
                    .entry(key)
                    .or_insert_with(|| AnimeLearning {
                        events: vec![],
                        promoted: None,
                    })
                    .promoted = Some(hint);
                json!(self.save())
            }
            "promotedHint" => {
                let key = id(args, "animeID")?.to_string();
                json!(self.load().get(&key).and_then(|v| v.promoted.clone()))
            }
            "consensusHint" => {
                let key = id(args, "animeID")?.to_string();
                let c = self
                    .load()
                    .get(&key)
                    .and_then(|v| consensus(&v.events, MINIMUM_EPISODES));
                json!(c.map(|c| IntroHint {
                    start_seconds: None,
                    end_seconds: c.end,
                    evidence_count: c.episode_count as i64,
                    source: IntroSource::Learned
                }))
            }
            "events" => {
                let key = id(args, "animeID")?.to_string();
                json!(self
                    .load()
                    .get(&key)
                    .map(|v| v.events.clone())
                    .unwrap_or_default())
            }
            "stats" => json!({"writeFailures":self.write_failures}),
            _ => return Err("unknown intro learning operation".to_owned()),
        };
        Ok(payload(result))
    }
}
