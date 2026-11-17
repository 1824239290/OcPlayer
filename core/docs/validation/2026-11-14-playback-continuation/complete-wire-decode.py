from pathlib import Path
import shutil
core=Path('/Volumes/Backup/软件/OcPlayer-Core');native=Path('/Users/jumusu/Documents/project/OcPlayer')
for name in ['OcpPlaybackFlow','OcpPlaybackEvents','OcpDanmakuLoader']:
 p=core/'bindings/apple/OcPlayerCore/Sources/OcPlayerCore'/str(name+'.swift')
 s=p.read_text().replace('response.data.decode(', 'response.decodeData(');p.write_text(s)
 shutil.copy2(p,native/'Packages/OcPlayerCore/Sources/OcPlayerCore'/p.name)
p=core/'bindings/apple/OcPlayerCore/Tests/OcPlayerCoreTests/OcpPlaybackPreparationTests.swift';s=p.read_text();marker='        XCTAssertEqual(snapshot.generation, .max); XCTAssertEqual(snapshot.playbackRequestId, "opaque")'
s=s.replace(marker,marker+'''
        let events = """
        {"ok":true,"code":0,"retryable":false,"message":"","data":{"generation":18446744073709551615,"state":"playing","positionSeconds":1.25,"durationSeconds":7200.5,"errorCount":18446744073709551614,"failure":{"code":-2147483648,"message":"原始错误"},"foldedStaleTailFailure":false}}
        """
        let eventResponse = try OcpResponse.fromWire(Data(events.utf8))
        let event = try eventResponse.decodeData(OcpPlaybackEvents.Snapshot.self)
        XCTAssertEqual(event.generation, .max); XCTAssertEqual(event.errorCount, .max-1)
        XCTAssertEqual(event.failure?.code, .min); XCTAssertEqual(event.failure?.message, "原始错误")''')
p.write_text(s);shutil.copy2(p,native/'Packages/OcPlayerCore/Tests/OcPlayerCoreTests'/p.name)
for p in [core/'docs/playback-continuation-contract.md',native/'Docs/SHARED-PLAYBACK-CONTINUATION.md']:
 s=p.read_text().replace('Apple recovery plans, request-chain snapshots and preparation receipts decode\noriginal wire bytes.','All typed Apple SDK response envelopes, including initialization, recovery plans,\nrequest-chain and engine-event snapshots and preparation receipts, decode original\nwire bytes.')
 p.write_text(s)
