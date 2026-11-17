//! Shared address selection, cache validity and stale-probe protection.
//! Hosts supply probe results and own task scheduling/network-change signals.

use serde::{Deserialize, Serialize};
use url::Url;

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EndpointConfig {
    #[serde(rename = "baseURL")]
    pub base_url: String,
    pub candidates: Vec<String>,
    #[serde(rename = "pinnedURL")]
    pub pinned_url: Option<String>,
    #[serde(rename = "expectedServerID")]
    pub expected_server_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct EndpointOptions {
    pub cache_ttl: f64,
    pub unreachable_retry_interval: f64,
    pub failure_cooldown: f64,
    pub stickiness_ratio: f64,
    pub stickiness_slack: f64,
}

impl Default for EndpointOptions {
    fn default() -> Self {
        Self {
            cache_ttl: 300.0,
            unreachable_retry_interval: 5.0,
            failure_cooldown: 3.0,
            stickiness_ratio: 0.7,
            stickiness_slack: 0.02,
        }
    }
}

impl EndpointOptions {
    pub fn validate(&self) -> Result<(), String> {
        if [
            self.cache_ttl,
            self.unreachable_retry_interval,
            self.failure_cooldown,
            self.stickiness_ratio,
            self.stickiness_slack,
        ]
        .iter()
        .any(|value| !value.is_finite() || *value < 0.0)
            || self.stickiness_ratio > 1.0
        {
            return Err("invalid endpoint timing/stickiness options".into());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointProbeResult {
    pub url: String,
    pub latency: f64,
    #[serde(rename = "serverID")]
    pub server_id: Option<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ResolutionDecision {
    Immediate,
    AwaitResolution,
    Background,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointSnapshot {
    #[serde(rename = "currentURL")]
    pub current_url: String,
    pub pinned: bool,
    pub candidate_count: usize,
    pub generation: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolutionPlan {
    pub generation: u64,
    pub targets: Vec<String>,
    #[serde(rename = "expectedServerID")]
    pub expected_server_id: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolutionApplied {
    pub snapshot: EndpointSnapshot,
    pub changed: bool,
    pub stale: bool,
    pub latency: Option<f64>,
}

pub struct EndpointDirectory {
    config: EndpointConfig,
    active: String,
    resolved_at: Option<f64>,
    earliest_next_probe: Option<f64>,
    last_failover_at: Option<f64>,
    hard_invalid: bool,
    generation: u64,
}

pub fn normalized_address(address: &str) -> Result<String, String> {
    let mut url = Url::parse(address).map_err(|_| "invalid endpoint URL")?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err("endpoint URL must use HTTP(S) with a host".into());
    }
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(&path);
    url.set_fragment(None);
    // url::Url normalizes host/scheme and removes default ports on parsing.
    Ok(url.to_string())
}

pub fn same_address(left: &str, right: &str) -> bool {
    match (normalized_address(left), normalized_address(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

impl EndpointConfig {
    fn validated(mut self) -> Result<Self, String> {
        normalized_address(&self.base_url)?;
        if let Some(pinned) = &self.pinned_url {
            normalized_address(pinned)?;
        }
        let mut unique: Vec<String> = Vec::new();
        for candidate in self.candidates {
            normalized_address(&candidate)?;
            if !unique
                .iter()
                .any(|existing| same_address(existing, &candidate))
            {
                unique.push(candidate);
            }
        }
        self.candidates = unique;
        Ok(self)
    }
}

impl EndpointDirectory {
    pub fn new(config: EndpointConfig) -> Result<Self, String> {
        let config = config.validated()?;
        Ok(Self {
            active: config
                .pinned_url
                .clone()
                .unwrap_or_else(|| config.base_url.clone()),
            config,
            resolved_at: None,
            earliest_next_probe: None,
            last_failover_at: None,
            hard_invalid: true,
            generation: 0,
        })
    }

    pub fn snapshot(&self) -> EndpointSnapshot {
        EndpointSnapshot {
            current_url: self.active.clone(),
            pinned: self.config.pinned_url.is_some(),
            candidate_count: self.config.candidates.len(),
            generation: self.generation,
        }
    }

    pub fn decision(&self, now: f64, options: &EndpointOptions) -> ResolutionDecision {
        if self
            .earliest_next_probe
            .is_some_and(|earliest| now < earliest)
        {
            return ResolutionDecision::Immediate;
        }
        if self.hard_invalid || self.resolved_at.is_none() {
            return ResolutionDecision::AwaitResolution;
        }
        if self
            .resolved_at
            .is_some_and(|resolved| now - resolved >= options.cache_ttl)
        {
            return ResolutionDecision::Background;
        }
        ResolutionDecision::Immediate
    }

    pub fn begin(&mut self) -> ResolutionPlan {
        self.generation = self.generation.wrapping_add(1);
        self.hard_invalid = false;
        let targets = if let Some(pinned) = &self.config.pinned_url {
            vec![pinned.clone()]
        } else if self.config.candidates.is_empty() {
            vec![self.active.clone()]
        } else {
            self.config.candidates.clone()
        };
        ResolutionPlan {
            generation: self.generation,
            targets,
            expected_server_id: self.config.expected_server_id.clone(),
        }
    }

    pub fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.hard_invalid = true;
        self.resolved_at = None;
        self.earliest_next_probe = None;
    }

    pub fn sync(&mut self, config: EndpointConfig) -> Result<EndpointSnapshot, String> {
        let mut config = config.validated()?;
        // Identity belongs to the original session, just as credentials do.
        config.expected_server_id = self.config.expected_server_id.clone();
        if config != self.config {
            self.invalidate();
        }
        if let Some(pinned) = &config.pinned_url {
            self.active = pinned.clone();
        } else if !config
            .candidates
            .iter()
            .any(|candidate| same_address(candidate, &self.active))
        {
            self.active = config.base_url.clone();
        }
        self.config = config;
        Ok(self.snapshot())
    }

    pub fn failure_allowed(&mut self, failed: &str, now: f64, options: &EndpointOptions) -> bool {
        if self.config.pinned_url.is_some()
            || !same_address(failed, &self.active)
            || self
                .last_failover_at
                .is_some_and(|last| now - last < options.failure_cooldown)
        {
            return false;
        }
        self.last_failover_at = Some(now);
        true
    }

    pub fn apply(
        &mut self,
        results: &[EndpointProbeResult],
        generation: u64,
        now: f64,
        options: &EndpointOptions,
    ) -> ResolutionApplied {
        if generation != self.generation {
            return ResolutionApplied {
                snapshot: self.snapshot(),
                changed: false,
                stale: true,
                latency: None,
            };
        }
        let results: Vec<_> = results
            .iter()
            .filter(|result| {
                result.latency.is_finite()
                    && result.latency >= 0.0
                    && (self
                        .config
                        .candidates
                        .iter()
                        .any(|candidate| same_address(candidate, &result.url))
                        || same_address(&result.url, &self.active))
                    && !self
                        .config
                        .expected_server_id
                        .as_ref()
                        .zip(result.server_id.as_ref())
                        .is_some_and(|(expected, actual)| !actual.is_empty() && expected != actual)
            })
            .collect();
        let before = self.active.clone();
        if let Some(pinned) = &self.config.pinned_url {
            self.active = pinned.clone();
        } else if let Some(best) = results
            .iter()
            .min_by(|left, right| left.latency.total_cmp(&right.latency))
        {
            self.active = if let Some(current) = results
                .iter()
                .find(|result| same_address(&result.url, &self.active))
            {
                if best.latency
                    < current.latency * options.stickiness_ratio - options.stickiness_slack
                {
                    best.url.clone()
                } else {
                    current.url.clone()
                }
            } else {
                best.url.clone()
            };
        }
        if results.is_empty() {
            self.resolved_at = None;
            self.earliest_next_probe = Some(now + options.unreachable_retry_interval);
        } else {
            self.resolved_at = Some(now);
            self.earliest_next_probe = None;
        }
        ResolutionApplied {
            changed: !same_address(&before, &self.active),
            stale: false,
            latency: results
                .iter()
                .find(|result| same_address(&result.url, &self.active))
                .map(|result| result.latency),
            snapshot: self.snapshot(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> EndpointConfig {
        EndpointConfig {
            base_url: "http://lan:8096/emby".into(),
            candidates: vec![
                "http://lan:8096/emby".into(),
                "http://tail:8096/emby".into(),
            ],
            pinned_url: None,
            expected_server_id: Some("srv".into()),
        }
    }
    fn result(url: &str, latency: f64, server: Option<&str>) -> EndpointProbeResult {
        EndpointProbeResult {
            url: format!("http://{url}:8096/emby"),
            latency,
            server_id: server.map(str::to_owned),
        }
    }

    #[test]
    fn selection_stickiness_identity_and_soft_cache() {
        let options = EndpointOptions::default();
        let mut directory = EndpointDirectory::new(config()).unwrap();
        assert_eq!(
            directory.decision(100.0, &options),
            ResolutionDecision::AwaitResolution
        );
        let plan = directory.begin();
        directory.apply(
            &[
                result("lan", 0.04, Some("srv")),
                result("tail", 0.03, Some("srv")),
            ],
            plan.generation,
            100.0,
            &options,
        );
        assert!(directory.snapshot().current_url.contains("lan"));
        assert_eq!(
            directory.decision(399.0, &options),
            ResolutionDecision::Immediate
        );
        assert_eq!(
            directory.decision(400.0, &options),
            ResolutionDecision::Background
        );
        let plan = directory.begin();
        let applied = directory.apply(
            &[
                result("lan", 0.06, Some("srv")),
                result("tail", 0.004, Some("srv")),
            ],
            plan.generation,
            400.0,
            &options,
        );
        assert!(applied.changed);
        assert!(applied.snapshot.current_url.contains("tail"));
        let plan = directory.begin();
        directory.apply(
            &[
                result("lan", 0.001, Some("other")),
                result("tail", 0.05, None),
            ],
            plan.generation,
            500.0,
            &options,
        );
        assert!(directory.snapshot().current_url.contains("tail"));
    }

    #[test]
    fn unreachable_cooldown_pinning_and_stale_failures() {
        let options = EndpointOptions::default();
        let mut directory = EndpointDirectory::new(config()).unwrap();
        let plan = directory.begin();
        directory.apply(&[], plan.generation, 100.0, &options);
        assert_eq!(
            directory.decision(104.0, &options),
            ResolutionDecision::Immediate
        );
        assert_eq!(
            directory.decision(105.0, &options),
            ResolutionDecision::AwaitResolution
        );
        assert!(!directory.failure_allowed("http://tail:8096/emby", 100.0, &options));
        assert!(directory.failure_allowed("http://lan:8096/emby", 100.0, &options));
        assert!(!directory.failure_allowed("http://lan:8096/emby", 102.0, &options));
        assert!(directory.failure_allowed("http://lan:8096/emby", 103.0, &options));
        let mut pinned = config();
        pinned.pinned_url = Some("http://tail:8096/emby".into());
        directory.sync(pinned).unwrap();
        assert_eq!(directory.begin().targets, ["http://tail:8096/emby"]);
        assert!(!directory.failure_allowed("http://tail:8096/emby", 200.0, &options));
    }

    #[test]
    fn invalidation_and_profile_sync_reject_in_flight_results() {
        let mut directory = EndpointDirectory::new(config()).unwrap();
        let options = EndpointOptions::default();
        let old = directory.begin();
        directory.invalidate();
        assert!(
            directory
                .apply(
                    &[result("tail", 0.01, Some("srv"))],
                    old.generation,
                    100.0,
                    &options
                )
                .stale
        );
        let old = directory.begin();
        let mut updated = config();
        updated.candidates = vec![updated.base_url.clone()];
        directory.sync(updated).unwrap();
        assert!(
            directory
                .apply(
                    &[result("tail", 0.01, Some("srv"))],
                    old.generation,
                    101.0,
                    &options
                )
                .stale
        );
        assert_eq!(directory.snapshot().current_url, "http://lan:8096/emby");
        assert_eq!(
            directory.decision(101.0, &options),
            ResolutionDecision::AwaitResolution
        );
    }

    #[test]
    fn normalized_duplicates_and_bad_input_are_handled_before_mutation() {
        assert!(same_address(
            "HTTP://NAS.local:80/emby/",
            "http://nas.local/emby"
        ));
        assert!(!same_address("http://nas.local/emby", "http://nas.local"));
        let mut candidates = config();
        candidates.candidates.push("HTTP://LAN:8096/emby/".into());
        let mut directory = EndpointDirectory::new(candidates).unwrap();
        assert_eq!(directory.snapshot().candidate_count, 2);
        let before = directory.snapshot().current_url;
        let mut bad = config();
        bad.base_url = "file:///tmp/test".into();
        assert!(directory.sync(bad).is_err());
        assert_eq!(directory.snapshot().current_url, before);
        assert!(EndpointOptions {
            cache_ttl: f64::NAN,
            ..EndpointOptions::default()
        }
        .validate()
        .is_err());
    }
}
