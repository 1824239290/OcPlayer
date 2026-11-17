//! Portable settings backup schema, snapshot policy and ordered restore plan.
//! Platform adapters supply preference getter facts and apply the returned effects.
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::NaiveDate;
use regex::Regex;
use serde::{
    de::{MapAccess, Visitor},
    Deserialize, Deserializer,
};
use serde_json::{json, value::RawValue, Map, Value};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub(super) type Failure = (i32, bool, String, Value);
fn invalid(message: impl Into<String>) -> Failure {
    (2702, false, message.into(), json!({"kind":"invalidFormat"}))
}
#[derive(Default)]
struct FirstObject(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for FirstObject {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct ObjectVisitor;
        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = FirstObject;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a backup object")
            }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut result = BTreeMap::new();
                while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    result.entry(key).or_insert(value);
                }
                Ok(FirstObject(result))
            }
        }
        d.deserialize_map(ObjectVisitor)
    }
}
fn object(raw: &str) -> Result<FirstObject, Failure> {
    serde_json::from_str(raw).map_err(|e| invalid(e.to_string()))
}
#[derive(Clone, Copy)]
enum Kind {
    Bool,
    Int,
    Double,
    Text,
    Color,
}
use Kind::*;
struct Field {
    name: &'static str,
    kind: Kind,
    optional: bool,
}
macro_rules! fields { ($($name:literal:$kind:ident $(? $optional:literal)?),* $(,)?) => { &[$(Field{name:$name,kind:$kind,optional:fields!(@optional $($optional)?)}),*] }; (@optional)=>{false}; (@optional $value:literal)=>{$value}; }
const TMDB: &[Field] = fields!["apiKey":Text ? true,"language":Text,"preferText":Bool,"replaceImages":Bool,"showPlaceholders":Bool,"cacheDays":Int];
const PLAYBACK: &[Field] = fields!["skipIntro":Bool,"skipOutro":Bool,"outroRetentionSeconds":Int,"subtitleLanguage":Text,"lumaUpscaler":Text,"subtitleStyleOverrides":Bool ? true,"subtitleAlignment":Int ? true,"subtitleMarginVertical":Int ? true,"subtitlePrimaryColor":Color ? true,"subtitleOutlineColor":Color ? true,"subtitleOutlineWidth":Double ? true,"subtitleBold":Bool ? true,"httpReadAheadMiB":Int,"httpBackBufferMiB":Int];
const DANMAKU: &[Field] = fields!["danmakuEnabled":Bool,"opacity":Double,"displayArea":Double,"blockTop":Bool,"blockBottom":Bool,"blockScroll":Bool,"fontSize":Double,"autoLoad":Bool,"dandanplayGatewayURL":Text ? true];
const GENERAL: &[Field] = fields!["bangumiEnabled":Bool,"moviepilotEnabled":Bool,"homeSections":Text ? true,"episodeSortAscending":Bool];
const MIRROR: &[Field] = fields!["bangumiEnabled":Bool,"bangumiRootDomain":Text ? true,"tmdbEnabled":Bool,"tmdbAPIBaseURL":Text ? true,"tmdbImageBaseURL":Text ? true];
const MODULES: [(&str, &[Field]); 5] = [
    ("tmdb", TMDB),
    ("playback", PLAYBACK),
    ("danmaku", DANMAKU),
    ("general", GENERAL),
    ("mirror", MIRROR),
];

