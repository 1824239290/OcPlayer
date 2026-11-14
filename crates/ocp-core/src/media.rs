//! Platform-neutral media-source selection and file/subtitle projection.
//! Raw server fields stay in the reply for existing consumers and plugins.
use super::CommandError;
use ocp_jellyfin::ServerKind;
use ocp_session::preparation::{preferred_source, Source as Candidate};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Envelope {
    items: Option<Vec<Item>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Item {
    media_sources: Option<Vec<Source>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Source {
    id: Option<String>,
    path: Option<String>,
    container: Option<String>,
    size: Option<i64>,
    supports_direct_play: Option<bool>,
    supports_direct_stream: Option<bool>,
    run_time_ticks: Option<i64>,
    media_streams: Option<Vec<Stream>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Stream {
    #[serde(rename = "Type")]
    kind: Option<String>,
    index: Option<i64>,
    codec: Option<String>,
    language: Option<String>,
    title: Option<String>,
    display_title: Option<String>,
    is_external: Option<bool>,
    is_default: Option<bool>,
    is_forced: Option<bool>,
    width: Option<i64>,
    height: Option<i64>,
    bit_rate: Option<i64>,
    average_frame_rate: Option<f64>,
    real_frame_rate: Option<f64>,
    bit_depth: Option<i64>,
    color_primaries: Option<String>,
    color_transfer: Option<String>,
    color_space: Option<String>,
    color_range: Option<String>,
    video_range_type: Option<String>,
    profile: Option<String>,
    is_interlaced: Option<bool>,
    channels: Option<i64>,
    channel_layout: Option<String>,
    sample_rate: Option<i64>,
}
fn decode_error(message: impl ToString) -> CommandError {
    CommandError(1514, false, message.to_string())
}
fn valid_frame_rate(average: Option<f64>, real: Option<f64>) -> Option<f64> {
    average
        .filter(|v| *v > 0.0 && *v < 1000.0)
        .or_else(|| real.filter(|v| *v > 0.0 && *v < 1000.0))
}
fn native_frame_rate(average: Option<f64>, real: Option<f64>, kind: &ServerKind) -> Option<f64> {
    if matches!(kind, ServerKind::Jellyfin) {
        // The reference SDK decodes these two fields as Float before converting to Double.
        valid_frame_rate(
            average.map(|v| v as f32 as f64),
            real.map(|v| v as f32 as f64),
        )
    } else {
        valid_frame_rate(average, real)
    }
}
fn file_name(path: Option<&str>) -> Option<&str> {
    let path = path?;
    if path.is_empty() {
        return None;
    }
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return Some("/");
    }
    trimmed.rsplit('/').next()
}
fn text_codec(codec: &str) -> bool {
    matches!(codec, "srt" | "subrip" | "ass" | "ssa" | "vtt" | "webvtt")
}
fn preferred(sources: &[Source]) -> Option<usize> {
    preferred_source(
        &sources
            .iter()
            .enumerate()
            .map(|(index, source)| Candidate {
                key: index.to_string(),
                id: source.id.clone().unwrap_or_default(),
                supports_direct_play: source.supports_direct_play,
                supports_direct_stream: source.supports_direct_stream,
            })
            .collect::<Vec<_>>(),
    )
}
fn validate_jellyfin(sources: &[Source]) -> Result<(), CommandError> {
    for stream in sources
        .iter()
        .flat_map(|s| s.media_streams.as_deref().unwrap_or_default())
    {
        if [stream.average_frame_rate, stream.real_frame_rate]
            .into_iter()
            .flatten()
            .any(|rate| !(rate as f32).is_finite() || (rate != 0.0 && rate as f32 == 0.0))
        {
            return Err(decode_error(
                "Jellyfin frame rate is not representable as Float32",
            ));
        }
        if let Some(kind) = stream.kind.as_deref() {
            if !matches!(
                kind,
                "Audio" | "Video" | "Subtitle" | "EmbeddedImage" | "Data" | "Lyric"
            ) {
                return Err(decode_error(format!(
                    "unknown Jellyfin MediaStreamType: {kind}"
                )));
            }
        }
        if let Some(range) = stream.video_range_type.as_deref() {
            if !matches!(
                range,
                "Unknown"
                    | "SDR"
                    | "HDR10"
                    | "HLG"
                    | "DOVI"
                    | "DOVIWithHDR10"
                    | "DOVIWithHLG"
                    | "DOVIWithSDR"
                    | "DOVIWithEL"
                    | "DOVIWithHDR10Plus"
                    | "DOVIWithELHDR10Plus"
                    | "DOVIInvalid"
                    | "HDR10Plus"
            ) {
                return Err(decode_error(format!(
                    "unknown Jellyfin VideoRangeType: {range}"
                )));
            }
        }
    }
    Ok(())
}
fn subtitle_projection(sources: &[Source], item: &str, selected: Option<&str>) -> Value {
    let index = match selected {
        Some(id) => sources
            .iter()
            .position(|source| source.id.as_deref() == Some(id)),
        None => preferred(sources),
    };
    let Some(source) = index.map(|i| &sources[i]) else {
        return json!([]);
    };
    Value::Array(source.media_streams.as_deref().unwrap_or_default().iter().filter_map(|stream| {
        if stream.kind.as_deref() != Some("Subtitle") || stream.is_external != Some(true) { return None; }
        let index = stream.index?;
        let codec = stream.codec.as_ref()?.to_lowercase();
        if !text_codec(&codec) { return None; }
        Some(json!({"itemId":item,"mediaSourceId":source.id,"index":index,"codec":codec,
            "title":stream.title.as_ref().or(stream.display_title.as_ref()),"language":stream.language}))
    }).collect())
}
fn file_projection(sources: &[Source], kind: &ServerKind) -> Value {
    let Some(index) = preferred(sources) else {
        return Value::Null;
    };
    let source = &sources[index];
    let streams = source.media_streams.as_deref().unwrap_or_default();
    let video = streams.iter().find(|s| s.kind.as_deref() == Some("Video")).map(|s| json!({
        "codec":s.codec,"width":s.width,"height":s.height,"bitrate":s.bit_rate,
        "frameRate":native_frame_rate(s.average_frame_rate,s.real_frame_rate,kind),"bitDepth":s.bit_depth,
        "colorPrimaries":s.color_primaries,"colorTransfer":s.color_transfer,"colorSpace":s.color_space,
        "colorRange":s.color_range,"videoRangeType":s.video_range_type,"profile":s.profile,
        "isInterlaced":s.is_interlaced.unwrap_or(false)
    }));
    let audio: Vec<_> = streams.iter().filter(|s| s.kind.as_deref() == Some("Audio")).map(|s| json!({
        "codec":s.codec,"channels":s.channels,"channelLayout":s.channel_layout,"sampleRate":s.sample_rate,
        "bitrate":s.bit_rate,"language":s.language,"title":s.title,"isDefault":s.is_default.unwrap_or(false)
    })).collect();
    let subtitles: Vec<_> = streams.iter().filter(|s| s.kind.as_deref() == Some("Subtitle")).map(|s| json!({
        "codec":s.codec,"language":s.language,"title":s.title,"isDefault":s.is_default.unwrap_or(false),
        "isForced":s.is_forced.unwrap_or(false),"isExternal":s.is_external.unwrap_or(false)
    })).collect();
    json!({"video":video,"audioTracks":audio,"subtitleTracks":subtitles,"container":source.container,
        "sizeBytes":source.size,"durationSeconds":source.run_time_ticks.map(|v|v as f64/10_000_000.0),
        "fileName":file_name(source.path.as_deref()),"sourceCount":sources.len()})
}

/// Add canonical metadata without discarding the original query result.
pub(super) fn enrich(
    mut raw: Value,
    kind: &ServerKind,
    item: &str,
    selected: Option<&str>,
) -> Result<Value, CommandError> {
    let envelope: Envelope = serde_json::from_value(raw.clone()).map_err(decode_error)?;
    // Decode every source before selection, as the native DTO decoders do.
    if matches!(kind, ServerKind::Jellyfin) {
        for item in envelope.items.as_deref().unwrap_or_default() {
            validate_jellyfin(item.media_sources.as_deref().unwrap_or_default())?;
        }
    }
    let sources = envelope
        .items
        .as_deref()
        .and_then(|items| items.first())
        .and_then(|item| item.media_sources.as_deref())
        .unwrap_or_default();
    raw["subtitles"] = subtitle_projection(sources, item, selected);
    raw["fileInfo"] = file_projection(sources, kind);
    Ok(raw)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn project(sources: Value, selected: Option<&str>) -> Value {
        match enrich(
            json!({"Items":[{"MediaSources":sources}]}),
            &ServerKind::Emby,
            "item",
            selected,
        ) {
            Ok(value) => value,
            Err(error) => panic!("{}", error.2),
        }
    }
    #[test]
    fn source_priority_and_explicit_missing_identity_remain_distinct() {
        let sources = json!([{"Id":"stream","SupportsDirectStream":true,"MediaStreams":[{"Type":"Subtitle","Index":1,"Codec":"srt","IsExternal":true}]},{"Id":"play","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Subtitle","Index":2,"Codec":"ass","IsExternal":true}]}]);
        assert_eq!(project(sources.clone(), None)["subtitles"][0]["index"], 2);
        assert_eq!(
            project(sources.clone(), Some("stream"))["subtitles"][0]["index"],
            1
        );
        assert_eq!(
            project(sources.clone(), Some("missing"))["subtitles"],
            json!([])
        );
        assert_eq!(project(sources, Some(""))["subtitles"], json!([]));
    }
    #[test]
    fn frame_rate_validity_has_strict_boundaries_and_real_fallback() {
        assert_eq!(valid_frame_rate(Some(23.976), Some(60.0)), Some(23.976));
        for invalid in [0.0, -1.0, 1000.0, 1001.0] {
            assert_eq!(valid_frame_rate(Some(invalid), Some(24.0)), Some(24.0));
        }
        assert_eq!(valid_frame_rate(Some(1000.0), Some(0.0)), None);
        assert_eq!(
            native_frame_rate(Some(23.976), None, &ServerKind::Jellyfin),
            Some(23.976_f32 as f64)
        );
        assert_eq!(
            native_frame_rate(Some(999.99999), Some(25.0), &ServerKind::Jellyfin),
            Some(25.0)
        );
        assert_eq!(
            native_frame_rate(Some(999.99999), Some(25.0), &ServerKind::Emby),
            Some(999.99999)
        );
    }
    #[test]
    fn file_track_titles_do_not_use_external_subtitle_display_fallback() {
        let value = project(
            json!([{"MediaStreams":[{"Type":"Audio","DisplayTitle":"display"},{"Type":"Subtitle","DisplayTitle":"display","Index":2,"Codec":"ASS","IsExternal":true}]}]),
            None,
        );
        assert!(value["fileInfo"]["audioTracks"][0]["title"].is_null());
        assert!(value["fileInfo"]["subtitleTracks"][0]["title"].is_null());
        assert_eq!(value["subtitles"][0]["title"], "display");
        assert_eq!(value["subtitles"][0]["codec"], "ass");
    }
    #[test]
    fn nullable_sources_and_streams_keep_absence_and_exact_size() {
        assert!(project(Value::Null, None)["fileInfo"].is_null());
        let value = project(
            json!([{"Size":i64::MAX,"RunTimeTicks":72002500000_i64,"MediaStreams":null}]),
            None,
        );
        assert_eq!(value["fileInfo"]["sizeBytes"], i64::MAX);
        assert_eq!(value["fileInfo"]["durationSeconds"], 7200.25);
        assert_eq!(value["fileInfo"]["audioTracks"], json!([]));
    }
    #[test]
    fn scalar_types_fail_before_source_selection() {
        for bad in [
            json!({"Size":"bad"}),
            json!({"SupportsDirectPlay":1}),
            json!({"MediaStreams":[{"SampleRate":"48000"}]}),
            json!({"MediaStreams":[{"AverageFrameRate":"24"}]}),
        ] {
            let result = enrich(
                json!({"Items":[{"MediaSources":[bad,{"SupportsDirectPlay":true}]}]}),
                &ServerKind::Emby,
                "item",
                None,
            );
            assert!(matches!(result, Err(CommandError(1514, false, _))));
        }
    }
    #[test]
    fn subtitle_filters_keep_only_indexed_external_text_tracks() {
        let tracks = json!([{"Type":"Subtitle","Index":1,"Codec":"WEBVTT","IsExternal":true},{"Type":"Subtitle","Index":2,"Codec":"pgssub","IsExternal":true},{"Type":"Subtitle","Codec":"srt","IsExternal":true},{"Type":"subtitle","Index":3,"Codec":"srt","IsExternal":true},{"Type":"Subtitle","Index":4,"Codec":"srt","IsExternal":false}]);
        let value = project(json!([{"MediaStreams":tracks}]), None);
        assert_eq!(value["subtitles"].as_array().unwrap().len(), 1);
        assert_eq!(value["subtitles"][0]["index"], 1);
    }
    #[test]
    fn jellyfin_enums_are_validated_and_emby_unknowns_are_retained() {
        let raw = json!({"Items":[{"MediaSources":[{"MediaStreams":[{"Type":"Attachment"},{"Type":"Video","VideoRangeType":"FutureHDR"}]}]}]});
        assert!(enrich(raw.clone(), &ServerKind::Jellyfin, "item", None).is_err());
        for rate in [1e100, 1e-50] {
            assert!(enrich(
                json!({"Items":[{"MediaSources":[{"MediaStreams":[{"AverageFrameRate":rate}]}]}]}),
                &ServerKind::Jellyfin,
                "item",
                None
            )
            .is_err());
        }
        assert_eq!(
            enrich(raw, &ServerKind::Emby, "item", None).ok().unwrap()["fileInfo"]["video"]
                ["videoRangeType"],
            "FutureHDR"
        );
    }
    #[test]
    fn file_basename_retains_native_slash_rules() {
        for (path, expected) in [
            ("/原盘/片.mkv", Some("片.mkv")),
            ("/folder/", Some("folder")),
            ("/", Some("/")),
            ("", None),
            ("C:\\folder\\file.mkv", Some("C:\\folder\\file.mkv")),
        ] {
            assert_eq!(file_name(Some(path)), expected);
        }
    }
}
