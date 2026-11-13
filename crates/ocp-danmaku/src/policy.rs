//! Native-equivalent candidate identity and ranking policy. Batch selection keeps
//! input ordering and returns an index so adapters retain complete source DTOs.
use crate::{
    comparable_title, parse_episode_token, parse_filename, Candidate, EpisodeToken, SpecialKind,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetContext {
    pub anime_title: Option<String>,
    pub episode_number: Option<i64>,
    pub season_number: Option<i64>,
    #[serde(default)]
    pub is_final: bool,
    pub special: Option<SpecialTarget>,
    #[serde(default)]
    pub kind: TargetKind,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpecialTarget {
    pub index: i64,
    pub kinds: Vec<SpecialKind>,
}
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TargetKind {
    #[default]
    Episode,
    Movie,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Selection {
    pub index: usize,
    pub score: i64,
}
pub const CONFIDENCE_THRESHOLD: i64 = 1200;

pub fn score(candidate: &Candidate, target: &TargetContext, rank: i64) -> i64 {
    let parsed = parse_filename(candidate.anime_title.as_deref().unwrap_or(""));
    let mut score = episode_score(target, candidate.episode_title.as_deref());
    score += if target.is_final {
        if parsed.is_final {
            1500
        } else {
            -1500
        }
    } else if parsed.is_final {
        -1500
    } else {
        0
    };
    score += match target.season_number {
        Some(n) if n > 1 => match parsed.season_number {
            Some(v) if v == n => 1500,
            None | Some(1) => -2000,
            _ => -3000,
        },
        None | Some(1) => {
            if parsed.season_number.is_none() || parsed.season_number == Some(1) {
                500
            } else {
                -2000
            }
        }
        _ => 0,
    };
    score += title_score(
        target.anime_title.as_deref(),
        candidate.anime_title.as_deref(),
    );
    let movie = candidate.kind.as_deref() == Some("movie")
        || candidate
            .type_description
            .as_deref()
            .is_some_and(|s| s.contains("剧场版") || s.contains("电影"));
    score += match target.kind {
        TargetKind::Movie => {
            if movie {
                1200
            } else {
                -10000
            }
        }
        TargetKind::Episode => {
            if movie {
                -10000
            } else {
                0
            }
        }
    };
    score.saturating_add(50i64.saturating_sub(rank).max(0))
}
fn episode_score(target: &TargetContext, title: Option<&str>) -> i64 {
    let episode = title.and_then(parse_episode_token);
    if let Some(special) = &target.special {
        return match episode {
            Some(EpisodeToken::Special { kind, index }) if index == special.index => {
                let fallback = [SpecialKind::Special, SpecialKind::Extra, SpecialKind::Other];
                let kinds = if special.kinds.is_empty() {
                    &fallback[..]
                } else {
                    &special.kinds
                };
                match kinds.iter().position(|k| *k == kind) {
                    Some(0) => 2000,
                    Some(_) => 1500,
                    None => 300,
                }
            }
            Some(EpisodeToken::Special { .. }) => -800,
            Some(EpisodeToken::Number { value }) if value == special.index => 600,
            Some(EpisodeToken::Number { .. }) => -1500,
            None => -500,
        };
    }
    if let Some(n) = target.episode_number {
        return match episode {
            Some(EpisodeToken::Number { value }) if n == value => 2000,
            Some(EpisodeToken::Number { .. }) => -3000,
            Some(EpisodeToken::Special { .. }) => -1500,
            None => -500,
        };
    }
    match episode {
        Some(EpisodeToken::Number { value: 1 }) | None => 800,
        Some(EpisodeToken::Number { .. }) => 0,
        Some(EpisodeToken::Special { .. }) => -500,
    }
}
fn title_score(target: Option<&str>, candidate: Option<&str>) -> i64 {
    let Some(target) = target.filter(|s| !s.is_empty()) else {
        return 500;
    };
    let a = comparable_title(target);
    let b = comparable_title(candidate.unwrap_or(""));
    if b.is_empty() {
        return -500;
    }
    if a == b {
        return 1500;
    }
    let al = a.graphemes(true).count();
    let bl = b.graphemes(true).count();
    if a.contains(&b) || b.contains(&a) {
        return (800.0 * al.min(bl) as f64 / al.max(bl) as f64) as i64 + 400;
    }
    let a: HashSet<_> = a.graphemes(true).collect();
    let b: HashSet<_> = b.graphemes(true).collect();
    let overlap = (a.intersection(&b).count() * 2) as f64 / (a.len() + b.len()) as f64;
    if overlap > 0.5 {
        (600.0 * overlap) as i64
    } else {
        -500
    }
}
pub fn select(candidates: &[Candidate], target: &TargetContext) -> Option<Selection> {
    let scores: Vec<_> = candidates
        .iter()
        .enumerate()
        .map(|(i, c)| score(c, target, i as i64))
        .collect();
    select_scores(&scores)
}
pub fn select_scores(scores: &[i64]) -> Option<Selection> {
    let mut best: Option<Selection> = None;
    for (index, &score) in scores.iter().enumerate() {
        if best.as_ref().is_none_or(|b| score > b.score) {
            best = Some(Selection { index, score });
        }
    }
    best.filter(|b| b.score >= CONFIDENCE_THRESHOLD)
}

/// Filename keywords use letter boundaries and prefer extra footage over SP.
/// Grapheme boundaries preserve Swift's handling of combining marks and ZWJ.
pub fn special_kind(text: &str) -> Option<SpecialKind> {
    let text = crate::normalize_full_width(text).to_lowercase();
    let graphemes: Vec<_> = text.grapheme_indices(true).collect();
    let mut boundaries: HashSet<usize> = graphemes.iter().map(|(i, _)| *i).collect();
    boundaries.insert(text.len());
    for (kind, keywords) in [
        (
            SpecialKind::Extra,
            &[
                "ncop",
                "nced",
                "non-credit",
                "noncredit",
                "opening",
                "ending",
                "menu",
                "preview",
                "pv",
                "cm",
                "予告",
                "预告",
                "オープニング",
                "エンディング",
            ][..],
        ),
        (
            SpecialKind::Special,
            &["sp", "special", "特典", "特别篇", "特別篇", "番外"][..],
        ),
    ] {
        for keyword in keywords {
            for (start, _) in text.match_indices(keyword) {
                let end = start + keyword.len();
                if !boundaries.contains(&start) || !boundaries.contains(&end) {
                    continue;
                }
                let before = graphemes
                    .iter()
                    .rev()
                    .find(|(i, _)| *i < start)
                    .map(|(_, g)| *g);
                let after = graphemes.iter().find(|(i, _)| *i == end).map(|(_, g)| *g);
                if !before.is_some_and(|g| g.chars().next().is_some_and(char::is_alphabetic))
                    && !after.is_some_and(|g| g.chars().next().is_some_and(char::is_alphabetic))
                {
                    return Some(kind);
                }
            }
        }
    }
    None
}
