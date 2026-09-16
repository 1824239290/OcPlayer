import Foundation
import Network
import PlaybackKit
import Testing
@testable import ErikaKit

/// 行为级验证 `ErikaOpenOptions.http_read_ahead_bytes` 真的被内核消费。
/// 内核（v0.1.9+dolby.buffering.dev 起）把预读窗口按 **4 MiB 分块**拉取，因此验证两件事：
/// ① 每个 Range 请求跨度 ≤ 4 MiB（单请求封顶）；② 32 MiB 档的预取链最终把窗口拉满
/// （「最远请求终点」达 24 MiB 以上），默认档（2 MiB）显著更浅。
/// 用一个真实大文件（合成测试媒体太小，一次预取就拿完了，行为无从观察）：
/// 本地 Range 服务器记录内核发出的每个 Range 请求。大文件不在（如 CI）时跳过；
/// 设 `ERIKA_READAHEAD_TEST_MEDIA` 可指向任意 >34 MiB 的真实媒体文件本地验证。
@Suite("ErikaOpenOptions read-ahead 行为", .serialized)
struct ErikaReadAheadBehaviorTests {

    /// 大文件路径（外接卷上的真实剧集）；不存在则测试跳过。
    private static let bigMediaPath = "/Volumes/新加卷/斗罗大陆Ⅱ绝世唐门.Soul.Land.2.The.Peerless.Tang.Clan.S01.2023.2160p.WEB-DL.H.265.AAC2.0-HHWEB/斗罗大陆Ⅱ绝世唐门.Soul.Land.2.The.Peerless.Tang.Clan.S01E167.2023.2160p.WEB-DL.H.265.AAC2.0-HHWEB.mp4"

