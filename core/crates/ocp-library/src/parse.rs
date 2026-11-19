//! Explicit library type precedes filename heuristics. Movie numbers are never episodes.
use crate::{ItemKind, LibraryType};
use regex::Regex;
use std::{path::Path, sync::OnceLock};

#[derive(Debug, Clone, PartialEq)]
pub struct Parsed {
    pub kind: ItemKind,
    pub title: String,
    pub year: Option<i64>,
    pub series_title: Option<String>,
    pub series_group: Option<String>,
    pub season: Option<i64>,
    pub episode: Option<i64>,
}

fn regex(slot: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    slot.get_or_init(|| Regex::new(pattern).expect("fixed library pattern"))
}

fn title(raw: &str) -> (String, Option<i64>) {
    static YEAR: OnceLock<Regex> = OnceLock::new();
    static RELEASE_YEAR: OnceLock<Regex> = OnceLock::new();
    static TECH: OnceLock<Regex> = OnceLock::new();
    // A number in a title (1917, Blade Runner 2049) is not a release year.
    let year_match = regex(&YEAR, r"[\[(]((?:19|20)\d{2})[\])]")
        .captures_iter(raw)
        .last()
        .or_else(|| {
            regex(&RELEASE_YEAR, r"[._]((?:19|20)\d{2})(?:[._]|$)")
                .captures_iter(raw)
                .last()
        });
    let year = year_match.as_ref().and_then(|c| c[1].parse().ok());
    let without_year = if let Some(c) = year_match {
        let mut result = raw.to_owned();
        result.replace_range(c.get(0).unwrap().range(), " ");
        result
    } else {
        raw.to_owned()
    };
    let clean = regex(&TECH, r"(?i)\b(?:2160p|1080p|720p|4k|uhd|remux|web[- .]?dl|web[- .]?rip|bluray|bdrip|x26[45]|h26[45]|hevc|avc|aac|dts|10bit)\b")
        .replace_all(&without_year, " ").replace(['.', '_'], " ");
    let clean = clean
        .trim_matches(|c: char| c.is_whitespace() || "-[]()".contains(c))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (
        if clean.is_empty() {
            raw.to_owned()
        } else {
            clean
        },
        year,
    )
}

pub fn is_video(path: &Path) -> bool {
    path.extension()
        .and_then(|s| s.to_str())
        .is_some_and(|ext| {
            matches!(
                ext.to_ascii_lowercase().as_str(),
                "mkv"
                    | "mp4"
                    | "m4v"
                    | "mov"
                    | "avi"
                    | "webm"
                    | "ts"
                    | "m2ts"
                    | "mpg"
                    | "mpeg"
                    | "wmv"
                    | "flv"
            )
        })
}

