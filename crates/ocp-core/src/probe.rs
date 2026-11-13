//! A probe connection pool whose executor has the same lifetime as its Core.

use std::time::{Duration, Instant};

use reqwest::{header, Client, Url};
use serde_json::{json, Value};

use crate::CommandError;

pub(crate) async fn run(client: Client, arguments: Value) -> Result<Value, CommandError> {
    let raw_url = arguments
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| CommandError::invalid("url is required"))?;
    let mut target = Url::parse(raw_url).map_err(|_| CommandError::invalid("invalid probe URL"))?;
    if !matches!(target.scheme(), "http" | "https") || target.host_str().is_none() {
        return Err(CommandError::invalid(
            "probe URL must use HTTP(S) with a host",
        ));
    }
    let path = format!("{}/System/Info/Public", target.path().trim_end_matches('/'));
    target.set_path(&path);
    target.set_fragment(None);
    let timeout = match arguments.get("timeout") {
        Some(value) => value
            .as_f64()
            .filter(|value| value.is_finite() && *value > 0.0)
            .and_then(|value| Duration::try_from_secs_f64(value).ok())
            .ok_or_else(|| CommandError::invalid("timeout must be a finite positive number"))?,
        None => Duration::from_secs(2),
    };
    let optional_string = |key: &str| -> Result<Option<String>, CommandError> {
        match arguments.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(value)) => Ok(Some(value.clone())),
            _ => Err(CommandError::invalid(format!(
                "{key} must be a string or null"
            ))),
        }
    };
    let authorization = optional_string("authorizationHeader")?;
    let user_agent = optional_string("userAgent")?;
    let expected = optional_string("expectedServerID")?;
    let raw_url = raw_url.to_owned();
    let start = Instant::now();
    let mut request = client
        .get(target)
        .header(header::ACCEPT, "application/json")
        .timeout(timeout);
    if let Some(authorization) = authorization {
        request = request.header(header::AUTHORIZATION, authorization);
    }
    if let Some(user_agent) = user_agent {
        request = request.header(header::USER_AGENT, user_agent);
    }
    let Ok(mut response) = request.send().await else {
        return Ok(Value::Null);
    };
    if !response.status().is_success() {
        return Ok(Value::Null);
    }
    let mut bytes = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if bytes.len() + chunk.len() <= 64 * 1024 => {
                bytes.extend_from_slice(&chunk)
            }
            Ok(None) => break,
            _ => return Ok(Value::Null),
        }
    }
    let Ok(info) = serde_json::from_slice::<ocp_jellyfin::ServerInfo>(&bytes) else {
        return Ok(Value::Null);
    };
    if ![
        &info.id,
        &info.server_name,
        &info.product_name,
        &info.version,
    ]
    .iter()
    .any(|value| value.as_ref().is_some_and(|value| !value.is_empty()))
    {
        return Ok(Value::Null);
    }
    if expected
        .as_ref()
        .zip(info.id.as_ref())
        .is_some_and(|(expected, actual)| !actual.is_empty() && expected != actual)
    {
        return Ok(Value::Null);
    }
    Ok(
        json!({"url": raw_url, "latency": start.elapsed().as_secs_f64(), "serverID": info.id,
                "serverName": info.server_name, "productName": info.product_name, "version": info.version}),
    )
}
