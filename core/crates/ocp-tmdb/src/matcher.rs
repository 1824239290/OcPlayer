//! Native TMDbMatcher decisions. Network effects stay injectable in the host.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[path = "matcher_unicode.rs"]
mod unicode;
pub const AUTO_APPLY_THRESHOLD: f64 = 0.85;

fn contains(ranges: &[(u32, u32)], c: char) -> bool {
    let value = c as u32;
    let index = ranges.partition_point(|(_, high)| *high < value);
    ranges.get(index).is_some_and(|(low, _)| *low <= value)
}
fn transform(c: char, table: &[(u32, &[u32])], output: &mut String) {
    if let Ok(index) = table.binary_search_by_key(&(c as u32), |(key, _)| *key) {
        for scalar in table[index].1 {
            output.push(char::from_u32(*scalar).expect("generated scalar"));
        }
    } else {
        output.push(c);
    }
}
pub fn normalize(raw: Option<&str>) -> String {
    let mut lower = String::new();
    for c in raw.unwrap_or_default().chars() {
        transform(c, unicode::LOWER, &mut lower);
    }
    let mut half = String::new();
    for c in lower.chars() {
        transform(c, unicode::WIDTH, &mut half);
    }
    let mut text: String = half
        .chars()
        .filter(|c| !contains(unicode::EXCLUDED, *c))
        .collect();
    // These patterns are applied sequentially, exactly as in String.range.
    for (prefix, suffix) in [
        ("第", "季"),
        ("season", ""),
        ("", "ndseason"),
        ("", "rdseason"),
        ("", "thseason"),
    ] {
        if let Some(head) = text.strip_suffix(suffix) {
            let digit_start = head
                .grapheme_indices(true)
                .rev()
                .take_while(|(_, cluster)| {
                    cluster
                        .chars()
                        .next()
                        .is_some_and(|c| contains(unicode::NUMERIC, c))
                })
                .last()
                .map(|(i, _)| i);
            if let Some(start) = digit_start {
                if let Some(remaining) = head[..start].strip_suffix(prefix) {
                    text.truncate(remaining.len());
                }
            }
        }
    }
    text
}
pub fn year(raw: Option<&str>) -> Option<i64> {
    let chars: Vec<&str> = raw?.graphemes(true).collect();
    for window in chars.windows(6) {
        if matches!(window[0], "(" | "（")
            && matches!(window[5], ")" | "）")
            && window[1..5].iter().all(|cluster| {
                cluster
                    .chars()
                    .next()
                    .is_some_and(|c| contains(unicode::NUMERIC, c))
            })
        {
            // Native chooses the first regex match before attempting Int.
            let digits = window[1..5].concat();
            return digits
                .parse::<i64>()
                .ok()
                .filter(|v| (1900..=2100).contains(v));
        }
    }
    None
}
pub fn provider_id(raw: Option<&str>) -> Option<i64> {
    trim(raw?).parse().ok().filter(|v| *v > 0)
}
pub fn trim(raw: &str) -> &str {
    raw.trim_matches(|c| contains(unicode::TRIMMING, c))
}

