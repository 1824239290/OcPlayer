from pathlib import Path
core=Path('/Volumes/Backup/软件/OcPlayer-Core'); native=Path('/Users/jumusu/Documents/project/OcPlayer')
p=core/'crates/ocp-core/src/lib.rs';s=p.read_text();s=s.replace('value.get("Items").filter(|v| !v.is_null()).cloned().unwrap_or_else(|| json!([]))','nullable_response_items(&value)?');s=s.replace('let value = client.raw_get("Items", params).await?;\n                    Ok(value)','let mut value = client.raw_get("Items", params).await?;\n                    value["Items"] = json!(nullable_response_items(&value)?);\n                    Ok(value)');s=s.replace('let value = client\n                        .raw_get("Items", vec![("ids", id.to_owned()), ("fields", "MediaSources".into())])\n                        .await?;\n                    Ok(value)','let mut value = client\n                        .raw_get("Items", vec![("ids", id.to_owned()), ("fields", "MediaSources".into())])\n                        .await?;\n                    value["Items"] = json!(nullable_response_items(&value)?);\n                    Ok(value)');marker='struct CommandError(i32, bool, String);';s=s.replace(marker,'''// Raw media endpoints share the native nullable query-result envelope.
// Only absent/null Items default to empty; a malformed non-null container is a decode error.
fn nullable_response_items(value: &Value) -> Result<Vec<Value>, CommandError> {
    let object = value.as_object().ok_or_else(|| CommandError(1514, false, "expected media query-result object".into()))?;
    serde_json::from_value::<Option<Vec<Value>>>(object.get("Items").cloned().unwrap_or(Value::Null))
        .map(|items| items.unwrap_or_default())
        .map_err(|error| CommandError(1514, false, error.to_string()))
}

'''+marker);p.write_text(s)
p=native/'Packages/JellyfinKit/Sources/JellyfinKit/RustCoreMediaServer.swift';s=p.read_text();s=s.replace('values.decodeFirst([RustMediaItem]', 'try values.decodeFirstPresent([RustMediaItem]').replace('values.decodeFirst([RustMediaSource]', 'try values.decodeFirstPresent([RustMediaSource]').replace('values.decodeFirst([RustMediaStream]', 'try values.decodeFirstPresent([RustMediaStream]');marker='    func decodeFirst<T: Decodable>';s=s.replace(marker,'''    func decodeFirstPresent<T: Decodable>(_ type: T.Type, keys: [String]) throws -> T? {
        for key in keys {
            let codingKey = RustCodingKey(stringValue: key)
            guard contains(codingKey) else { continue }
            if let value = try decodeIfPresent(type, forKey: codingKey) { return value }
        }
        return nil
    }

'''+marker);p.write_text(s)
p=core/'tests/media_nullable_server.py';s=p.read_text();s=s.replace("self.send(self.list([{'Id':'item','MediaSources':None}]));return",'''source={'Id':'source','Name':'原盘','Size':9223372036854775807,'Path':'/原盘/片.mkv','SupportsDirectPlay':True,'RunTimeTicks':72002500000,'MediaStreams':None}
   case=self.case()
   if case=='no_streams':source.pop('MediaStreams')
   if case=='empty_streams':source['MediaStreams']=[]
   if case=='wrong_streams':source['MediaStreams']='bad'
   item={'Id':'item','MediaSources':[source]}
   if case=='null_sources':item['MediaSources']=None
   if case=='missing_sources':item.pop('MediaSources')
   if case=='wrong_sources':item['MediaSources']=1
   self.send(self.list([item]));return''');p.write_text(s);(native/'Packages/JellyfinKit/Tests/JellyfinKitTests/Fixtures/media_nullable_server.py').write_text(s)
p=native/'Packages/JellyfinKit/Tests/JellyfinKitTests/MediaNullableHTTPTests.swift';s=p.read_text();marker='    func testPreparationWithNullStreams';s=s.replace(marker,'''    func testNullableRawMediaContainersAndMalformedArraysMatchNative() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["containers_missing", "containers_null", "containers_empty", "null_sources", "missing_sources", "null_streams", "no_streams", "empty_streams"] {
                try await paired(name, kind: kind) { native, core in
                    let expectedSubtitles = try await native.externalSubtitles(itemID: "item")
                    let actualSubtitles = try await core.externalSubtitles(itemID: "item")
                    XCTAssertEqual(actualSubtitles, expectedSubtitles)
                    let expected = try await native.mediaFileInfo(itemID: "item"), actual = try await core.mediaFileInfo(itemID: "item")
                    XCTAssertEqual(try self.encoded(actual), try self.encoded(expected), "file info \\(kind)/\\(name)")
                }
            }
            for name in ["wrong_list", "wrong_sources", "wrong_streams"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        for operation in 0...1 {
                            do {
                                if operation == 0 { _ = try await server.externalSubtitles(itemID: "item") }
                                else { _ = try await server.mediaFileInfo(itemID: "item") }
                                XCTFail("Unexpected raw-media success: \\(kind)/\\(name)")
                            } catch { XCTAssertFalse(error is CancellationError) }
                        }
                        if name == "wrong_list" {
                            do { _ = try await server.mediaSegments(itemID: "item"); XCTFail("Unexpected segments success") }
                            catch { XCTAssertFalse(error is CancellationError) }
                        }
                    }
                }
            }
        }
    }
'''+marker);p.write_text(s)
