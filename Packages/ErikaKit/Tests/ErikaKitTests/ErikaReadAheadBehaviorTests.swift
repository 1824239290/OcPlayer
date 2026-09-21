import Darwin
import Foundation
import PlaybackKit
import Testing
@testable import ErikaKit

/// 行为级验证 `ErikaOpenOptions` 的 HTTP 窗口参数真的被内核消费。
/// 内核（v0.1.9+dolby.streaming.fix.dev）用**持久流预取**：两个 worker 各持一条
/// 开放式 GET（`bytes=锚点-`），按 4 MiB stripe 交付、TCP 背压限速，预读窗口
/// 由流**主动**灌满（不再等读者驱动）；已播数据按回退预算（`http_back_buffer_bytes`，
/// 默认 16 MiB）保留，预算内回退是纯缓存命中。据此验证三件事：
/// ① worker 的请求是开放式 Range、初始两条锚点相距一个 stripe（4 MiB）；
/// ② 32 MiB 档窗口被主动灌满（交付水位 ≥ 24 MiB）；
/// ③ 回退预算端到端生效：小预算下回到已播头部要重新发请求，大预算下零请求。
///
/// 测试服务器按**真实源**的形状实现（POSIX 阻塞 socket：bind/listen 同步完成，
/// 阻塞 send 的写满即 TCP 背压，全量套件并行跑也不受调度影响）：keep-alive、
/// HEAD 探测、有界 Range 精确回 206；开放式 GET **持续流式推送直到内核停读或
/// 连接死亡**——绝不提前关闭连接：内核把「干净 EOF」当资源结束（worker 直接标
/// done，不做续传），提前断开会让预取停在第一个 stripe。交付进度用服务器侧的
/// **已推送字节水位**度量（持久流下请求条数不再随预取前沿增长）。
/// 大文件不在（如 CI）时跳过；设 `ERIKA_READAHEAD_TEST_MEDIA` 可指向任意
/// >34 MiB 的真实媒体文件本地验证。**媒体必须是 faststart（moov 在头部）**：
/// moov 在尾部时 open 探测会先读到 EOF 附近，字节断言全部失真。
@Suite("ErikaOpenOptions read-ahead/回退预算 行为", .serialized)
struct ErikaReadAheadBehaviorTests {

    /// 大文件路径（外接卷上的真实媒体）；不存在则测试跳过。
    private static let bigMediaPath = "/Volumes/新加卷/[item4056016].mp4"