/// Foundation accepts mathematically integral decimal/exponent forms without
/// rounding through f64, but excludes floating forms at the Int64 endpoints.
fn integer(raw: &str) -> Option<i64> {
    if !raw.contains(['.', 'e', 'E']) {
        return raw.parse().ok();
    }
    let float: f64 = raw.parse().ok()?;
    if !float.is_finite() || float <= -9223372036854775808.0 || float >= 9223372036854775808.0 {
        return None;
    }
    let negative = raw.starts_with('-');
    let unsigned = raw.trim_start_matches('-');
    let (mantissa, exponent) = unsigned.split_once(['e', 'E']).unwrap_or((unsigned, "0"));
    let exponent: i64 = exponent.parse().ok()?;
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let mut digits = format!("{whole}{fraction}");
    let scale = exponent.checked_sub(fraction.len() as i64)?;
    if scale < 0 {
        let drop = usize::try_from(scale.checked_neg()?).ok()?;
        if drop > digits.len() {
            return if digits.bytes().all(|c| c == b'0') {
                Some(0)
            } else {
                None
            };
        }
        if !digits[digits.len() - drop..].bytes().all(|c| c == b'0') {
            return None;
        }
        digits.truncate(digits.len() - drop);
    } else if scale > 20 {
        return if digits.bytes().all(|c| c == b'0') {
            Some(0)
        } else {
            None
        };
    } else {
        digits.extend(std::iter::repeat_n('0', scale as usize));
    }
    let digits = digits.trim_start_matches('0');
    if digits.is_empty() {
        return Some(0);
    }
    format!("{}{digits}", if negative { "-" } else { "" })
        .parse()
        .ok()
}
fn scalar(raw: &str, kind: Kind) -> Result<Value, Failure> {
    let error = || invalid("invalid settings scalar");
    match kind {
        Bool => serde_json::from_str::<bool>(raw)
            .map(Value::Bool)
            .map_err(|_| error()),
        Text => serde_json::from_str::<std::string::String>(raw)
            .map(Value::String)
            .map_err(|_| error()),
        Int | Color => {
            let n = integer(raw).ok_or_else(error)?;
            if matches!(kind, Color) && !(0..=u32::MAX as i64).contains(&n) {
                return Err(error());
            }
            Ok(json!(n))
        }
        Double => serde_json::from_str::<f64>(raw)
            .ok()
            .filter(|n| n.is_finite())
            .map(|n| json!(n))
            .ok_or_else(error),
    }
}
fn fields_from(
    object: &FirstObject,
    fields: &[Field],
) -> Result<Map<std::string::String, Value>, Failure> {
    let mut result = Map::new();
    for field in fields {
        let raw = object.0.get(field.name).map(|v| v.get());
        if raw.is_none() || raw == Some("null") {
            if field.optional {
                continue;
            }
            return Err(invalid(format!("missing {}", field.name)));
        }
        result.insert(field.name.into(), scalar(raw.unwrap(), field.kind)?);
    }
    Ok(result)
}
fn whitespace(c: char) -> bool {
    c.is_whitespace() || c == '\u{200b}'
}
fn trim(value: &str) -> &str {
    value.trim_matches(whitespace)
}
fn date_valid(value: &str) -> bool {
    // Foundation ISO8601 accepts variable-width components, trailing data,
    // fractional seconds and normalized day/time overflow within numeric ranges.
    let re=Regex::new(r"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}(?::?[0-9]{2})?)").unwrap();
    let Some(c) = re.captures(value) else {
        return false;
    };
    let numbers: Vec<u32> = (1..=6).map(|i| c[i].parse().unwrap()).collect();
    if !(1..=12).contains(&numbers[1]) || !(1..=31).contains(&numbers[2]) {
        return false;
    }
    if NaiveDate::from_ymd_opt(numbers[0] as i32, numbers[1], 1).is_none() {
        return false;
    }
    let zone = &c[8];
    if zone != "Z" {
        let zone = zone[1..].replace(':', "");
        let h: u32 = zone[..2].parse().unwrap();
        let m: u32 = zone
            .get(2..)
            .filter(|s| !s.is_empty())
            .unwrap_or("0")
            .parse()
            .unwrap();
        if h > 23 || m > 59 {
            return false;
        }
    }
    true
}
fn text_bytes(bytes: &[u8]) -> Result<std::string::String, Failure> {
    let mut bytes = bytes;
    let mut width = 1;
    let mut little = true;
    for (bom, w, l) in [
        (b"\x00\x00\xfe\xff".as_slice(), 4, false),
        (b"\xff\xfe\x00\x00", 4, true),
        (b"\xfe\xff", 2, false),
        (b"\xff\xfe", 2, true),
        (b"\xef\xbb\xbf", 1, true),
    ] {
        if bytes.starts_with(bom) {
            bytes = &bytes[bom.len()..];
            width = w;
            little = l;
            break;
        }
    }
    if width == 1 && bytes.len() >= 4 {
        if bytes[..3] == [0, 0, 0] {
            width = 4;
            little = false;
        } else if bytes[1..4] == [0, 0, 0] {
            width = 4;
            little = true;
        } else if bytes[0] == 0 && bytes[2] == 0 {
            width = 2;
            little = false;
        } else if bytes[1] == 0 && bytes[3] == 0 {
            width = 2;
            little = true;
        }
    }
    match width {
        1 => std::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|_| invalid("invalid UTF-8 backup")),
        2 => {
            if bytes.len() % 2 != 0 {
                return Err(invalid("invalid UTF-16 backup"));
            }
            let units: Vec<_> = bytes
                .chunks_exact(2)
                .map(|b| {
                    if little {
                        u16::from_le_bytes([b[0], b[1]])
                    } else {
                        u16::from_be_bytes([b[0], b[1]])
                    }
                })
                .collect();
            std::string::String::from_utf16(&units).map_err(|_| invalid("invalid UTF-16 backup"))
        }
        _ => {
            if bytes.len() % 4 != 0 {
                return Err(invalid("invalid UTF-32 backup"));
            }
            bytes
                .chunks_exact(4)
                .map(|b| {
                    char::from_u32(if little {
                        u32::from_le_bytes(b.try_into().unwrap())
                    } else {
                        u32::from_be_bytes(b.try_into().unwrap())
                    })
                    .ok_or_else(|| invalid("invalid UTF-32 backup"))
                })
                .collect()
        }
    }
}
fn decode(bytes: &[u8], enforce_version: bool) -> Result<Value, Failure> {
    if bytes.is_empty() {
        return Err((
            2701,
            false,
            "empty backup".into(),
            json!({"kind":"emptyData"}),
        ));
    }
    let raw = text_bytes(bytes)?;
    let root = object(&raw)?;
    let root_fields =
        fields!["formatVersion":Int,"exportedAt":Text,"appVersion":Text,"deviceName":Text ? true];
    let mut result = fields_from(&root, root_fields)?;
    if !date_valid(result["exportedAt"].as_str().unwrap()) {
        return Err(invalid("invalid ISO8601 export date"));
    }
    for (name, fields) in MODULES {
        let Some(raw) = root.0.get(name).filter(|r| r.get() != "null") else {
            continue;
        };
        let module = object(raw.get())?;
        let data = if name == "mirror" {
            // Legacy enabled is decoded even when new flags are explicit.
            let legacy = module
                .0
                .get("enabled")
                .filter(|r| r.get() != "null")
                .map(|r| scalar(r.get(), Bool))
                .transpose()?;
            let mut data = Map::new();
            for field in fields {
                if let Some(raw) = module.0.get(field.name).filter(|r| r.get() != "null") {
                    data.insert(field.name.into(), scalar(raw.get(), field.kind)?);
                } else if !field.optional {
                    data.insert(
                        field.name.into(),
                        legacy.clone().unwrap_or(Value::Bool(false)),
                    );
                }
            }
            data
        } else {
            fields_from(&module, fields)?
        };
        result.insert(name.into(), Value::Object(data));
    }
    let version = result["formatVersion"].as_i64().unwrap();
    if enforce_version && version > 1 {
        return Err((
            2703,
            false,
            "unsupported backup version".into(),
            json!({"kind":"unsupportedVersion","version":version}),
        ));
    }
    Ok(Value::Object(result))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecodeInput {
    input_base64: std::string::String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Fact {
    present: bool,
    value: Value,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    preferences: BTreeMap<std::string::String, Fact>,
    tmdb: Value,
    exported_at: std::string::String,
    app_version: std::string::String,
    device_name: Option<std::string::String>,
    #[serde(rename = "dandanplayGatewayURL")]
    dandanplay_gateway_url: Option<std::string::String>,
}
fn chosen(snapshot: &Snapshot, path: &str, fallback: Value) -> Value {
    snapshot
        .preferences
        .get(path)
        .filter(|f| f.present)
        .map(|f| f.value.clone())
        .unwrap_or(fallback)
}
fn snapshot(input: Snapshot) -> Result<Value, Failure> {
    let mut root = json!({"formatVersion":1,"exportedAt":input.exported_at,"appVersion":input.app_version,"tmdb":input.tmdb});
    if let Some(name) = input.device_name.as_ref() {
        root["deviceName"] = json!(name);
    }
    let mut playback = Map::new();
    let mut danmaku = Map::new();
    let mut general = Map::new();
    let mut mirror = Map::new();
    for (name, target, fields) in [
        ("playback", &mut playback, PLAYBACK),
        ("danmaku", &mut danmaku, DANMAKU),
        ("general", &mut general, GENERAL),
        ("mirror", &mut mirror, MIRROR),
    ] {
        for field in fields {
            let fallback = match (name, field.name) {
                ("playback", "skipIntro" | "skipOutro")
                | ("danmaku", "danmakuEnabled" | "autoLoad")
                | ("general", "bangumiEnabled" | "moviepilotEnabled" | "episodeSortAscending") => {
                    json!(true)
                }
                ("playback", "outroRetentionSeconds") => json!(10),
                ("playback", "subtitleLanguage") => json!("zh-Hans"),
                ("playback", "lumaUpscaler") => json!("off"),
                ("playback", "httpReadAheadMiB" | "httpBackBufferMiB") => json!(0),
                ("danmaku", "opacity") => json!(0.85),
                ("danmaku", "displayArea") => json!(0.75),
                ("danmaku", "fontSize") => json!(22.0),
                (_, _) if field.optional => Value::Null,
                (_, _) => json!(false),
            };
            let mut value = chosen(&input, &format!("{name}.{}", field.name), fallback.clone());
            if name == "playback" {
                if field.name == "outroRetentionSeconds"
                    && ![0, 5, 10, 15, 20, 30]
                        .iter()
                        .any(|n| value.as_i64() == Some(*n))
                {
                    value = fallback.clone();
                }
                if field.name == "subtitleLanguage"
                    && !["zh-Hans", "zh-Hant", "followSource", "off"]
                        .iter()
                        .any(|s| value.as_str() == Some(*s))
                {
                    value = fallback.clone();
                }
                if field.name == "lumaUpscaler"
                    && !["off", "artCnnC4F16", "artCnnC4F32", "artCnnC4F16Ds"]
                        .iter()
                        .any(|s| value.as_str() == Some(*s))
                {
                    value = fallback.clone();
                }
                if matches!(field.kind, Color)
                    && !value
                        .as_i64()
                        .is_some_and(|n| n > 0 && n <= u32::MAX as i64)
                {
                    value = Value::Null;
                }
            }
            if name == "mirror" {
                if matches!(field.kind, Bool) && !value.is_boolean() {
                    value = json!(false);
                }
                if let Some(s) = value.as_str() {
                    let s = trim(s);
                    value = if s.is_empty() { Value::Null } else { json!(s) };
                }
            }
            if field.name == "dandanplayGatewayURL" {
                value = input
                    .dandanplay_gateway_url
                    .as_ref()
                    .filter(|s| !s.is_empty())
                    .map_or(Value::Null, |s| json!(s));
            }
            if !value.is_null() {
                target.insert(field.name.into(), value);
            }
        }
    }
    root["playback"] = Value::Object(playback);
    root["danmaku"] = Value::Object(danmaku);
    root["general"] = Value::Object(general);
    root["mirror"] = Value::Object(mirror);
    decode(serde_json::to_string(&root).unwrap().as_bytes(), true)
}
fn summary(backup: &Value) -> Value {
    let key = backup["tmdb"]["apiKey"].as_str().unwrap_or("");
    let graphemes: Vec<_> = key.graphemes(true).collect();
    json!({"hasTMDb":!key.is_empty(),"tmdbKeyTail":if key.is_empty(){None}else{Some(format!("••••{}",graphemes[graphemes.len().saturating_sub(4)..].concat()))},"tmdbLanguage":backup["tmdb"]["language"],"hasPlayback":backup.get("playback").is_some(),"hasDanmaku":backup.get("danmaku").is_some(),"hasGeneral":backup.get("general").is_some(),"hasMirror":backup.get("mirror").is_some(),"deviceName":backup["deviceName"]})
}
fn restore(backup: &Value) -> Value {
    let mut effects = Vec::new();
    for (name, fields) in [
        ("tmdb", TMDB),
        ("playback", PLAYBACK),
        ("danmaku", DANMAKU),
        ("mirror", MIRROR),
        ("general", GENERAL),
    ] {
        let Some(module) = backup.get(name) else {
            continue;
        };
        let mut fields: Vec<_> = fields.iter().collect();
        if name == "playback" {
            let order = [
                "skipIntro",
                "skipOutro",
                "outroRetentionSeconds",
                "subtitleLanguage",
                "lumaUpscaler",
                "httpReadAheadMiB",
                "httpBackBufferMiB",
                "subtitleStyleOverrides",
                "subtitleAlignment",
                "subtitleMarginVertical",
                "subtitlePrimaryColor",
                "subtitleOutlineColor",
                "subtitleOutlineWidth",
                "subtitleBold",
            ];
            fields.sort_by_key(|f| order.iter().position(|name| *name == f.name));
        } else if name == "general" {
            let order = [
                "bangumiEnabled",
                "moviepilotEnabled",
                "episodeSortAscending",
                "homeSections",
            ];
            fields.sort_by_key(|f| order.iter().position(|name| *name == f.name));
        }
        for field in fields {
            let value = module.get(field.name).cloned().unwrap_or(Value::Null);
            let remove = name == "mirror"
                && field.optional
                && value.as_str().is_none_or(|s| trim(s).is_empty());
            if !remove && value.is_null() {
                continue;
            }
            if (name == "tmdb" && field.name == "apiKey"
                || name == "danmaku" && field.name == "dandanplayGatewayURL"
                || name == "general" && field.name == "homeSections")
                && value.as_str() == Some("")
            {
                continue;
            }
            if name == "playback"
                && field.name == "subtitleLanguage"
                && !["zh-Hans", "zh-Hant", "followSource", "off"]
                    .iter()
                    .any(|s| value.as_str() == Some(*s))
            {
                continue;
            }
            if name == "playback"
                && field.name == "lumaUpscaler"
                && !["off", "artCnnC4F16", "artCnnC4F32", "artCnnC4F16Ds"]
                    .iter()
                    .any(|s| value.as_str() == Some(*s))
            {
                continue;
            }
            effects.push(json!({"target":if name=="tmdb"{"tmdb"}else if name=="danmaku" && field.name=="dandanplayGatewayURL"{"dandanplay"}else{"preferences"},"field":format!("{name}.{}",field.name),"operation":if remove{"remove"}else{"set"},"valueJSON":serde_json::to_string(&value).unwrap()}));
        }
    }
    json!(effects)
}
pub(super) fn call(method: &str, args: Value) -> Result<Value, Failure> {
    if method == "settings.backup.capabilities" {
        return Ok(
            json!({"schemaVersion":1,"formatVersion":1,"modules":["tmdb","playback","danmaku","general","mirror"]}),
        );
    }
    let backup = if method == "settings.backup.snapshot" {
        let input = serde_json::from_value::<Snapshot>(args).map_err(|e| invalid(e.to_string()))?;
        snapshot(input)?
    } else {
        let input =
            serde_json::from_value::<DecodeInput>(args).map_err(|e| invalid(e.to_string()))?;
        decode(
            &STANDARD
                .decode(input.input_base64)
                .map_err(|_| invalid("invalid backup byte encoding"))?,
            method == "settings.backup.decode",
        )?
    };
    Ok(
        json!({"backupJSON":serde_json::to_string(&backup).unwrap(),"summary":summary(&backup),"effects":restore(&backup)}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn basic() -> Value {
        json!({"formatVersion":1,"exportedAt":"2026-11-14T00:00:00Z","appVersion":"fixture"})
    }
    fn read(value: &Value) -> Value {
        decode(serde_json::to_string(value).unwrap().as_bytes(), true).unwrap()
    }
    #[test]
    fn native_integral_decimal_forms_keep_exact_digits() {
        for (raw, expected) in [
            ("1.0", 1),
            ("1e0", 1),
            ("9.9e4", 99000),
            ("9007199254740993.0", 9007199254740993),
            ("9223372036854775807", i64::MAX),
            ("-9223372036854775808", i64::MIN),
        ] {
            assert_eq!(integer(raw), Some(expected), "{raw}");
        }
        for raw in [
            "1.5",
            "9223372036854775807.0",
            "-9223372036854775808.0",
            "1e100",
            "true",
            "\"1\"",
        ] {
            assert_eq!(integer(raw), None, "{raw}");
        }
    }
    #[test]
    fn duplicate_keys_are_first_wins_in_root_and_nested_objects() {
        let value=decode(br#"{"formatVersion":1,"formatVersion":2,"exportedAt":"2026-11-14T00:00:00Z","appVersion":"fixture","mirror":{"enabled":true,"enabled":false}}"#,true).unwrap();
        assert_eq!(value["formatVersion"], 1);
        assert_eq!(value["mirror"]["tmdbEnabled"], true);
    }
    #[test]
    fn legacy_mirror_and_null_modules_keep_restore_semantics() {
        let mut value = basic();
        value["mirror"] = json!({"enabled":true,"tmdbEnabled":false});
        value["playback"] = Value::Null;
        let value = read(&value);
        assert!(value.get("playback").is_none());
        assert_eq!(value["mirror"]["bangumiEnabled"], true);
        assert_eq!(restore(&value).as_array().unwrap().len(), 5);
        let mut bad = basic();
        bad["mirror"] = json!({"enabled":"bad","tmdbEnabled":false});
        assert_eq!(
            decode(serde_json::to_string(&bad).unwrap().as_bytes(), true)
                .unwrap_err()
                .0,
            2702
        );
    }
    #[test]
    fn only_file_decode_gates_newer_versions_after_schema_validation() {
        let mut value = basic();
        value["formatVersion"] = json!(2);
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(decode(&bytes, false).is_ok());
        assert_eq!(decode(&bytes, true).unwrap_err().0, 2703);
        value["mirror"] = json!({"tmdbEnabled":"bad"});
        assert_eq!(
            decode(serde_json::to_vec(&value).unwrap().as_slice(), true)
                .unwrap_err()
                .0,
            2702
        );
        assert_eq!(decode(b"", true).unwrap_err().0, 2701);
    }
    #[test]
    fn utf16_utf32_bom_and_unmarked_encodings_match_utf8() {
        let raw = serde_json::to_string(&basic()).unwrap();
        let expected = read(&basic());
        for little in [false, true] {
            let utf16: Vec<_> = raw
                .encode_utf16()
                .flat_map(|n| {
                    if little {
                        n.to_le_bytes()
                    } else {
                        n.to_be_bytes()
                    }
                })
                .collect();
            let utf32: Vec<_> = raw
                .chars()
                .flat_map(|n| {
                    if little {
                        (n as u32).to_le_bytes()
                    } else {
                        (n as u32).to_be_bytes()
                    }
                })
                .collect();
            assert_eq!(decode(&utf16, true).unwrap(), expected);
            assert_eq!(decode(&utf32, true).unwrap(), expected);
        }
        assert!(decode(&[0xff, 0xfe, 0xd8], true).is_err());
    }
    #[test]
    fn foundation_iso_date_forms_preserve_normalization_and_trailing_text() {
        for value in [
            "2026-02-30T00:00:00Z",
            "2026-1-1T0:0:0Z",
            "2026-01-01T25:61:61Z",
            "2026-01-01T00:00:00.123Z",
            "2026-01-01T00:00:00+08",
            "2026-01-01T00:00:00Zextra",
            "0000-01-01T00:00:00Z",
        ] {
            assert!(date_valid(value), "{value}");
        }
        for value in [
            "2026-00-01T00:00:00Z",
            "2026-01-00T00:00:00Z",
            "2026-01-32T00:00:00Z",
            "2026-01-01T00:00:00+25:99",
            "2026-01-01",
            "٢٠٢٦-01-01T00:00:00Z",
        ] {
            assert!(!date_valid(value), "{value}");
        }
    }
    #[test]
    fn summary_masks_extended_graphemes_and_counts_key_presence() {
        let mut value = basic();
        value["tmdb"] = json!({"apiKey":"prefix-a👩‍👩‍👧‍👦🇨🇳e\u{301}z"});
        assert_eq!(summary(&value)["tmdbKeyTail"], "••••👩‍👩‍👧‍👦🇨🇳e\u{301}z");
        value["tmdb"]["apiKey"] = json!("");
        assert_eq!(summary(&value)["hasTMDb"], false);
    }
    #[test]
    fn restore_never_clears_empty_credentials_or_absent_style() {
        let value = json!({"tmdb":{"apiKey":"","language":"zh-CN"},"playback":{"skipIntro":false,"subtitleBold":false},"mirror":{"bangumiEnabled":false,"tmdbEnabled":false},"general":{"homeSections":""}});
        let effects = restore(&value);
        let effects = effects.as_array().unwrap();
        assert!(!effects
            .iter()
            .any(|e| e["field"] == "tmdb.apiKey" || e["field"] == "general.homeSections"));
        assert!(effects
            .iter()
            .any(|e| e["field"] == "playback.subtitleBold" && e["valueJSON"] == "false"));
        assert_eq!(
            effects
                .iter()
                .filter(|e| e["operation"] == "remove")
                .count(),
            3
        );
    }
}
