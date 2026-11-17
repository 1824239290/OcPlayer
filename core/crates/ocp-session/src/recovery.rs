//! Retry/rebuild intent is separate from decoder and HTTP effects. The host
//! retains the complete item/request and dispatches preparation or decoder reopen.
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub mode: Mode,
    pub loading: bool,
    pub has_playback: bool,
    pub has_request: bool,
    pub has_media_item: bool,
    pub has_loaded_source: bool,
    pub current_position_seconds: Option<f64>,
    pub request_resume_seconds: Option<f64>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Manual,
    Background,
}
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    None,
    Reprepare,
    Reopen,
    RetryLast,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub action: Action,
    pub resume_seconds: Option<f64>,
}
pub fn plan(request: Request) -> Result<Plan, String> {
    if request
        .current_position_seconds
        .is_some_and(|v| !v.is_finite())
        || request
            .request_resume_seconds
            .is_some_and(|v| !v.is_finite())
    {
        return Err("recovery positions must be finite".into());
    }
    let (action, resume_seconds) = match request.mode {
        Mode::Manual if request.loading => (Action::None, None),
        Mode::Manual if !request.has_media_item => (Action::RetryLast, None),
        Mode::Manual => (
            Action::Reprepare,
            request
                .current_position_seconds
                .filter(|&v| v >= 30.0)
                .or(request.request_resume_seconds),
        ),
        Mode::Background if !request.has_playback || !request.has_request => (Action::None, None),
        Mode::Background => (
            if request.has_media_item {
                Action::Reprepare
            } else {
                Action::Reopen
            },
            if request.has_loaded_source {
                request.current_position_seconds
            } else {
                request.request_resume_seconds
            },
        ),
    };
    Ok(Plan {
        action,
        resume_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(mode: Mode) -> Request {
        Request {
            mode,
            loading: false,
            has_playback: true,
            has_request: true,
            has_media_item: true,
            has_loaded_source: true,
            current_position_seconds: Some(1.25),
            request_resume_seconds: Some(80.5),
        }
    }
    #[test]
    fn manual_retry_preserves_threshold_fallback_and_loading_guard() {
        for (current, expected) in [
            (None, Some(80.5)),
            (Some(-1.0), Some(80.5)),
            (Some(29.999999), Some(80.5)),
            (Some(30.0), Some(30.0)),
            (Some(150.25), Some(150.25)),
        ] {
            let mut r = request(Mode::Manual);
            r.current_position_seconds = current;
            let p = plan(r).unwrap();
            assert_eq!(p.action, Action::Reprepare);
            assert_eq!(p.resume_seconds, expected);
        }
        let mut r = request(Mode::Manual);
        r.loading = true;
        assert_eq!(plan(r).unwrap().action, Action::None);
        let mut r = request(Mode::Manual);
        r.has_media_item = false;
        assert_eq!(plan(r).unwrap().action, Action::RetryLast);
        let mut r = request(Mode::Manual);
        r.has_playback = false;
        r.has_request = false;
        r.current_position_seconds = None;
        r.request_resume_seconds = None;
        let p = plan(r).unwrap();
        assert_eq!(p.action, Action::Reprepare);
        assert_eq!(p.resume_seconds, None);
    }
    #[test]
    fn background_rebuild_trusts_loaded_position_including_zero() {
        for current in [0.0, 1.25, 29.999999, 30.0, 150.25] {
            let mut r = request(Mode::Background);
            r.current_position_seconds = Some(current);
            r.loading = true;
            let p = plan(r).unwrap();
            assert_eq!(p.action, Action::Reprepare);
            assert_eq!(p.resume_seconds, Some(current));
        }
        let mut r = request(Mode::Background);
        r.has_loaded_source = false;
        r.has_media_item = false;
        let p = plan(r).unwrap();
        assert_eq!(p.action, Action::Reopen);
        assert_eq!(p.resume_seconds, Some(80.5));
        for missing in [true, false] {
            let mut r = request(Mode::Background);
            if missing {
                r.has_playback = false
            } else {
                r.has_request = false
            };
            assert_eq!(plan(r).unwrap().action, Action::None);
        }
    }
    #[test]
    fn invalid_recovery_positions_are_rejected() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut r = request(Mode::Manual);
            r.current_position_seconds = Some(value);
            assert!(plan(r).is_err());
            let mut r = request(Mode::Background);
            r.request_resume_seconds = Some(value);
            assert!(plan(r).is_err());
        }
    }
}
