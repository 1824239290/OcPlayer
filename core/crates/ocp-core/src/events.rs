//! Bounded, lossy delivery of notifications. Snapshots and command responses
//! remain authoritative when a consumer falls behind.

use std::collections::VecDeque;
use std::io::{self, Write};

use ocp_model::Event;
use serde_json::Value;

pub(crate) const MAX_EVENTS: usize = 256;
pub(crate) const MAX_EVENT_BYTES: usize = 1024 * 1024;

#[derive(PartialEq, Eq)]
enum TelemetryKey {
    RenderTick,
    PlaybackPosition,
    MoviePilotSearch(Option<String>),
}

struct QueuedEvent {
    json: String,
    telemetry: Option<TelemetryKey>,
}

#[derive(Default)]
pub(crate) struct EventQueue {
    entries: VecDeque<QueuedEvent>,
    bytes: usize,
    last_sequence: u64,
    coalesced: u64,
    dropped: u64,
}

// Stop serialization at the budget instead of temporarily allocating an
// arbitrarily large second copy of a search projection or source payload.
#[derive(Default)]
struct BoundedBuffer(Vec<u8>);

impl Write for BoundedBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_EVENT_BYTES - self.0.len() {
            return Err(io::Error::other("event exceeds queue byte budget"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl EventQueue {
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn diagnostics(&self) -> Value {
        serde_json::json!({
            "depth": self.len(),
            "bytes": self.bytes,
            "capacity": MAX_EVENTS,
            "byteCapacity": MAX_EVENT_BYTES,
            "lastSequence": self.last_sequence,
            "coalesced": self.coalesced,
            "dropped": self.dropped,
        })
    }

    pub(crate) fn pop_front(&mut self) -> Option<String> {
        let event = self.entries.pop_front()?;
        self.bytes -= event.json.len();
        Some(event.json)
    }

    fn remove(&mut self, index: usize) {
        if let Some(event) = self.entries.remove(index) {
            self.bytes -= event.json.len();
        }
    }

    pub(crate) fn push(&mut self, kind: &str, data: Value) {
        self.last_sequence = self.last_sequence.saturating_add(1);
        let telemetry = match kind {
            "render.tick" => Some(TelemetryKey::RenderTick),
            "playback.position" => Some(TelemetryKey::PlaybackPosition),
            "moviepilot.searchProgress" => Some(TelemetryKey::MoviePilotSearch(
                data.get("requestId")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            )),
            _ => None,
        };
        let event = Event {
            sequence: self.last_sequence,
            kind: kind.to_owned(),
            data,
        };
        let mut buffer = BoundedBuffer::default();
        if serde_json::to_writer(&mut buffer, &event).is_err() {
            self.dropped = self.dropped.saturating_add(1);
            return;
        }
        // serde_json emits valid UTF-8, including escaped control characters.
        let json = String::from_utf8(buffer.0).expect("serialized event is UTF-8");

        if telemetry.is_some() {
            if let Some(index) = self
                .entries
                .iter()
                .position(|entry| entry.telemetry == telemetry)
            {
                self.remove(index);
                self.coalesced = self.coalesced.saturating_add(1);
            }
        }
        while self.len() >= MAX_EVENTS || self.bytes + json.len() > MAX_EVENT_BYTES {
            let oldest_telemetry = self
                .entries
                .iter()
                .position(|entry| entry.telemetry.is_some());
            match oldest_telemetry {
                Some(index) => self.remove(index),
                // A new telemetry update cannot displace control/error events.
                None if telemetry.is_some() => {
                    self.dropped = self.dropped.saturating_add(1);
                    return;
                }
                None => self.remove(0),
            }
            self.dropped = self.dropped.saturating_add(1);
        }
        self.bytes += json.len();
        self.entries.push_back(QueuedEvent { json, telemetry });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn drain(queue: &mut EventQueue) -> Vec<Event> {
        let mut events = Vec::new();
        while let Some(event) = queue.pop_front() {
            events.push(serde_json::from_str(&event).unwrap());
        }
        assert_eq!(queue.bytes, 0);
        events
    }

    #[test]
    fn coalescing_preserves_control_order_and_separates_search_requests() {
        let mut queue = EventQueue::default();
        queue.push("playback.opened", json!({}));
        queue.push("playback.position", json!({"positionSeconds": 1}));
        queue.push("playback.pause", json!({}));
        queue.push("playback.position", json!({"positionSeconds": 2}));
        queue.push(
            "moviepilot.searchProgress",
            json!({"requestId":"a", "progress":1}),
        );
        queue.push(
            "moviepilot.searchProgress",
            json!({"requestId":"b", "progress":2}),
        );
        queue.push(
            "moviepilot.searchProgress",
            json!({"requestId":"a", "progress":3}),
        );
        let events = drain(&mut queue);
        assert_eq!(
            events
                .iter()
                .map(|event| event.sequence)
                .collect::<Vec<_>>(),
            [1, 3, 4, 6, 7]
        );
        assert_eq!(events[2].data["positionSeconds"], 2);
        assert_eq!(events[3].data["requestId"], "b");
        assert_eq!(events[4].data["progress"], 3);
        assert_eq!(queue.coalesced, 2);
        assert_eq!(queue.dropped, 0);
    }

    #[test]
    fn overflow_prefers_controls_and_retains_latest_errors() {
        let mut queue = EventQueue::default();
        queue.push("render.tick", json!({"timeSeconds":1}));
        for index in 0..MAX_EVENTS - 1 {
            queue.push("playback.seek", json!({"positionSeconds":index}));
        }
        queue.push("playback.failed", json!({"message":"decoder unavailable"}));
        assert_eq!(queue.len(), MAX_EVENTS);
        assert!(queue.entries.iter().all(|entry| entry.telemetry.is_none()));
        queue.push("render.tick", json!({"timeSeconds":2}));
        queue.push("playback.ended", json!({}));
        let events = drain(&mut queue);
        assert_eq!(events.first().unwrap().data["positionSeconds"], 1);
        assert_eq!(events[events.len() - 2].kind, "playback.failed");
        assert_eq!(events.last().unwrap().kind, "playback.ended");
        assert_eq!(queue.dropped, 3);
    }

    #[test]
    fn bytes_are_bounded_and_oversized_update_preserves_last_usable_projection() {
        let mut queue = EventQueue::default();
        let payload = "x".repeat(MAX_EVENT_BYTES / 3);
        for index in 0..20 {
            queue.push("settings.changed", json!({"index":index, "value":payload}));
            assert!(queue.bytes <= MAX_EVENT_BYTES);
        }
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.dropped, 18);
        drain(&mut queue);
        queue.push(
            "moviepilot.searchProgress",
            json!({"requestId":"a", "progress":5}),
        );
        queue.push(
            "moviepilot.searchProgress",
            json!({"requestId":"a", "items":["x".repeat(MAX_EVENT_BYTES)]}),
        );
        assert_eq!(queue.len(), 1);
        assert_eq!(queue.coalesced, 0);
        assert_eq!(drain(&mut queue)[0].data["progress"], 5);
        assert_eq!(queue.dropped, 19);
    }
}
