import DiagnosticsKit
import MachO
import XCTest
@testable import OcPlayer

/// 内核 stderr 的分帧/分类/限速与内核 trace 开关的键位。
/// 真正的 fd 重定向是进程级副作用，单测只覆盖纯逻辑这一层。
final class KernelLoggingTests: XCTestCase {

    // MARK: - KernelStderrDecoder

    /// 管道读到的块边界与行边界无关：半行留到下一块再拼。
    func testDecoderFramesAcrossChunks() {
        var decoder = KernelStderrDecoder()
        XCTAssertEqual(decoder.ingest(Data("ErikaHDR half".utf8)).count, 0, "没有换行不该出结果")
        let lines = decoder.ingest(Data(" line\nErikaHDR second\n".utf8))
        XCTAssertEqual(lines.map(\.text), ["ErikaHDR half line", "ErikaHDR second"])
    }

    func testDecoderClassifiesKnownPrefixesAndFallsBack() {
        var decoder = KernelStderrDecoder()
        let lines = decoder.ingest(Data("""
        ErikaHDR tone map: peak=1000
        ErikaOpenOptions readahead=16777216
        something else entirely

        """.utf8))
        XCTAssertEqual(lines.map(\.category), ["Erika/Output", "Erika/Open", "Erika/Stderr"])
    }

    /// 内核报错的行要能在**默认档**看见——否则「内核出错了」依然只存在于丢失的 stderr 里。
    func testDecoderLevelsErrorLikeLinesAboveDebug() {
        var decoder = KernelStderrDecoder()
        let lines = decoder.ingest(Data("""
        ErikaHDR render failed: timeout
        fatal runtime error: thread local panicked
        ErikaHDR ordinary detail

        """.utf8))
        XCTAssertEqual(lines.map(\.level), [.warning, .error, .debug])
    }

    func testDecoderTruncatesOverlongLines() {
        var decoder = KernelStderrDecoder(maxLineBytes: 32)
        let lines = decoder.ingest(Data((String(repeating: "x", count: 200) + "\n").utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].text.hasSuffix("[…截断]"))
        XCTAssertLessThan(lines[0].text.utf8.count, 100)
    }

    /// trace 回声（已在 trace 文件里）不进管线：否则逐帧 trace 会把诊断文件冲掉。
    func testDecoderDropsTraceEchoesButKeepsRealLines() {
        var decoder = KernelStderrDecoder()
        let lines = decoder.ingest(Data("""
        [erika-clock-trace] stage=engine_play before=0.000
        [erika-render-trace] stage=upload_frame gen=2
        [erika-capi-trace] ts_ms=1 fn=open
        ErikaHDR: first Metal video frame output_mode=Sdr
        [erika-something-else] not a trace echo

        """.utf8))
        XCTAssertEqual(lines.map(\.text), [
            "ErikaHDR: first Metal video frame output_mode=Sdr",
            "[erika-something-else] not a trace echo",
        ])
        XCTAssertEqual(decoder.traceEchoesDropped, 3)
    }

    /// 超预算的行丢弃并计数（内核刷屏时别把诊断文件撑爆），窗口末尾给一条汇总。
    func testDecoderRateLimitsBursts() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var decoder = KernelStderrDecoder(linesPerSecondBudget: 3, now: start)
        let burst = String(repeating: "ErikaHDR spam\n", count: 10)
        let lines = decoder.ingest(Data(burst.utf8), now: start)
        XCTAssertEqual(lines.count, 3, "只放行预算内的行")
        XCTAssertEqual(decoder.takeDroppedSummary(now: start), 7)