#[derive(Clone, Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub name: String,
    pub kind: String,
    pub year: Option<i64>,
    pub original_title: Option<String>,
    #[serde(rename = "tmdbID", alias = "tmdbId")]
    pub tmdb_id: Option<String>,
    pub season_number: Option<i64>,
    pub series_name: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub entity_key: String,
    pub source: String,
    pub confidence: f64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub id: i64,
    pub media_type: String,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub year: Option<i64>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub popularity: Option<f64>,
    // Preserve native manual-panel fields, including future unknown fields.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Match {
    pub entity_key: String,
    pub source: String,
    pub confidence: f64,
    pub matched_title: Option<String>,
    pub alternatives: Vec<Candidate>,
    pub should_apply_automatically: bool,
}
fn matched(key: String, source: String, confidence: f64, title: Option<String>) -> Match {
    Match {
        entity_key: key,
        source,
        confidence,
        matched_title: title,
        alternatives: vec![],
        should_apply_automatically: confidence >= AUTO_APPLY_THRESHOLD,
    }
}
fn includes(text: &str, pattern: &str) -> bool {
    let pattern: Vec<_> = pattern.graphemes(true).collect();
    if pattern.is_empty() {
        return true;
    }
    let text: Vec<_> = text.graphemes(true).collect();
    text.windows(pattern.len()).any(|window| window == pattern)
}
pub fn score(candidate: &Candidate, item: &Item) -> f64 {
    // Swift String equality/substring matching uses canonical equivalence.
    let target: String = normalize(Some(&item.name)).nfc().collect();
    let title: String = normalize(candidate.title.as_deref()).nfc().collect();
    let original: String = normalize(candidate.original_title.as_deref())
        .nfc()
        .collect();
    let target_original: String = normalize(item.original_title.as_deref()).nfc().collect();
    let exact = !target.is_empty()
        && (title == target
            || original == target
            || (!target_original.is_empty()
                && (target_original == title || target_original == original)));
    let loose = !target.is_empty()
        && !exact
        && ((!title.is_empty() && (includes(&title, &target) || includes(&target, &title)))
            || (!original.is_empty() && includes(&original, &target)));
    if !exact && !loose {
        return 0.1;
    }
    // The title-derived year filters searches only; it never becomes item.year.
    let relation = match item.year.zip(candidate.year) {
        None => 2,
        Some((a, b)) if a == b => 0,
        Some((a, b)) if a.abs_diff(b) <= 1 => 1,
        _ => 3,
    };
    if exact {
        [0.95, 0.8, 0.7, 0.4][relation]
    } else {
        [0.6, 0.5, 0.3, 0.1][relation]
    }
}
pub fn rank(item: &Item, candidates: &[Candidate]) -> Option<Match> {
    let mut ranked: Vec<_> = candidates
        .iter()
        .map(|candidate| (candidate, score(candidate, item)))
        .collect();
    // Swift.sorted is stable, retaining primary/fallback order and duplicates.
    ranked.sort_by(|(_, a), (_, b)| b.total_cmp(a));
    let (best, confidence) = *ranked.first()?;
    let mut result = matched(
        format!(
            "{}/{}",
            if best.media_type == "movie" {
                "movie"
            } else {
                "tv"
            },
            best.id
        ),
        "search".into(),
        confidence,
        best.title.clone(),
    );
    result.alternatives = ranked
        .into_iter()
        .skip(1)
        .take(5)
        .map(|(c, _)| c.clone())
        .collect();
    Some(result)
}
pub fn invoke(args: &Value) -> Result<Value, String> {
    let operation = match args.get("operation") {
        None => "initial",
        Some(value) => value.as_str().ok_or("operation must be a string")?,
    };
    if operation == "normalize" {
        let values: Vec<Option<String>> =
            serde_json::from_value(args.get("titles").cloned().unwrap_or(Value::Null))
                .map_err(|e| e.to_string())?;
        return Ok(
            json!({"normalized": values.iter().map(|v| normalize(v.as_deref())).collect::<Vec<_>>(), "years": values.iter().map(|v| year(v.as_deref())).collect::<Vec<_>>()}),
        );
    }
    let item: Item = serde_json::from_value(args.get("item").cloned().unwrap_or(Value::Null))
        .map_err(|e| e.to_string())?;
    if ![
        "movie",
        "series",
        "season",
        "episode",
        "boxSet",
        "musicAlbum",
        "musicArtist",
        "audio",
        "book",
        "photo",
        "folder",
        "playlist",
        "other",
    ]
    .contains(&item.kind.as_str())
    {
        return Err("invalid media item kind".into());
    }
    match operation {
        "providerID" => Ok(json!({"id": provider_id(item.tmdb_id.as_deref())})),
        "initial" => {
            let link: Option<Link> =
                serde_json::from_value(args.get("seriesLink").cloned().unwrap_or(Value::Null))
                    .map_err(|e| e.to_string())?;
            if let Some(link) = &link {
                let parts: Vec<_> = link
                    .entity_key
                    .split('/')
                    .filter(|p| !p.is_empty())
                    .collect();
                let valid_key = match parts.as_slice() {
                    [kind, id] => {
                        ["movie", "tv", "collection"].contains(kind) && id.parse::<i64>().is_ok()
                    }
                    ["tv", id, "season", number] => {
                        id.parse::<i64>().is_ok() && number.parse::<i64>().is_ok()
                    }
                    _ => false,
                };
                if !valid_key || !["providerID", "search", "manual"].contains(&link.source.as_str())
                {
                    return Err("invalid series link".into());
                }
            }
            let allow_search = match args.get("allowSearch") {
                None => true,
                Some(v) => v.as_bool().ok_or("allowSearch must be boolean")?,
            };
            let mut result = None;
            let mut search = None;
            match item.kind.as_str() {
                "season" | "episode" => {
                    if let Some((link, season)) = link.zip(item.season_number) {
                        let parts: Vec<_> = link
                            .entity_key
                            .split('/')
                            .filter(|p| !p.is_empty())
                            .collect();
                        if parts.len() == 2 && parts[0] == "tv" {
                            if let Ok(id) = parts[1].parse::<i64>() {
                                result = Some(matched(
                                    format!("tv/{id}/season/{season}"),
                                    link.source,
                                    link.confidence,
                                    item.series_name.clone(),
                                ));
                            }
                        }
                    }
                }
                "movie" | "series" => {
                    if let Some(id) = provider_id(item.tmdb_id.as_deref()) {
                        result = Some(matched(
                            format!("{}/{id}", if item.kind == "movie" { "movie" } else { "tv" }),
                            "providerID".into(),
                            1.0,
                            Some(item.name.clone()),
                        ));
                    } else if allow_search {
                        search = Some(
                            json!({"query": item.name, "mediaType": if item.kind == "movie" { "movie" } else { "tv" }, "year": item.year.or_else(|| year(Some(&item.name)))}),
                        );
                    }
                }
                _ => {}
            }
            Ok(json!({"match": result, "search": search}))
        }
        "rank" | "score" => {
            let candidates: Vec<Candidate> =
                serde_json::from_value(args.get("candidates").cloned().unwrap_or(Value::Null))
                    .map_err(|e| e.to_string())?;
            if candidates
                .iter()
                .any(|c| !["movie", "tv", "season", "collection"].contains(&c.media_type.as_str()))
            {
                return Err("invalid candidate media type".into());
            }
            let scores: Vec<_> = candidates.iter().map(|c| score(c, &item)).collect();
            let needs_original_search = !scores.iter().any(|s| *s >= AUTO_APPLY_THRESHOLD)
                && item.original_title.as_ref().is_some_and(|original| {
                    !original.is_empty() && original.nfc().ne(item.name.nfc())
                });
            Ok(
                json!({"match": rank(&item, &candidates), "scores": scores, "needsOriginalSearch": needs_original_search}),
            )
        }
        _ => Err("unknown TMDB matcher operation".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_title_rules_preserve_non_width_compatibility_and_marks() {
        assert_eq!(normalize(Some("Ａ SHOW 第十一季")), "ashow");
        assert_eq!(normalize(Some("ガ Season 12")), "ｶﾞ");
        assert_eq!(normalize(Some("Cafe\u{301} ② Ⅳ")), "cafe\u{301}②ⅳ");
        assert_eq!(normalize(Some("Show 1st Season")), "show1stseason");
        assert_eq!(year(Some("title (2100)")), Some(2100));
        assert_eq!(year(Some("title (1800) (2024)")), None);
    }
    #[test]
    fn identity_and_score_do_not_infer_authority_or_scoring_year() {
        let result = invoke(&json!({"item":{"name":"Episode", "kind":"episode", "tmdbID":"3384539", "seasonNumber":0}, "seriesLink":{"entityKey":"tv/9223372036854775807", "source":"manual", "confidence":0.8}})).unwrap();
        assert_eq!(
            result["match"]["entityKey"],
            "tv/9223372036854775807/season/0"
        );
        let result = invoke(&json!({"operation":"rank", "item":{"name":"Title (2024)", "kind":"movie"}, "candidates":[{"id":1, "mediaType":"movie", "title":"Title (2024)", "year":2024}]})).unwrap();
        assert_eq!(result["scores"][0], 0.7);
        assert_eq!(result["match"]["shouldApplyAutomatically"], false);
    }
    #[test]
    fn numeric_graphemes_and_containment_keep_native_character_boundaries() {
        assert_eq!(normalize(Some("Show 第2\u{301}季")), "show");
        assert_eq!(normalize(Some("Show season2\u{fe0f}")), "show");
        assert_eq!(year(Some("(2\u{301}019) (2024)")), None);
        assert_eq!(year(Some("(2019)\u{fe0f} (2024)")), Some(2024));
        let result = invoke(&json!({"operation":"score", "item":{"name":"X", "kind":"series", "year":2024}, "candidates":[{"id":1,"mediaType":"tv","title":"X\u{fe0f}","year":2024}]})).unwrap();
        assert_eq!(result["scores"][0], 0.1);
    }
}
