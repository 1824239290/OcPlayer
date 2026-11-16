use crate::{
    normalize_full_width, parse_chinese_number, EpisodeToken, ParsedAnimeInfo, SpecialKind,
};
use regex::Regex;
use std::sync::OnceLock;

fn patterns(slot: &'static OnceLock<Vec<Regex>>, patterns: &[&str]) -> &'static Vec<Regex> {
    slot.get_or_init(|| patterns.iter().map(|p| Regex::new(p).unwrap()).collect())
}
fn stem(raw: &str) -> String {
    let normalized = normalize_full_width(raw).replace('\\', "/");
    let file = normalized
        .split('/')
        .filter(|p| !p.is_empty())
        .next_back()
        .unwrap_or(&normalized);
    file.rsplit_once('.')
        // Callers also pass extensionless release names and series titles.
        // Treating any dotted suffix as an extension loses "Series.S01E01".
        .filter(|(stem, extension)| {
            !stem.is_empty()
                && matches!(
                    extension.to_ascii_lowercase().as_str(),
                    "mkv"
                        | "mp4"
                        | "avi"
                        | "mov"
                        | "wmv"
                        | "webm"
                        | "ts"
                        | "m2ts"
                        | "flv"
                        | "m4v"
                        | "mpg"
                        | "mpeg"
                        | "rmvb"
                        | "rm"
                        | "vob"
                        | "iso"
                )
        })
        .map(|(s, _)| s)
        .unwrap_or(file)
        .to_owned()
}

pub fn parse_episode_token(input: &str) -> Option<EpisodeToken> {
    static TOKENS: OnceLock<Vec<Regex>> = OnceLock::new();
    let patterns = patterns(
        &TOKENS,
        &[
            r"^([SCO])(\d{1,3})",
            r"第\s*(\d+)\s*[话話集回期]",
            r"第\s*([一二两三四五六七八九十]+)\s*[话話集回期]",
            r"^(?:EP|E)?\s*(\d{1,4})(?:\b|\s|$)",
        ],
    );
    let name = normalize_full_width(input);
    let name = name.trim();
    if let Some(c) = patterns[0].captures(name) {
        let after = &name[c.get(0)?.end()..];
        if !after.starts_with(|c: char| c.is_ascii_digit()) {
            if let Some(index) = c[2].parse::<i64>().ok().filter(|n| *n > 0) {
                let kind = match &c[1] {
                    "S" => SpecialKind::Special,
                    "C" => SpecialKind::Extra,
                    _ => SpecialKind::Other,
                };
                return Some(EpisodeToken::Special { kind, index });
            }
        }
    }
    for p in &patterns[1..] {
        if let Some(c) = p.captures(name) {
            if let Some(value) = parse_chinese_number(&c[1]) {
                return Some(EpisodeToken::Number { value });
            }
        }
    }
    parse_filename(input)
        .episode_number
        .map(|value| EpisodeToken::Number { value })
}

pub fn parse_filename(raw: &str) -> ParsedAnimeInfo {
    static FINAL: OnceLock<Regex> = OnceLock::new();
    static SEASONS: OnceLock<Vec<Regex>> = OnceLock::new();
    static EPISODES: OnceLock<Vec<Regex>> = OnceLock::new();
    static TAGS: OnceLock<Vec<Regex>> = OnceLock::new();
    static TECH: OnceLock<Vec<Regex>> = OnceLock::new();
    let name = stem(raw);
    let is_final = FINAL
        .get_or_init(|| Regex::new(r"(?i)(?:the\s+)?final\s+season|最终季|完结篇").unwrap())
        .is_match(&name);
    let seasons = patterns(
        &SEASONS,
        &[
            r"(?i)(?:^|[\s_\-.\[(])S(\d{1,2})(?:[Ee]|\b|[\s_\-.\])])",
            r"(?i)season\s*(\d{1,2})",
            r"第\s*(\d{1,2})\s*[季期部]",
            r"(?i)(\d{1,2})(?:st|nd|rd|th)\s*season",
            r"第\s*([一二两三四五六七八九十]+)\s*[季期部]",
        ],
    );
    let season_number = if is_final {
        None
    } else {
        seasons
            .iter()
            .find_map(|p| p.captures(&name).and_then(|c| parse_chinese_number(&c[1])))
    };
    let episodes = patterns(
        &EPISODES,
        &[
            r"(?i)(?:s\d{1,2})?[Ee](?:p)?\s*(\d{1,4})(?:v\d+)?(?:\b|[^a-zA-Z0-9])",
            r"第\s*(\d{1,4})\s*[话話集回期]",
            r"(?:^|[\s_\-.\[【(])(\d{1,4})(?:v\d+)?",
            r"第\s*([一二两三四五六七八九十]+)\s*[话話集回期]",
        ],
    );
    let mut episode_number = None;
    for (index, p) in episodes.iter().enumerate() {
        for c in p.captures_iter(&name) {
            if index == 2
                && name[c.get(0).unwrap().end()..]
                    .chars()
                    .next()
                    .is_some_and(|ch| !ch.is_whitespace() && !"_-.]】)".contains(ch))
            {
                continue;
            }
            if let Some(n) = parse_chinese_number(&c[1]) {
                // Season/resolution/year exclusions apply to bare numbers only;
                // explicit E01 / 第1集 is a real episode even in season 1.
                if index == 2
                    && (matches!(n, 720 | 1080 | 2160)
                        || (1970..=2050).contains(&n)
                        || Some(n) == season_number)
                {
                    continue;
                }
                episode_number = Some(n);
                break;
            }
        }
        if episode_number.is_some() {
            break;
        }
    }
    let tags = patterns(
        &TAGS,
        &[
            r"\[[^\]]*\]",
            r"【[^】]*】",
            r"\([^\)]*\)",
            r"（[^）]*）",
            r"★[^★]*★",
        ],
    );
    let total_tags: usize = tags.iter().map(|p| p.find_iter(&name).count()).sum();
    let mut title = name.clone();
    for p in tags {
        let removals: Vec<_> = p
            .find_iter(&title)
            .filter_map(|m| {
                let inner = m.as_str().trim_matches(|c| "[]【】()（）★ ".contains(c));
                let is_episode = episode_number
                    .is_some_and(|n| inner == n.to_string() || inner == format!("{n:02}"));
                let year = inner.len() == 4
                    && inner
                        .parse::<i64>()
                        .is_ok_and(|n| (1900..=2100).contains(&n));
                (is_noise_tag(inner) || is_episode || year || (m.start() == 0 && total_tags > 1))
                    .then_some(m.range())
            })
            .collect();
        for r in removals.into_iter().rev() {
            title.replace_range(r, "");
        }
    }
    for p in patterns(
        &TECH,
        &[
            r"(?i)\b(?:1080p|720p|2160p|4k|uhd|fhd|hd)\b",
            r"(?i)\b(?:hevc|avc|x264|x265|h264|h265|10bit|8bit|ma10p)\b",
            r"(?i)\b(?:aac|flac|mp3|dts|ac3|eac3|ddp?)\b",
            r"(?i)\b(?:web-?dl|web-?rip|baha|cr|bilibili|abema|bdrip|dvdrip)\b",
            r"(?i)\b(?:chs|cht|gb|big5|jp|sc|tc|eng|ita)\b",
            r"(?i)\b(?:s\d{1,2}e\d{1,4}|ep?\d{1,4})\b",
            r"第\s*\d{1,4}\s*[话話集回期]",
            r"(?i)season\s*\d+",
            r"第\s*\d+\s*[季期部]",
            r"(?i)(?:the\s+)?final\s+season|最终季|完结篇",
        ],
    ) {
        title = p.replace_all(&title, " ").into_owned();
    }
    let dash: Vec<_> = title
        .split(" - ")
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    if dash.len() >= 2 {
        title = dash[0].to_owned();
    } else if dash.len() == 1 {
        if let Some(n) = episode_number {
            let tail = Regex::new(&format!(r"\s*\]?{n:02}\s*$")).unwrap();
            title = tail.replace_all(&title, "").into_owned();
        }
    }
    title = title
        .replace(['.', '_'], " ")
        .trim_matches(|c| " -_./[]()【】 ".contains(c))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if title.is_empty() {
        title = name;
    }
    ParsedAnimeInfo {
        raw_name: raw.to_owned(),
        title,
        episode_number,
        season_number,
        is_final,
    }
}

#[cfg(test)]
mod filename_regressions {
    use super::parse_filename;

    #[test]
    fn explicit_episode_is_not_filtered_as_season_or_resolution() {
        for (name, episode, season) in [
            ("葬送的芙莉莲.S01E01.mkv", 1, 1),
            ("Series.S02E02", 2, 2),
            ("番剧 第2季 第2集.mp4", 2, 2),
            ("Series S01E1080", 1080, 1),
        ] {
            let parsed = parse_filename(name);
            assert_eq!(parsed.episode_number, Some(episode), "{name}");
            assert_eq!(parsed.season_number, Some(season), "{name}");
        }
        assert_eq!(parse_filename("Series Season 2 1080p").episode_number, None);
    }

    #[test]
    fn extensionless_dotted_names_keep_episode_and_title() {
        let name = parse_filename("葬送的芙莉莲.S01E01");
        assert_eq!(name.episode_number, Some(1));
        assert_eq!(name.season_number, Some(1));
        assert_eq!(name.title, "葬送的芙莉莲");
        assert_eq!(parse_filename("Dr. Stone").title, "Dr Stone");
        assert_eq!(parse_filename("Show.E12.MKV").episode_number, Some(12));
    }
}

fn is_noise_tag(tag: &str) -> bool {
    let lower = tag.to_lowercase();
    let tag = lower.trim();
    if tag.is_empty() {
        return true;
    }
    if tag.len() == 8 && tag.chars().all(|c| c.is_ascii_hexdigit()) {
        return true;
    }
    if let Ok(n) = tag.parse::<i64>() {
        if ((0..=2000).contains(&n) && !matches!(n, 1080 | 720))
            || (tag.len() == 4 && (1900..=2100).contains(&n))
        {
            return true;
        }
    }
    [
        "nc-raws",
        "lilith-raws",
        "ani",
        "b-global",
        "sweetsub",
        "lolihouse",
        "dmg",
        "beansub",
        "mikan",
        "dbd-raws",
        "喵萌奶茶屋",
        "幻樱字幕组",
        "极影字幕社",
        "诸神字幕组",
        "悠哈璃羽字幕社",
        "风车字幕组",
        "恶魔奶爸字幕组",
        "1080p",
        "720p",
        "2160p",
        "4k",
        "hevc",
        "avc",
        "x264",
        "x265",
        "h264",
        "h265",
        "aac",
        "flac",
        "ac3",
        "dts",
        "10bit",
        "8bit",
        "ma10p",
        "web-dl",
        "webrip",
        "baha",
        "cr",
        "bilibili",
        "chs",
        "cht",
        "gb",
        "big5",
        "简日双语",
        "繁日双语",
        "简繁",
        "双语",
        "新番",
        "招募",
        "字幕",
        "bdrip",
        "dvdrip",
        "mp4",
        "mkv",
        "sc",
        "tc",
    ]
    .iter()
    .any(|kw| tag.contains(kw))
}
