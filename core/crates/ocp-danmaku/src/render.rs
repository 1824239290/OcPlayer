//! Production overlay/Erika payload conversion, retaining the native wire rules.
use crate::{cache::IntroHint, identity::trim, intro, providers::ProviderError, DanmakuComment};
use serde::Serialize;
use serde_json::{json, Value};

#[derive(Clone, Serialize)]
pub struct Entry {
    pub time: f64,
    pub mode: &'static str,
    pub color: u32,
    pub text: String,
}
#[derive(Serialize)]
struct ErikaItem {
    time: f64,
    #[serde(rename = "type")]
    mode: i64,
    color: i64,
    content: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Payload {
    pub entries: Option<Vec<Entry>>,
    pub json: Option<String>,
    pub comment_count: usize,
    pub detected_intro_hint: Option<IntroHint>,
}
pub fn render(
    comments: &[DanmakuComment],
    format: &str,
    detecting_intro: bool,
) -> Result<Payload, ProviderError> {
    if !matches!(format, "overlay" | "kernelTrack" | "both") {
        return Err(ProviderError::Request("invalid payload format".into()));
    }
    let fields: Vec<_> = comments
        .iter()
        .filter_map(|comment| {
            // The reference converter splits ASCII comma bytes, including combining suffixes.
            let mut parts = comment.p.split(',');
            let time = intro::swift_double(parts.next()?)?;
            let mode = parts.next()?.parse::<i64>().ok()?;
            let color = parts.next()?.parse::<i64>().ok()?;
            (time >= 0.0
                && matches!(mode, 1 | 4 | 5)
                && (0..=0xff_ffff).contains(&color)
                && !trim(&comment.m).is_empty())
            .then_some((time, mode, color, &comment.m))
        })
        .collect();
    let entries = if format == "kernelTrack" || fields.is_empty() {
        None
    } else {
        let mut entries: Vec<_> = fields
            .iter()
            .map(|(time, mode, color, text)| Entry {
                time: *time,
                mode: match mode {
                    5 => "top",
                    4 => "bottom",
                    _ => "scroll",
                },
                color: *color as u32,
                text: (*text).clone(),
            })
            .collect();
        entries.sort_by(|a, b| a.time.partial_cmp(&b.time).unwrap());
        Some(entries)
    };
    let json = if format == "overlay" || fields.is_empty() {
        None
    } else {
        let comments: Vec<_> = fields
            .iter()
            .map(|(time, mode, color, text)| ErikaItem {
                time: *time,
                mode: *mode,
                color: *color,
                content: (*text).clone(),
            })
            .collect();
        Some(
            serde_json::to_string(&json!({"comments":comments}))
                .map_err(|e| ProviderError::Decode(e.to_string()))?,
        )
    };
    Ok(Payload {
        entries,
        json,
        comment_count: comments.len(),
        detected_intro_hint: detecting_intro.then(|| intro::detect(comments)).flatten(),
    })
}
pub fn call(args: &Value) -> Result<Value, ProviderError> {
    let raw = args
        .get("payloadJSON")
        .and_then(Value::as_str)
        .ok_or_else(|| ProviderError::Request("payloadJSON required".into()))?;
    let comments: Option<Vec<DanmakuComment>> =
        serde_json::from_str(raw).map_err(|e| ProviderError::Request(e.to_string()))?;
    let format = args.get("format").and_then(Value::as_str).unwrap_or("both");
    let detecting = crate::identity::boolean(args, "detectingIntro", true)?;
    crate::providers::payload(render(&comments.unwrap_or_default(), format, detecting)?)
}
