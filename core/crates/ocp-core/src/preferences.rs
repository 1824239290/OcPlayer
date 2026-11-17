//! Native persistence supplies cast facts; Core owns runtime defaults and ranges.
use serde_json::{json, Value};

#[derive(Clone, Copy)]
enum Rule {
    Bool(bool),
    OptionalBool,
    Float(f64, f64, f64),
    Width,
    Int(i64, i64),
    Color,
    Choice(&'static [&'static str], &'static str),
    Options(&'static [i64], i64),
}
const RULES: &[(&str, Rule)] = &[
    ("playback.rate", Rule::Float(0.5, 2.0, 1.0)),
    ("playback.volume", Rule::Float(0.0, 1.0, 1.0)),
    ("playback.muted", Rule::Bool(false)),
    ("playback.subtitleScale", Rule::Float(0.5, 3.0, 1.0)),
    (
        "playback.subtitleLanguage",
        Rule::Choice(&["zh-Hans", "zh-Hant", "followSource", "off"], "zh-Hans"),
    ),
    (
        "playback.lumaUpscaler",
        Rule::Choice(
            &["off", "artCnnC4F16", "artCnnC4F32", "artCnnC4F16Ds"],
            "off",
        ),
    ),
    ("playback.subtitleAlignment", Rule::Int(0, 9)),
    ("playback.subtitleMarginVertical", Rule::Int(0, 200)),
    ("playback.subtitlePrimaryColor", Rule::Color),
    ("playback.subtitleOutlineColor", Rule::Color),
    ("playback.subtitleOutlineWidth", Rule::Width),
    ("playback.subtitleBold", Rule::OptionalBool),
    ("playback.subtitleStyleOverrides", Rule::Bool(false)),
    (
        "playback.httpReadAheadMiB",
        Rule::Options(&[0, 8, 16, 32], 0),
    ),
    (
        "playback.httpBackBufferMiB",
        Rule::Options(&[0, 32, 64, 128], 0),
    ),
    ("playback.skipIntro", Rule::Bool(true)),
    ("playback.skipOutro", Rule::Bool(true)),
    (
        "playback.outroRetentionSeconds",
        Rule::Options(&[0, 5, 10, 15, 20, 30], 10),
    ),
    ("danmaku.useOverlayRenderer", Rule::Bool(false)),
    ("danmaku.enabled", Rule::Bool(true)),
    ("danmaku.opacity", Rule::Float(0.25, 1.0, 0.85)),
    ("danmaku.displayArea", Rule::Float(0.25, 1.0, 0.75)),
    ("danmaku.blockTop", Rule::Bool(false)),
    ("danmaku.blockBottom", Rule::Bool(false)),
    ("danmaku.blockScroll", Rule::Bool(false)),
    ("danmaku.mergeDuplicates", Rule::Bool(false)),
    ("danmaku.allowStacking", Rule::Bool(false)),
    ("danmaku.fontSize", Rule::Float(11.0, 44.0, 22.0)),
    ("danmaku.diagnostics", Rule::Bool(false)),
];
impl Rule {
    fn resolve(self, present: bool, value: &Value) -> Value {
        match self {
            Self::Bool(default) => json!(if present {
                value.as_bool().unwrap_or(false)
            } else {
                default
            }),
            Self::OptionalBool => {
                if present {
                    json!(value.as_bool().unwrap_or(false))
                } else {
                    Value::Null
                }
            }
            Self::Float(low, high, default) => {
                if !present {
                    return json!(default);
                }
                match value.as_str() {
                    Some("nan") => json!("nan"),
                    Some("infinity") => json!(high),
                    Some("-infinity") => json!(low),
                    _ => json!(value.as_f64().unwrap_or(0.0).clamp(low, high)),
                }
            }
            Self::Width => json!(if present {
                value
                    .as_f64()
                    .filter(|v| v.is_finite() && (0.0..=32.0).contains(v))
                    .unwrap_or(0.0)
            } else {
                0.0
            }),
            Self::Int(low, high) => json!(if present {
                value
                    .as_i64()
                    .filter(|v| (low..=high).contains(v))
                    .unwrap_or(0)
            } else {
                0
            }),
            Self::Color => {
                if present {
                    value
                        .as_i64()
                        .filter(|v| *v > 0 && *v <= u32::MAX as i64)
                        .map_or(Value::Null, |v| json!(v))
                } else {
                    Value::Null
                }
            }
            Self::Choice(choices, default) => json!(if present {
                value
                    .as_str()
                    .filter(|v| choices.contains(v))
                    .unwrap_or(default)
            } else {
                default
            }),
            Self::Options(choices, default) => json!(if present {
                value
                    .as_i64()
                    .filter(|v| choices.contains(v))
                    .unwrap_or(default)
            } else {
                default
            }),
        }
    }
}
pub(crate) fn call(method: &str, args: &Value) -> Result<Value, String> {
    if method == "preferences.schema" {
        return Ok(
            json!({"schemaVersion":1,"keys":RULES.iter().map(|(key, rule)| json!({"key":key,"default":rule.resolve(false, &Value::Null)})).collect::<Vec<_>>()}),
        );
    }
    let key = args["key"].as_str().ok_or("preference key required")?;
    let present = args["present"].as_bool().ok_or("present must be boolean")?;
    let value = args.get("value").ok_or("value fact required")?;
    let rule = RULES
        .iter()
        .find(|(name, _)| *name == key)
        .ok_or("unknown preference key")?
        .1;
    Ok(json!({"value":rule.resolve(present, value)}))
}