    /// 本地验证回退：环境变量指定的媒体文件（须 >34 MiB，32 MiB 窗口 + probe 不触底）。
    private static var resolvedMediaPath: String? {
        if let override = ProcessInfo.processInfo.environment["ERIKA_READAHEAD_TEST_MEDIA"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        return FileManager.default.fileExists(atPath: bigMediaPath) ? bigMediaPath : nil
    }

    /// 与内核 `HTTP_STREAM_STRIPE_BYTES` 一致：worker 锚点间隔的单位。
    private static let stripeBytes = 4 * 1024 * 1024

    /// 线程安全的 Range 请求日志（只记带 Range 头的 GET；HEAD 不入日志）。
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) { lock.withLock { storage.append(line) } }
        var all: [String] { lock.withLock { storage } }
        var count: Int { lock.withLock { storage.count } }
        func suffix(from index: Int) -> [String] { lock.withLock { Array(storage[index...]) } }
    }

    /// 服务器侧已推送字节水位：跨连接取 max(start + 已发送字节数)。
    /// 持久流下请求条数不再随预取前沿增长，交付进度只能这样度量。
    final class DeliveryWatermark: @unchecked Sendable {
        private let lock = NSLock()
        private var farthest = -1

        func advance(_ value: Int) {
            lock.withLock { if value > farthest { farthest = value } }
        }

        var farthestDelivered: Int { lock.withLock { farthest } }
    }

    // MARK: - 测试服务器（真实源形状，POSIX 阻塞 socket）

    private static func startRangeServer(
        servingFile fileURL: URL
    ) throws -> (port: Int, log: RequestLog, tracker: DeliveryWatermark) {
        let fileSize = try Int(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! Int64)
        let log = RequestLog()
        let tracker = DeliveryWatermark()

        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "socket() 失败 errno=\(errno)"])
        }
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0  // 任意端口
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            bind(serverFD, UnsafePointer<sockaddr>(OpaquePointer(pointer)), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "bind() 失败 errno=\(errno)"])
        }
        guard listen(serverFD, 8) == 0 else {
            close(serverFD)
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "listen() 失败 errno=\(errno)"])
        }
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsockResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            getsockname(serverFD, UnsafeMutablePointer<sockaddr>(OpaquePointer(pointer)), &addrLen)
        }
        guard getsockResult == 0 else {
            close(serverFD)
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "getsockname() 失败 errno=\(errno)"])
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))

        Thread.detachNewThread {
            while true {
                let clientFD = accept(serverFD, nil, nil)
                guard clientFD >= 0 else { break }
                var noSigPipe: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                let fileURL = fileURL
                Thread.detachNewThread {
                    Self.handleConnection(clientFD, fileURL: fileURL, fileSize: fileSize, log: log, tracker: tracker)
                }
            }
            close(serverFD)
        }
        // bind/listen 同步完成，端口此刻已可连接，无需就绪等待。
        return (port, log, tracker)
    }

    /// 一个连接的处理循环：keep-alive；HEAD 回长度；有界 Range 精确回切片；
    /// 开放式 Range 持续推送直到连接死亡（内核停读 = TCP 背压，不是断开）。
    private static func handleConnection(
        _ fd: Int32,
        fileURL: URL,
        fileSize: Int,
        log: RequestLog,
        tracker: DeliveryWatermark
    ) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            close(fd)
            return
        }
        defer { try? handle.close(); close(fd) }
        let headerEnd = Data("\r\n\r\n".utf8)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func readHeader() -> Data? {
            while pending.range(of: headerEnd) == nil {
                let received = recv(fd, &buffer, buffer.count, 0)
                guard received > 0 else { return nil }
                pending.append(contentsOf: buffer[0..<received])
                if pending.count > 128 * 1024 { return nil }
            }
            let end = pending.range(of: headerEnd)!
            let header = pending.prefix(upTo: end.upperBound)
            pending.removeSubrange(..<end.upperBound)
            return header
        }

        func sendAll(_ data: Data) -> Bool {
            var offset = 0
            while offset < data.count {
                let sent = data.withUnsafeBytes { raw -> Int in
                    let pointer = raw.bindMemory(to: UInt8.self).baseAddress!
                    return send(fd, pointer + offset, data.count - offset, 0)
                }
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }

        func slice(_ start: Int, _ length: Int) -> Data {
            try? handle.seek(toOffset: UInt64(start))
            return (try? handle.readData(ofLength: length)) ?? Data()
        }

        while true {
            guard let headerData = readHeader() else { return }
            let headerText = String(decoding: headerData, as: UTF8.self)
            let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            let method = lines.first.map { String($0.split(separator: " ").first ?? Substring()) } ?? "GET"
            let rangeValue = lines
                .first(where: { $0.lowercased().hasPrefix("range:") })
                .flatMap { $0.split(separator: ":", maxSplits: 1).last.map(String.init) }
                .map { $0.trimmingCharacters(in: .whitespaces) }

            if method == "HEAD" {
                // 长度探测：200 + 全长（内核从 Content-Length 取 total，无响应体）。
                let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n" +
                    "Accept-Ranges: bytes\r\nContent-Length: \(fileSize)\r\n\r\n"
                guard sendAll(Data(head.utf8)) else { return }
                continue
            }

            guard let rangeValue, rangeValue.hasPrefix("bytes=") else {
                // 无 Range 的 GET：按开放式从头推（语义等价 200 全量）。
                let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n" +
                    "Accept-Ranges: bytes\r\nContent-Length: \(fileSize)\r\n\r\n"
                guard sendAll(Data(head.utf8)) else { return }
                streamBody(fd, start: 0, handle: handle, fileSize: fileSize, tracker: tracker)
                return
            }

            let parts = rangeValue.dropFirst("bytes=".count).split(separator: "-")
            let start = parts.first.flatMap { Int($0) } ?? 0
            let requestedEnd = parts.count > 1 ? Int(parts[1]) : nil

            if let requestedEnd {
                // 有界请求：精确回切片（内核校验 Content-Range），keep-alive 继续。
                let reqEnd = min(requestedEnd, fileSize - 1)
                let length = max(0, reqEnd - start + 1)
                let body = slice(start, length)
                log.append("bytes=\(start)-\(reqEnd)")
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\n" +
                    "Content-Range: bytes \(start)-\(reqEnd)/\(fileSize)\r\n" +
                    "Content-Length: \(body.count)\r\n\r\n"
                guard sendAll(Data(head.utf8) + body) else { return }
                tracker.advance(start + body.count)
                continue
            }

            // 开方式请求（bytes=N-）：worker 的持久流——推到 EOF 或连接死亡。
            log.append("bytes=\(start)-")
            let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\n" +
                "Content-Range: bytes \(start)-\(fileSize - 1)/\(fileSize)\r\n" +
                "Content-Length: \(fileSize - start)\r\n\r\n"
            guard sendAll(Data(head.utf8)) else { return }
            streamBody(fd, start: start, handle: handle, fileSize: fileSize, tracker: tracker)
            return
        }
    }

    /// 开方式响应的持续推送体：64 KB 分块、阻塞 send（内核停读即背压），
    /// 推到 EOF（worker 视资源结束）或连接死亡为止。
    private static func streamBody(
        _ fd: Int32,
        start: Int,
        handle: FileHandle,
        fileSize: Int,
        tracker: DeliveryWatermark
    ) {
        var offset = start
        while offset < fileSize {
            let length = min(64 * 1024, fileSize - offset)
            try? handle.seek(toOffset: UInt64(offset))
            let chunk = (try? handle.readData(ofLength: length)) ?? Data()
            if chunk.isEmpty { break }
            var sent = 0
            while sent < chunk.count {
                let written = chunk.withUnsafeBytes { raw -> Int in
                    let pointer = raw.bindMemory(to: UInt8.self).baseAddress!
                    return send(fd, pointer + sent, chunk.count - sent, 0)
                }
                guard written > 0 else { return }
                sent += written
            }
            offset += chunk.count
            tracker.advance(start + offset)
        }
    }

    // MARK: - 请求解析

    private static func requestStart(_ range: String) -> Int? {
        range.dropFirst("bytes=".count).split(separator: "-").first.flatMap { Int($0) }
    }

    /// 开方式请求（"bytes=N-"）：持久流 worker 的签名（有界请求以数字结尾）。
    private static func isOpenEnded(_ range: String) -> Bool {
        range.hasPrefix("bytes=") && range.hasSuffix("-")
    }

    /// 等请求与交付水位都静默（连续 ~1.5 s 无变化）：窗口灌满且没有在途传输。
    private static func waitForQuiet(_ log: RequestLog, _ tracker: DeliveryWatermark) async {
        var stablePolls = 0
        var lastState = (log.count, tracker.farthestDelivered)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let state = (log.count, tracker.farthestDelivered)
            if state == lastState {
                stablePolls += 1
                if stablePolls >= 30 { return }
            } else {
                stablePolls = 0
                lastState = state
            }
        }
    }

    /// 驱动一拍：推进音频解码 + 排空事件（顺带捕获时长与位置）。
    private static func tickAndDrain(
        _ presenter: ErikaPresenter,
        duration: inout Int64,
        position: inout Int64
    ) {
        _ = try? presenter.audioOnlyTick()
        while let event = try? presenter.pollEvent() {
            switch event {
            case .durationChanged(let d): duration = d.microseconds
            case .positionChanged(let p): position = p.microseconds
            default: break
            }
        }
    }

    // MARK: - 用例

    @Test("32 MiB 窗口被持久流主动灌满，worker 锚点相距一个 stripe")
    func windowFillsProactively() async throws {
        guard let mediaPath = Self.resolvedMediaPath else {
            // swift-testing 没有正式的 skip API：空过（CI 上没挂大卷时此测试不产生断言）
            print("⚠️ 跳过 read-ahead 行为测试：大文件不在本机 \(Self.bigMediaPath)")
            return
        }

        let (port, log, tracker) = try Self.startRangeServer(servingFile: URL(fileURLWithPath: mediaPath))
        let presenter = try ErikaPresenter()
        try presenter.open(PlaybackSource(
            uri: "http://127.0.0.1:\(port)/stream.mp4",
            readAheadBytes: 32 * 1024 * 1024
        ))
        try? presenter.play()
        var duration: Int64 = 0
        var position: Int64 = 0
        let bigDeadline = Date().addingTimeInterval(60)
        while Date() < bigDeadline {
            Self.tickAndDrain(presenter, duration: &duration, position: &position)
            if tracker.farthestDelivered >= 24 * 1024 * 1024 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try? presenter.close()

        // ① 持久流签名：至少两条开方式请求，且最初的两个不同锚点相距恰好一个
        //    stripe（两个 worker 分别锚在 cache_end 与 cache_end + 4 MiB）。
        let openEndedStarts = log.all.filter(Self.isOpenEnded).compactMap(Self.requestStart(_:))
        #expect(openEndedStarts.count >= 2,
                "应有 ≥2 条开方式 worker GET：\(log.all)")
        let distinctAnchors = Array(Set(openEndedStarts)).sorted()
        #expect(distinctAnchors.count >= 2
                && distinctAnchors[1] - distinctAnchors[0] == Self.stripeBytes,
                "前两个 worker 锚点应相距 4 MiB，实际 \(distinctAnchors)")

        // ② 窗口深度：32 MiB 档被主动灌满（读者还停在片头，交付已奔到窗口尽头）。
        let bigEnd = tracker.farthestDelivered
        #expect(bigEnd >= 24 * 1024 * 1024, "32MiB 档交付水位应 ≥24 MiB，实际 \(bigEnd)")
    }

    @Test("回退预算端到端：小预算回退到已播头部重新拉取，大预算零请求")
    func rewindBudgetHonored() async throws {
        guard let mediaPath = Self.resolvedMediaPath else {
            print("⚠️ 跳过回退预算行为测试：大文件不在本机 \(Self.bigMediaPath)")
            return
        }
        let fileSize = try Int(FileManager.default.attributesOfItem(atPath: mediaPath)[.size] as! Int64)

        /// 跑一轮回退对照，返回「seek 到 0 之后是否出现了近 0 的新请求」。
        /// 流程：灌满 32 MiB 窗口 → 前跳 ~20 MiB（纯缓存命中，同时让小预算的
        /// trim——预算 1 MiB + 迟滞 8 MiB——把头部逐出缓存）→ 静默 → seek 回 0。
        /// 小预算：0 已在缓存外，必须重新 re-anchor；大预算（128 MiB）：命中缓存，
        /// 零请求。
        func runCase(backBufferBytes: UInt64) async throws -> Bool {
            let (port, log, tracker) = try Self.startRangeServer(servingFile: URL(fileURLWithPath: mediaPath))
            let presenter = try ErikaPresenter()
            try presenter.open(PlaybackSource(
                uri: "http://127.0.0.1:\(port)/stream.mp4",
                readAheadBytes: 32 * 1024 * 1024,
                backBufferBytes: backBufferBytes
            ))
            try? presenter.play()
            var duration: Int64 = 0
            var position: Int64 = 0
            let fillDeadline = Date().addingTimeInterval(60)
            while Date() < fillDeadline {
                Self.tickAndDrain(presenter, duration: &duration, position: &position)
                if tracker.farthestDelivered >= 28 * 1024 * 1024 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await Self.waitForQuiet(log, tracker)
            guard duration > 0 else {
                try? presenter.close()
                throw CocoaError(.fileReadUnknown)
            }

            // 前跳：目标字节 ≈ 20 MiB（须落在已灌满的窗口内——cache_end ≈ 水位
            // - 在途 ≈ 26 MiB+；回退命中判据要求落点字节 ≥ 预算+迟滞 = 9 MiB）。
            let bitrate = Double(fileSize) / (Double(duration) / 1_000_000)
            let forwardTargetBytes = min(20 * 1024 * 1024, fileSize / 2)
            let forwardSeconds = Int64(Double(forwardTargetBytes) / bitrate)
            let baselineBeforeForward = log.count
            try? presenter.seek(to: Duration(secondsComponent: forwardSeconds, attosecondsComponent: 0))
            let forwardDeadline = Date().addingTimeInterval(10)
            while Date() < forwardDeadline {
                Self.tickAndDrain(presenter, duration: &duration, position: &position)
                try await Task.sleep(for: .milliseconds(50))
            }
            await Self.waitForQuiet(log, tracker)
            // 前跳必须零请求：目标在已灌满的窗口里，trim 逐头也不发网络请求。
            #expect(log.count == baselineBeforeForward,
                    "前跳落在窗口内应是纯缓存命中，实际新增请求：\(log.suffix(from: baselineBeforeForward))")

            // 回到 0：小预算 = 缓存外（重新拉取）；大预算 = 缓存内（零请求）。
            let baseline = log.count
            try? presenter.seek(to: .zero)
            var newRequestNearZero = false
            let rewindDeadline = Date().addingTimeInterval(8)
            while Date() < rewindDeadline {
                Self.tickAndDrain(presenter, duration: &duration, position: &position)
                if log.count > baseline {
                    let fresh = log.suffix(from: baseline)
                    if fresh.contains(where: { (Self.requestStart($0) ?? .max) <= 4 * 1024 * 1024 }) {
                        newRequestNearZero = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try? presenter.close()
            return newRequestNearZero
        }

        // 小预算（1 MiB）：头部被 trim 逐出，回到 0 必须重新拉取。
        let smallRun = try await runCase(backBufferBytes: 1 * 1024 * 1024)
        #expect(smallRun, "1 MiB 预算下回退到 0 应触发重新拉取（trim 把头部逐出了缓存）")

        // 大预算（128 MiB）：0 仍在缓存里，回退零请求。
        let bigRun = try await runCase(backBufferBytes: 128 * 1024 * 1024)
        #expect(!bigRun, "128 MiB 预算下回退到 0 应纯缓存命中，不应出现新请求")
    }
}