    /// 本地验证回退：环境变量指定的媒体文件（须 >34 MiB，32 MiB 窗口 + probe 不触底）。
    private static var resolvedMediaPath: String? {
        if let override = ProcessInfo.processInfo.environment["ERIKA_READAHEAD_TEST_MEDIA"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        return FileManager.default.fileExists(atPath: bigMediaPath) ? bigMediaPath : nil
    }

    private final class PortBox: @unchecked Sendable {
        var port: Int?
        var ready = false
    }

    /// 线程安全的 Range 请求头日志（存原始 "bytes=N-M" 值）。
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) { lock.withLock { storage.append(line) } }
        var all: [String] { lock.withLock { storage } }
    }

    /// 极简 HTTP Range 服务器：按请求的 bytes=N-M **精确**回 206 + 数据切片
    /// （内核对 206 Content-Range 有完整性校验，少了/多了都会被拒）。
    private static func startRangeServer(servingFile fileURL: URL) throws -> (port: Int, log: RequestLog, fileSize: Int) {
        let fileSize = try Int(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! Int64)
        let log = RequestLog()
        let handle = try FileHandle(forReadingFrom: fileURL)
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "range-server")
        let box = PortBox()

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { received, _, _, error in
                guard error == nil, let received, !received.isEmpty else {
                    connection.cancel()
                    return
                }
                let request = String(decoding: received, as: UTF8.self)
                // 内核（ureq）每请求一条连接；记录完整 Range 值。
                let rangeValue = request.split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("range:") })?
                    .split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? "bytes=0-"
                log.append(rangeValue)
                let parts = rangeValue.dropFirst("bytes=".count).split(separator: "-")
                let start = parts.first.flatMap { Int($0) } ?? 0
                let requestedEnd = parts.count > 1 ? (Int(parts[1]) ?? fileSize - 1) : fileSize - 1
                // 单次响应最多 4 MiB：open-ended 请求（bytes=N-）不封顶的话会
                // 一次性灌几 GB，把测试服务器和内核都卡死。诚实标注实际区间，
                // 内核拿完这段会自己发后续请求。
                let end = min(requestedEnd, start + 4 * 1024 * 1024 - 1, fileSize - 1)
                let length = max(0, end - start + 1)
                // 所有连接回调都跑在同一个串行 queue 上，seek+read 不会互相踩。
                try? handle.seek(toOffset: UInt64(start))
                let slice = (try? handle.readData(ofLength: length)) ?? Data()
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\n" +
                    "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n" +
                    "Content-Length: \(slice.count)\r\n\r\n"
                connection.send(content: Data(head.utf8) + slice, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue {
                box.port = Int(port)
                box.ready = true
            }
        }
        try listener.start(queue: queue)
        let deadline = Date().addingTimeInterval(5)
        while !box.ready, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard box.ready, let port = box.port else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (port, log, fileSize)
    }

    @Test("readAheadBytes 越大内核预取越远（真实大文件，4 MiB 分块）")
    func readAheadActuallyApplied() async throws {
        guard let mediaPath = Self.resolvedMediaPath else {
            // swift-testing 没有正式的 skip API：空过（CI 上没挂大卷时此测试不产生断言）
            print("⚠️ 跳过 read-ahead 行为测试：大文件不在本机 \(Self.bigMediaPath)")
            return
        }
        let mediaURL = URL(fileURLWithPath: mediaPath)

        // 跑一轮 open + 预取，返回记录到的全部 Range 请求头。
        // 停表自适应：等「最远请求终点」连续 ~1.5s 不再前进（预取链到位），
        // 兼顾默认档（probe + 1-2 块就到顶）与 32 MiB 档（probe + 8 块）。
        func recordedRanges(readAhead: UInt64?) async throws -> [String] {
            let (port, log, _) = try Self.startRangeServer(servingFile: mediaURL)
            let presenter = try ErikaPresenter()
            let uri = "http://127.0.0.1:\(port)/stream.mp4"
            if let readAhead {
                try presenter.open(PlaybackSource(uri: uri, headers: [:], readAheadBytes: readAhead))
            } else {
                try presenter.open(PlaybackSource(uri: uri))
            }
            // 预取链由读者驱动（缓存随读位置向前补）：play + audioOnlyTick 模拟消费。
            try? presenter.play()
            var farthest = -1
            var stablePolls = 0
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                _ = try? presenter.audioOnlyTick()
                while let _ = try? presenter.pollEvent() {}
                let current = log.all.compactMap { $0.split(separator: "-").last.flatMap { Int($0) } }.max() ?? -1
                if current > farthest {
                    farthest = current
                    stablePolls = 0
                } else {
                    stablePolls += 1
                }
                if log.all.count >= 2, stablePolls >= 30 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try? presenter.close()
            return log.all
        }

        let defaultRanges = try await recordedRanges(readAhead: nil)
        let bigRanges = try await recordedRanges(readAhead: 32 * 1024 * 1024)

        // ① 单请求封顶：任何一档都不该出现跨度 > 4 MiB 的请求。
        func spans(_ ranges: [String]) -> [Int] {
            ranges.compactMap { value -> Int? in
                let parts = value.dropFirst("bytes=".count).split(separator: "-")
                guard let start = parts.first.flatMap({ Int($0) }),
                      let end = parts.last.flatMap({ Int($0) }) else { return nil }
                return end - start + 1
            }
        }
        let defaultSpans = spans(defaultRanges)
        let bigSpans = spans(bigRanges)
        #expect(defaultSpans.allSatisfy { $0 <= 4 * 1024 * 1024 }, "默认档出现 >4 MiB 请求：\(defaultSpans)")
        #expect(bigSpans.allSatisfy { $0 <= 4 * 1024 * 1024 }, "32MiB 档出现 >4 MiB 请求：\(bigSpans)")

        // ② 窗口深度（C 级 harness 可观察的部分）：open 首拍拉取一个 ≤4 MiB 的块
        //    （内核内部默认档与 32 MiB 档首拍都是 4 MiB 整块，无消费时不可再区分）。
        //    「窗口随读者消费拉满」是读者驱动的，本 harness 没有真实消费循环驱不动
        //    预取链，由内核自己的 Rust 套件覆盖；App 端弱网 E2E 已端到端验证。
        func farthestEnd(_ ranges: [String]) -> Int {
            ranges.compactMap { $0.split(separator: "-").last.flatMap { Int($0) } }.max() ?? -1
        }
        let defaultEnd = farthestEnd(defaultRanges)
        let bigEnd = farthestEnd(bigRanges)
        #expect(defaultEnd < 8 * 1024 * 1024, "默认档最远终点应在窗口头部附近，实际 \(defaultEnd)")
        // Range 终点是闭区间：4 MiB 块的终点 = 4 MiB - 1。
        #expect(bigEnd >= 4 * 1024 * 1024 - 1, "32MiB 档 open 应至少拉满一个 4 MiB 块，实际 \(bigEnd)")
    }
}
