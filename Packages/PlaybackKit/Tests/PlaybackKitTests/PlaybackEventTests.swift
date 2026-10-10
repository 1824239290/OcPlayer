import DiagnosticsKit
import Foundation
import Testing
@testable import PlaybackKit

/// 播放生命周期事件的**名字与字段**契约。
///
/// 这些字符串是给排障脚本 grep 的：改名或改字段名不会让任何代码编译失败，
/// 只会让「按 event 过滤拉出一次播放的时间线」这条工作流悄悄失效。所以钉住。
@Suite("播放事件契约")
struct PlaybackEventTests {

    @Test("事件名保持稳定（脚本按这些字符串过滤日志）")
    func eventNamesAreStable() {
        let expected: [PlaybackEvent: String] = [
            .openStart: "open.start",
            .openDone: "open.done",
            .firstFrame: "first_frame",
            .bufferStart: "buffer.start",
            .bufferEnd: "buffer.end",
            .stall: "stall",
            .seek: "seek",
            .error: "error",
            .decoderChanged: "decoder.changed",
            .sessionEnd: "session.end",
        ]
        for (event, raw) in expected {
            #expect(event.rawValue == raw)
        }
        // 反向：不许有事件漏进这份清单（新增事件时应该连同名字一起被审一遍）。
        #expect(Set(PlaybackEvent.allCases) == Set(expected.keys))
    }

    @Test("decoder.changed 带毫秒位置：硬解掉软解那一刻能和进度对上")
    func decoderChangedFields() {
        let fields = PlaybackEvent.decoderChangedFields(position: .seconds(95) + .milliseconds(500))
        #expect(fields == ["position_ms": .integer(95_500)])
    }
}
