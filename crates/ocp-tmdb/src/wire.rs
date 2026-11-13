//! Foundation JSONObject-compatible bytes and numeric field decoding.
use serde_json::Value;

pub fn decode(bytes: &[u8]) -> Result<Value, String> {
    // JSONSerialization accepts big-endian UTF-32 BOMs, but rejects little-endian
    // UTF-32 BOMs on the reference runtime. Unmarked UTF-32 works in both orders.
    if bytes.starts_with(&[0xff, 0xfe, 0, 0]) {
        return Err("UTF-32 little-endian BOM is not accepted by the native parser".into());
    }
    let (width, big, bytes) = if bytes.starts_with(&[0, 0, 0xfe, 0xff]) {
        (4, true, &bytes[4..])
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        (2, true, &bytes[2..])
    } else if bytes.starts_with(&[0xff, 0xfe]) {
        (2, false, &bytes[2..])
    } else if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        (1, true, &bytes[3..])
    } else if bytes.len() >= 4 && bytes[..3] == [0, 0, 0] {
        (4, true, bytes)
    } else if bytes.len() >= 4 && bytes[1..4] == [0, 0, 0] {
        (4, false, bytes)
    } else if bytes.len() >= 4 && bytes[0] == 0 && bytes[2] == 0 {
        (2, true, bytes)
    } else if bytes.len() >= 4 && bytes[1] == 0 && bytes[3] == 0 {
        (2, false, bytes)
    } else {
        (1, true, bytes)
    };
    let text = match width {
        1 => std::str::from_utf8(bytes)
            .map_err(|e| e.to_string())?
            .to_owned(),
        2 if bytes.len() % 2 == 0 => char::decode_utf16(bytes.chunks_exact(2).map(|b| {
            if big {
                u16::from_be_bytes([b[0], b[1]])
            } else {
                u16::from_le_bytes([b[0], b[1]])
            }
        }))
        .collect::<Result<String, _>>()
        .map_err(|e| e.to_string())?,
        4 if bytes.len() % 4 == 0 => bytes
            .chunks_exact(4)
            .map(|b| {
                let code = if big {
                    u32::from_be_bytes(b.try_into().unwrap())
                } else {
                    u32::from_le_bytes(b.try_into().unwrap())
                };
                char::from_u32(code).ok_or_else(|| "invalid Unicode scalar".to_owned())
            })
            .collect::<Result<String, _>>()?,
        _ => return Err("incomplete Unicode code unit".into()),
    };
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub fn integer(value: &Value) -> Option<i64> {
    if let Some(value) = value.as_i64() {
        return Some(value);
    }
    if let Some(value) = value.as_bool() {
        return Some(i64::from(value));
    }
    let number = number(value)?;
    // Native Int(Double) truncates fractional values. Avoid its trap for corrupt
    // out-of-range server values while preserving every representable Int.
    (number.is_finite() && number >= -9223372036854775808.0 && number < 9223372036854775808.0)
        .then_some(number.trunc() as i64)
}
pub fn number(value: &Value) -> Option<f64> {
    if let Some(value) = value.as_bool() {
        return Some(if value { 1.0 } else { 0.0 });
    }
    if let Some(value) = value.as_i64() {
        return Some(value as f64);
    }
    if let Some(value) = value.as_u64() {
        let double = value as f64;
        return (double < 18446744073709551616.0 && double as u64 == value).then_some(double);
    }
    value.as_f64().filter(|value| value.is_finite())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_integer_fields_accept_booleans_and_truncate_without_narrowing() {
        for (value, expected) in [
            (serde_json::json!(true), 1),
            (serde_json::json!(false), 0),
            (serde_json::json!(7.9), 7),
            (serde_json::json!(-7.9), -7),
            (serde_json::json!(i64::MAX), i64::MAX),
        ] {
            assert_eq!(integer(&value), Some(expected));
        }
        assert_eq!(integer(&serde_json::json!(u64::MAX)), None);
        assert_eq!(number(&serde_json::json!(u64::MAX)), None);
    }
    #[test]
    fn native_encodings_keep_exact_ids_and_bom_policy() {
        let text = "{\"id\":9223372036854775807,\"name\":\"中文😀\"}";
        let expected: Value = serde_json::from_str(text).unwrap();
        assert_eq!(decode(text.as_bytes()).unwrap(), expected);
        for big in [false, true] {
            let bytes: Vec<_> = text
                .encode_utf16()
                .flat_map(|c| {
                    if big {
                        c.to_be_bytes()
                    } else {
                        c.to_le_bytes()
                    }
                })
                .collect();
            assert_eq!(decode(&bytes).unwrap(), expected);
            let bytes: Vec<_> = text
                .chars()
                .flat_map(|c| {
                    if big {
                        (c as u32).to_be_bytes()
                    } else {
                        (c as u32).to_le_bytes()
                    }
                })
                .collect();
            assert_eq!(decode(&bytes).unwrap(), expected);
        }
        assert!(decode(&[0xff, 0xfe, 0, 0]).is_err());
        assert!(decode(b"{\"id\":7,\"ignored\":\"\xff\"}").is_err());
    }
}
