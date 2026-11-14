from pathlib import Path
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer')
p=core/'crates/ocp-core/src/lib.rs';s=p.read_text();needle='''                    let value = client
                        .raw_get(
                            &format!("MediaSegments/{id}"),''';replacement='''                    if matches!(client.profile.kind, ocp_jellyfin::ServerKind::Emby) {
                        let detail = client.raw_get(&format!("Items/{id}"), vec![("fields", "Chapters".into())]).await?;
                        return Ok(json!({"items": emby_media_segments(id, detail)?}));
                    }
                    let value = client
                        .raw_get(
                            &format!("MediaSegments/{id}"),''';assert needle in s;s=s.replace(needle,replacement)
marker='// Raw media endpoints share';helper='''// Emby exposes intro/credits markers in Chapters rather than Jellyfin's plugin endpoint.
fn emby_media_segments(id: &str, detail: Value) -> Result<Vec<Value>, CommandError> {
    #[derive(serde::Deserialize)]
    struct Chapter {
        #[serde(rename = "StartPositionTicks")]
        start: Option<i64>,
        #[serde(rename = "MarkerType")]
        marker: Option<Value>,
    }
    #[derive(serde::Deserialize)]
    struct Detail {
        #[serde(rename = "Chapters")]
        chapters: Option<Vec<Chapter>>,
        #[serde(rename = "RunTimeTicks")]
        runtime: Option<i64>,
    }
    let detail: Detail = serde_json::from_value(detail).map_err(|error| CommandError(1514, false, error.to_string()))?;
    let mut starts = Vec::new();
    let (mut intro, mut end, mut credits) = (None, None, None);
    for chapter in detail.chapters.unwrap_or_default() {
        let Some(ticks) = chapter.start else { continue };
        starts.push(ticks);
        let marker = chapter.marker.unwrap_or(Value::Null);
        let name = marker.as_str().map(str::to_ascii_lowercase);
        match (marker.as_i64(), name.as_deref()) {
            (Some(1), _) | (_, Some("introstart")) => { intro.get_or_insert(ticks); }
            (Some(2), _) | (_, Some("introend")) => { end.get_or_insert(ticks); }
            (Some(3), _) | (_, Some("creditsstart")) => { credits.get_or_insert(ticks); }
            _ => {}
        }
    }
    if let Some(start) = intro {
        if end.is_none() { end = starts.into_iter().filter(|ticks| *ticks > start).min(); }
    }
    let mut segments = Vec::new();
    if let (Some(start), Some(end)) = (intro, end) {
        if end > start { segments.push(json!({"Id":format!("emby-intro-{id}"),"ItemId":id,"Type":"Intro","StartTicks":start,"EndTicks":end})); }
    }
    if let (Some(start), Some(end)) = (credits, detail.runtime) {
        if end > start { segments.push(json!({"Id":format!("emby-credits-{id}"),"ItemId":id,"Type":"Outro","StartTicks":start,"EndTicks":end})); }
    }
    Ok(segments)
}

''';s=s.replace(marker,helper+marker);p.write_text(s)
p=core/'tests/media_nullable_server.py';s=p.read_text();s=s.replace("  if case=='missing_identity':",'''  if case in ('emby_markers','emby_marker_fallback','emby_marker_unknown'):
   item['Chapters']=[{'StartPositionTicks':100000000,'MarkerType':1},{'StartPositionTicks':200000000,'MarkerType':'IntroEnd'},{'StartPositionTicks':70000000000,'MarkerType':'CREDITSSTART'}]
   if case=='emby_marker_fallback':item['Chapters'][1]['MarkerType']=0
   if case=='emby_marker_unknown':item['Chapters']=[{'StartPositionTicks':1,'MarkerType':{'bad':True}},{'StartPositionTicks':2,'MarkerType':99},{'MarkerType':'IntroStart'}]
  if case=='missing_identity':''');p.write_text(s);(native/'Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_nullable_server.py').write_text(s)
p=native/'Packages/JellyfinKit/Tests/JellyfinKitTests/MediaNullableHTTPTests.swift';s=p.read_text().replace('if name == "wrong_list" {\n                            do { _ = try await server.mediaSegments','if name == "wrong_list" && kind == .jellyfin {\n                            do { _ = try await server.mediaSegments');marker='    func testPreparationWithNullStreams';s=s.replace(marker,'''    func testEmbyChapterMarkersAndFallbackRetainNativeSegments() async throws {
        for name in ["emby_markers", "emby_marker_fallback", "emby_marker_unknown"] {
            try await paired(name, kind: .emby) { native, core in
                let expected = try await native.mediaSegments(itemID: "item"), actual = try await core.mediaSegments(itemID: "item")
                XCTAssertEqual(actual, expected)
                if name != "emby_marker_unknown" {
                    XCTAssertEqual(actual.count, 2); XCTAssertEqual(actual.first?.startSeconds, 10)
                    XCTAssertEqual(actual.first?.endSeconds, 20); XCTAssertEqual(actual.last?.startSeconds, 7000)
                    XCTAssertEqual(actual.last?.endSeconds, 7200.25)
                } else { XCTAssertTrue(actual.isEmpty) }
            }
        }
    }
'''+marker);p.write_text(s)
p=core/'tests/media_nullable_contract.py';s=p.read_text().replace("            for case, command in cases:\n", "            for case, command in cases:\n                if kind=='emby' and command=='media.segments': continue\n");needle="            item = self.success('browse.detail', profile=self.profile('missing_identity',kind), itemId='item')";s=s.replace(needle,'''            if kind=='emby':
                for case in ('emby_markers','emby_marker_fallback'):
                    segments=self.success('media.segments', profile=self.profile(case,kind), itemId='item')['items']
                    self.assertEqual([v['Id'] for v in segments], ['emby-intro-item','emby-credits-item'])
                    self.assertEqual(segments[0]['StartTicks'], 100000000); self.assertEqual(segments[0]['EndTicks'], 200000000)
                    self.assertEqual(segments[1]['EndTicks'], 72002500000)
                self.assertEqual(self.success('media.segments', profile=self.profile('emby_marker_unknown',kind), itemId='item')['items'], [])
'''+needle);p.write_text(s)