        // 下一窗口恢复配额。
        let later = start.addingTimeInterval(1)
        XCTAssertEqual(decoder.ingest(Data("ErikaHDR again\n".utf8), now: later).count, 1)
        XCTAssertNil(decoder.takeDroppedSummary(now: later), "没有丢弃就不该有汇总")
    }

    /// 防回归：`remainder = remainder[idx...]` 切出的是共享底层存储的切片，已消费字节会
    /// 留在存储里被 append 一路 realloc 保住（实测一条播放会话残留 60MB+）。消费完必须压实。
    func testDecoderDoesNotRetainConsumedBytes() {
        var decoder = KernelStderrDecoder()
        // 与内核 http_cache_hit 一行相仿的长度。
        let line = Data("{\"event\":\"http_cache_hit\",\"start\":74486,\"length\":172041}\n".utf8)
        let before = Self.mallocInUseBytes()
        for _ in 0..<200_000 { _ = decoder.ingest(line) }
        // `malloc_zone_statistics` 是**进程级**统计，循环里既分配也释放，`after`
        // 完全可能小于 `before`。两个 `UInt64` 直接相减会算术溢出、当场 SIGTRAP
        // 把测试进程打崩——表象是「0.000 秒失败、无断言文案」，实为崩溃型 flaky
        // （崩溃报告 OcPlayer-*.ips：EXC_BREAKPOINT / SIGTRAP，栈顶
        // `Swift runtime failure: arithmetic overflow`）。改用有符号差值：
        // 负值即「没涨」，断言照常通过。
        let grown = Int64(Self.mallocInUseBytes()) - Int64(before)
        // 阈值 8 MiB（原为 2 MiB）：量的是**进程级** `malloc_zone_statistics`，含
        // XCTest 自身的分配与分配器记账抖动，与解码器无关——实测同一份代码的 grown
        // 跨四个数量级（n=18：272 B / 1.0 KB / 1.4 KB / 2.6 KB / 2.8 KB / 6.4 KB /
        // 176 KB，多轮为负；最高两轮 2.23 MB 冲破 2 MiB 阈值 → 约 11% 假失败）。
        //
        // **别靠加迭代数压噪声**：噪声与分配次数近似成正比，把迭代数从 20 万提到
        // 100 万，噪声跟着涨到 14.2 MB（n=6：2.2 KB / 7.4 KB / 11.9 KB / 2.9 MB /
        // 2.9 MB / 14.2 MB），信噪比没有改善。所以维持 20 万次、阈值 8 MiB：对实测
        // 噪声最高值有 3.6× 余量，同时能接住「把整条流留住」的回归
        // （200k × 60 B ≈ 12 MB；生产实测单会话残留 60 MB+）。
        XCTAssertLessThan(grown, Int64(8 * 1024 * 1024), "已消费字节被 remainder 存储留住了 \(grown) 字节")
    }

    private static func mallocInUseBytes() -> UInt64 {
        var total: UInt64 = 0
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        malloc_get_all_zones(mach_task_self_, nil, &zones, &count)
        for index in 0..<Int(count) {
            guard let raw = zones?[index],
                  let zone = UnsafeMutableRawPointer(bitPattern: raw)?
                    .assumingMemoryBound(to: malloc_zone_t.self) else { continue }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            total += UInt64(stats.size_in_use)
        }
        return total
    }

    // MARK: - KernelTraceSwitches

    func testTraceSwitchesSetPathsUnderGivenDirectoryWhenVerbose() {
        let directory = URL(fileURLWithPath: "/tmp/ocplayer-test-logs")
        let switches = KernelTraceSwitches.switches(verbose: true, directory: directory)
        XCTAssertEqual(switches["ERIKA_HTTP_TRACE"], "1")
        XCTAssertEqual(switches["ERIKA_HDR_DEBUG"], "1")
        XCTAssertEqual(switches["ERIKA_HTTP_TRACE_FILE"],
                       "/tmp/ocplayer-test-logs/erika_http_trace.jsonl")
        XCTAssertEqual(switches["ERIKA_PLAYBACK_TRACE_FILE"],
                       "/tmp/ocplayer-test-logs/erika_playback_trace.jsonl")
        XCTAssertTrue(switches.values.allSatisfy { $0 != nil }, "详细档不该有清除项")
    }

    func testTraceSwitchesClearEverythingWhenNotVerbose() {
        let switches = KernelTraceSwitches.switches(
            verbose: false, directory: URL(fileURLWithPath: "/tmp/whatever"))
        XCTAssertEqual(Set(switches.keys), Set([
            "ERIKA_HTTP_TRACE", "ERIKA_HTTP_TRACE_FILE",
            "ERIKA_PLAYBACK_TRACE", "ERIKA_PLAYBACK_TRACE_FILE",
            "ERIKA_HDR_DEBUG",
        ]))
        XCTAssertTrue(switches.values.allSatisfy { $0 == nil }, "关闭时要清干净，别留 trace 开关")
    }

    /// 逐帧级的高频开关（ffmpeg / 字幕诊断）刻意不在集合里：会把诊断文件冲掉。
    func testTraceSwitchesSkipHighVolumeKnobs() {
        let switches = KernelTraceSwitches.switches(
            verbose: true, directory: URL(fileURLWithPath: "/tmp/logs"))
        XCTAssertNil(switches["ERIKA_FFMPEG_DEBUG"], "逐帧 NAL 日志 1500+ 行/秒")
        XCTAssertNil(switches["ERIKA_SUBTITLE_DIAG"], "逐帧字幕几何 ~100 行/秒且无文件 sink")
    }

    /// trace 文件按会话清：启动时清一次，关掉详细档时再清一次。
    func testPrepareForLaunchRemovesStaleTraceFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in KernelTraceSwitches.traceFileNames {
            try Data("stale".utf8).write(to: directory.appendingPathComponent(name))
        }
        KernelTraceSwitches.prepareForLaunch(logDirectory: directory)
        for name in KernelTraceSwitches.traceFileNames {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                "\(name) 应该被清掉")
        }
    }
}
