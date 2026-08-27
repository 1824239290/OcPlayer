import Foundation
import Network
import PlaybackKit
import Testing
@testable import ErikaKit

/// 行为级验证 `ErikaOpenOptions.http_read_ahead_bytes` 真的被内核消费。
/// 用一个真实大文件（合成测试媒体太小，一次请求就拿完了，预取行为无从观察）：
/// 本地 Range 服务器记录内核发出的每个 Range 请求，对比两档的「最远请求终点」。
/// 大文件不在（如 CI）时跳过。
@Suite("ErikaOpenOptions read-ahead 行为", .serialized)
struct ErikaReadAheadBehaviorTests {

    /// 大文件路径（外接卷上的真实剧集）；不存在则测试跳过。
    private static let bigMediaPath = "/Volumes/新加卷/斗罗大陆Ⅱ绝世唐门.Soul.Land.2.The.Peerless.Tang.Clan.S01.2023.2160p.WEB-DL.H.265.AAC2.0-HHWEB/斗罗大陆Ⅱ绝世唐门.Soul.Land.2.The.Peerless.Tang.Clan.S01E167.2023.2160p.WEB-DL.H.265.AAC2.0-HHWEB.mp4"

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

    @Test("readAheadBytes 越大内核预取越远（真实大文件）")
    func readAheadActuallyApplied() async throws {
        let mediaURL = URL(fileURLWithPath: Self.bigMediaPath)
        guard FileManager.default.fileExists(atPath: Self.bigMediaPath) else {
            // swift-testing 没有正式的 skip API：空过（CI 上没挂大卷时此测试不产生断言）
            print("⚠️ 跳过 read-ahead 行为测试：大文件不在本机 \(Self.bigMediaPath)")
            return
        }

        func farthestRequestedRangeEnd(readAhead: UInt64?) async throws -> Int {
            let (port, log, _) = try Self.startRangeServer(servingFile: mediaURL)
            let presenter = try ErikaPresenter()
            let uri = "http://127.0.0.1:\(port)/stream.mp4"
            if let readAhead {
                try presenter.open(PlaybackSource(uri: uri, headers: [:], readAheadBytes: readAhead))
            } else {
                try presenter.open(PlaybackSource(uri: uri))
            }
            // 等 probe + 多次预取
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                _ = try? presenter.audioOnlyTick()
                while let _ = try? presenter.pollEvent() {}
                if log.all.count >= 4 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try? presenter.close()
            // 所有请求 Range 终点的最大值 = 内核预取拉到过的最远位置
            return log.all.compactMap { value -> Int? in
                value.split(separator: "-").last.flatMap { Int($0) }
            }.max() ?? -1
        }

        let defaultEnd = try await farthestRequestedRangeEnd(readAhead: nil)
        let bigEnd = try await farthestRequestedRangeEnd(readAhead: 32 * 1024 * 1024)

        // 默认档：probe(0-642907) 之后的预取终点 ≈ 642908 + 2 MiB；
        // 32 MiB 档：终点 ≈ 642908 + 32 MiB。两档必须拉开 24 MiB 以上。
        #expect(defaultEnd < 8 * 1024 * 1024, "默认档最远终点应在 2 MiB 档位附近，实际 \(defaultEnd)")
        #expect(bigEnd >= 24 * 1024 * 1024, "32MiB 档最远终点应 ≥ 24 MiB，实际 \(bigEnd)")
    }
}