pub fn parse(relative: &Path, library_type: LibraryType) -> Parsed {
    let stem = relative.file_stem().unwrap_or_default().to_string_lossy();
    if library_type == LibraryType::Movies {
        let (name, year) = title(&stem);
        return Parsed {
            kind: ItemKind::Movie,
            title: name,
            year,
            series_title: None,
            series_group: None,
            season: None,
            episode: None,
        };
    }
    static SE: OnceLock<Regex> = OnceLock::new();
    static CROSS: OnceLock<Regex> = OnceLock::new();
    static SEASON: OnceLock<Regex> = OnceLock::new();
    static EP: OnceLock<Regex> = OnceLock::new();
    static MULTI: OnceLock<Regex> = OnceLock::new();
    let explicit = regex(&SE, r"(?i)(?:^|[ ._\-])s(\d{1,2})e(\d{1,4})(?:\b|[ ._\-])")
        .captures(&stem)
        .or_else(|| {
            regex(
                &CROSS,
                r"(?i)(?:^|[ ._\-])(\d{1,2})x(\d{1,4})(?:\b|[ ._\-])",
            )
            .captures(&stem)
        });
    let season_re = regex(
        &SEASON,
        r"(?i)^(?:season\s*|s)(\d{1,2})$|^第\s*(\d{1,2})\s*季$",
    );
    let directories: Vec<_> = relative
        .parent()
        .unwrap_or(Path::new(""))
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    let season_dir = directories
        .iter()
        .rev()
        .find_map(|d| season_re.captures(d))
        .and_then(|c| c.get(1).or_else(|| c.get(2)))
        .and_then(|n| n.as_str().parse::<i64>().ok());
    let series_directory = directories
        .iter()
        .enumerate()
        .rev()
        .find(|(_, d)| !season_re.is_match(d));
    let series_dir = series_directory.map(|(_, d)| d);
    let (mut season, mut episode, mut prefix) = (season_dir, None, None);
    if let Some(c) = explicit {
        season = c[1].parse().ok();
        episode = c[2].parse().ok();
        prefix = Some(stem[..c.get(0).unwrap().start()].to_owned());
    } else if let Some(c) = regex(
        &EP,
        r"(?i)(?:^|[ ._\-])(?:ep?|第\s*)(\d{1,4})(?:集|话|話|\b)",
    )
    .captures(&stem)
    {
        episode = c[1].parse().ok();
        prefix = Some(stem[..c.get(0).unwrap().start()].to_owned());
        if season.is_none() && series_dir.is_some() {
            season = Some(1);
        }
    } else if season_dir.is_some() && series_dir.is_some() {
        episode = stem.trim().parse::<i64>().ok();
    }
    // Until interval/absolute numbering is mapped explicitly, keep these assets unresolved.
    if regex(&MULTI, r"(?i)(?:e\d{1,4}(?:e\d|[- ]e?\d)|\d+x\d+[- ]\d+)").is_match(&stem) {
        episode = None;
    }
    let raw_series = series_dir.map(String::as_str).or(prefix
        .as_deref()
        .filter(|p| !p.trim_matches([' ', '.', '_', '-']).is_empty()));
    let (series, year) = raw_series.map(title).unwrap_or_default();
    let identified = !series.is_empty() && season.is_some() && episode.is_some_and(|e| e > 0);
    Parsed {
        kind: if identified {
            ItemKind::Episode
        } else {
            ItemKind::Unidentified
        },
        title: stem.into_owned(),
        year,
        series_title: (!series.is_empty()).then_some(series),
        series_group: series_directory
            .map(|(index, _)| directories[..=index].join("/"))
            .or_else(|| {
                prefix
                    .as_deref()
                    .map(|p| title(p).0)
                    .filter(|p| !p.is_empty())
            }),
        season,
        episode,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numeric_movies_and_release_tags_preserve_title() {
        let p = parse(
            Path::new("1917 (2019).2160p.Remux.mkv"),
            LibraryType::Movies,
        );
        assert_eq!(
            (p.kind, p.title.as_str(), p.year, p.episode),
            (ItemKind::Movie, "1917", Some(2019), None)
        );
        assert_eq!(
            parse(
                Path::new("2001 A Space Odyssey (1968).mp4"),
                LibraryType::Movies
            )
            .title,
            "2001 A Space Odyssey"
        );
        assert_eq!(
            parse(Path::new("Blade Runner 2049.mkv"), LibraryType::Movies).title,
            "Blade Runner 2049"
        );
    }

    #[test]
    fn seasons_specials_and_explicit_numbers() {
        for (path, season, episode) in [
            ("某剧 (2024)/Season 02/某剧.S02E03.mkv", 2, 3),
            ("Show/Season 00/Show.S00E01.mkv", 0, 1),
            ("Show/Season 02/03.mkv", 2, 3),
            ("Show.2x03.mkv", 2, 3),
        ] {
            let p = parse(Path::new(path), LibraryType::Tvshows);
            assert_eq!(
                (p.kind, p.season, p.episode),
                (ItemKind::Episode, Some(season), Some(episode)),
                "{path}"
            );
        }
        for path in [
            "1917.mkv",
            "Show/03.mkv",
            "Show.S01E01E02.mkv",
            "Show.S01E01-02.mkv",
        ] {
            assert_eq!(
                parse(Path::new(path), LibraryType::Tvshows).kind,
                ItemKind::Unidentified,
                "{path}"
            );
        }
    }
}
