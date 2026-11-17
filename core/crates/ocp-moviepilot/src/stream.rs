use crate::{MoviePilotError, SearchProgress, TorrentResult};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;

#[derive(Debug, Clone, Serialize)]
pub struct SearchUpdate {
    pub items: Vec<TorrentResult>,
    pub progress: SearchProgress,
}

/// Incremental SSE decoder. Buffer bytes until a line boundary so split UTF-8 is safe.
#[derive(Default)]
pub struct StreamDecoder {
    line: Vec<u8>,
    data: String,
    after_cr: bool,
    items: Vec<TorrentResult>,
    seen: HashSet<String>,
    done: bool,
}

impl StreamDecoder {
    pub fn is_done(&self) -> bool {
        self.done
    }
    pub fn into_items(self) -> Vec<TorrentResult> {
        self.items
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SearchUpdate>, MoviePilotError> {
        let mut updates = Vec::new();
        for &byte in bytes {
            if self.done {
                break;
            }
            if self.after_cr && byte == b'\n' {
                self.after_cr = false;
                continue;
            }
            self.after_cr = byte == b'\r';
            if matches!(byte, b'\r' | b'\n') {
                if let Some(update) = self.consume_line()? {
                    updates.push(update);
                }
            } else {
                self.line.push(byte);
                if self.line.len() + self.data.len() > 8 * 1024 * 1024 {
                    return Err(MoviePilotError::Api("SSE event exceeds 8 MiB".into()));
                }
            }
        }
        Ok(updates)
    }

    pub fn finish(&mut self) -> Result<Vec<SearchUpdate>, MoviePilotError> {
        if self.done {
            return Ok(Vec::new());
        }
        let mut updates = Vec::new();
        if !self.line.is_empty() {
            if let Some(update) = self.consume_line()? {
                updates.push(update);
            }
        }
        if let Some(update) = self.dispatch()? {
            updates.push(update);
        }
        Ok(updates)
    }

    fn consume_line(&mut self) -> Result<Option<SearchUpdate>, MoviePilotError> {
        let line = String::from_utf8(std::mem::take(&mut self.line))
            .map_err(|_| MoviePilotError::Api("SSE contains invalid UTF-8".into()))?;
        if line.is_empty() {
            return self.dispatch();
        }
        if let Some(value) = line.strip_prefix("data:") {
            if !self.data.is_empty() {
                self.data.push('\n');
            }
            self.data.push_str(value.strip_prefix(' ').unwrap_or(value));
        }
        Ok(None)
    }

    fn dispatch(&mut self) -> Result<Option<SearchUpdate>, MoviePilotError> {
        let data = std::mem::take(&mut self.data);
        if data.trim().is_empty() {
            return Ok(None);
        }
        let event: Value = serde_json::from_str(&data)?;
        let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
        if kind == "error" {
            return Err(MoviePilotError::Api(
                event
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("torrent search failed")
                    .into(),
            ));
        }
        if kind == "replace" {
            self.items.clear();
            self.seen.clear();
        }
        if matches!(kind, "append" | "replace" | "done" | "finish" | "finished") {
            for item in event
                .get("items")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(torrent) = item.get("torrent_info").filter(|v| v.is_object()) else {
                    continue;
                };
                let key = torrent
                    .get("enclosure")
                    .and_then(Value::as_str)
                    .or_else(|| torrent.get("title").and_then(Value::as_str))
                    .map(str::to_owned)
                    .unwrap_or_else(|| torrent.to_string());
                if self.seen.insert(key) {
                    self.items.push(TorrentResult {
                        torrent: torrent.clone(),
                        meta: item.get("meta_info").cloned(),
                    });
                }
            }
        }
        self.done = matches!(kind, "done" | "finish" | "finished");
        let count = |name| {
            event
                .get(name)
                .and_then(Value::as_u64)
                .unwrap_or(0)
                .min(u32::MAX as u64) as u32
        };
        Ok(Some(SearchUpdate {
            items: self.items.clone(),
            progress: SearchProgress {
                text: event.get("text").and_then(Value::as_str).map(str::to_owned),
                finished: count("finished"),
                total: count("total"),
                total_items: count("total_items"),
            },
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arbitrary_chunks_preserve_utf8_replace_and_final_items() {
        let stream = concat!(
            "data: {\"type\":\"append\",\"items\":[{\"torrent_info\":{\"enclosure\":\"old\"}}]}\r\n\r\n",
            ": heartbeat\n\n",
            "data: {\"type\":\"replace\",\n",
            "data: \"text\":\"搜索\",\"items\":[{\"torrent_info\":{\"enclosure\":\"new\",\"seeders\":0}}]}\n\n",
            "data: {\"type\":\"done\",\"finished\":2,\"total\":2,\"items\":[{\"torrent_info\":{\"enclosure\":\"new\"}},{\"torrent_info\":{\"enclosure\":\"last\"}}]}\n\n",
            "data: invalid trailing data\n\n"
        );
        for chunk_size in 1..=stream.len() {
            let mut decoder = StreamDecoder::default();
            let mut updates = Vec::new();
            for chunk in stream.as_bytes().chunks(chunk_size) {
                updates.extend(decoder.push(chunk).unwrap());
            }
            updates.extend(decoder.finish().unwrap());
            assert_eq!(updates.len(), 3);
            assert_eq!(updates[1].progress.text.as_deref(), Some("搜索"));
            assert_eq!(updates[2].progress.finished, 2);
            let items = decoder.into_items();
            assert_eq!(items.len(), 2);
            assert_eq!(items[0].torrent["seeders"], 0);
            assert_eq!(items[1].torrent["enclosure"], "last");
        }
    }
}
