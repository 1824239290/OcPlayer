import CryptoKit
import XCTest
@testable import DanmakuKit

/// `P2-38`：`head16MiBMD5(from:)` 必须**在收到响应头时就决策**，
/// 不合格立刻取消 —— 响应体一个字节都不该被消费。
///
/// ## 背景（这是真缺陷，不只是性能）
///
/// 旧实现是 `try await session.data(for: request)`：**读完整个响应体才返回**，
/// 然后才校验「服务器有没有老实按 Range 返回」。于是服务器一忽略 `Range`
/// 返回 `200 + 整个文件`，就会先把整部电影读进内存，再抛 `rangeUnsupported`。
/// 旧注释的 "can never download an entire movie" 在传输层不成立。
final class FileHashRangePolicyTests: XCTestCase {

    private typealias Policy = FileHash.RangePolicy
    private typealias Error = FileHash.FileHashError

    // MARK: - 判定表（纯函数）

    /// `206` + 合法 `Content-Range` → 接受，并声明要收的字节数。
    func testPartialContentAccepted() {
        // 声明收前 16 MiB（文件更大）。
        guard case .success(let length) = Policy.decide(
            statusCode: 206,
            contentRange: "bytes 0-16777215/999999999",
            expectedFileSize: nil
        ) else { return XCTFail("合法 206 应被接受") }
        XCTAssertEqual(length, Int64(FileHash.headByteCount))

        // 小文件：只声明 3 字节。
        guard case .success(let small) = Policy.decide(
            statusCode: 206,
            contentRange: "bytes 0-2/3",
            expectedFileSize: 3
        ) else { return XCTFail("小文件的 206 应被接受") }
        XCTAssertEqual(small, 3)
    }

    /// **`200` + 整文件 ≤ 16 MiB → 接受**（服务器不认 Range 也无所谓，反正收得下）。
    func testFullBodyAcceptedOnlyWhenWholeFileFitsInHead() {
        // 正好等于上限：接受。
        guard case .success(let none) = Policy.decide(
            statusCode: 200,
            contentRange: nil,
            expectedFileSize: Int64(FileHash.headByteCount)
        ) else { return XCTFail("整文件 ≤ 16 MiB 的 200 应被接受") }
        XCTAssertNil(none, "没有 Content-Range 时不该声明长度")

        // 比上限多 1 字节：拒绝。
        guard case .failure(let error) = Policy.decide(
            statusCode: 200,
            contentRange: nil,
            expectedFileSize: Int64(FileHash.headByteCount) + 1
        ) else { return XCTFail("超过 16 MiB 的 200 必须拒绝") }
        XCTAssertEqual(error, .rangeUnsupported)
    }

    /// **`200` 且不知道文件多大 → 拒绝**（这一条就是「不能下载整部电影」的判据）。
    ///
    /// 未知大小时必须假设它可能很大 —— 宁可放弃匹配，也不能赌。
    func testFullBodyRejectedWhenSizeUnknown() {
        guard case .failure(let error) = Policy.decide(
            statusCode: 200, contentRange: nil, expectedFileSize: nil
        ) else { return XCTFail("未知大小的 200 必须拒绝") }
        XCTAssertEqual(error, .rangeUnsupported)
    }

    /// 各种不合法的 `Content-Range` 都要拒绝。
    func testMalformedOrUnexpectedRangesRejected() {
        let cases: [(String?, Int64?, String)] = [
            (nil, nil, "206 却没有 Content-Range"),
            ("bytes 0-three/3", nil, "非数字"),
            ("bytes 1-3/4", nil, "起点不是 0"),
            ("bytes 0-2/4", nil, "只给了前 3 字节，后面还有"),
            ("bytes 0-16777215/16777216", 16777217, "声明总长与期望文件大小不符"),
            ("bytes 0-2/*", 4, "通配总长但未覆盖整个 head"),
        ]
        for (header, expected, label) in cases {
            guard case .failure(let error) = Policy.decide(
                statusCode: 206, contentRange: header, expectedFileSize: expected
            ) else {
                XCTFail("应拒绝：\(label)")
                continue
            }
            XCTAssertEqual(error, .rangeUnsupported, "应拒绝：\(label)")
        }
    }

    /// 其它状态码原样报出来。
    func testOtherStatusCodesReported() {
        guard case .failure(let error) = Policy.decide(
            statusCode: 404, contentRange: nil, expectedFileSize: nil
        ) else { return XCTFail("404 应失败") }
        XCTAssertEqual(error, .httpStatus(404))
    }

    // MARK: - 「不碰 body」的硬证据

    /// 服务器无视 `Range`、要回一个很大的文件：**必须在头之后立刻停**。
    ///
    /// ## 这条用例为什么这么设计
    ///
    /// `URLProtocol` 有个机制限制：它会把响应头**缓冲到第一块 body 到达时**才投递
    /// （实测：头在 5.3s、和 body 同时到）。所以「头到了但 body 永远不来」这种桩
    /// **测不出**立即取消 —— 那是在测 mock 的缓冲，不是测实现。
    ///
    /// 因此桩改成：头 + 第一块 body 立刻给，**后续 body 慢慢发**（共约 3 秒）。
    /// - 修好后：拿到头就 cancel → **1.5 秒内**返回（剩下的 body 不再消费）。
    /// - 旧实现 `data(for:)`：要等整个 body → 约 **3 秒**。
    ///
    /// 阈值 1.5 s 落在两者之间，能明确区分。
    func testRejectedResponseStopsBeforeBodyFinishes() async throws {
        let url = URL(string: "https://media.example/movie.mkv")!
        Self.DripBodyURLProtocol.resetCounters()
        do {
            _ = try await FileHash.head16MiBMD5(
                from: url,
                expectedFileSize: 8_000_000_000,
                session: Self.dripBodySession()
            )
            XCTFail("服务器无视 Range 时应拒绝")
        } catch FileHash.FileHashError.rangeUnsupported {
            // expected
        }
        // 确定性判据（不用耗时 —— CI 上耗时断言会假红，实测踩过）：
        // 桩共 11 块（第一块立刻 + 10 块慢发）。及时取消的话只发出前 1–2 块；
        // 若把整个 body 都收下来，会发满 11 块。
        let delivered = Self.DripBodyURLProtocol.deliveredChunks
        XCTAssertLessThanOrEqual(
            delivered, 3,
            "应在收到响应头后立刻取消，实际桩发出了 \(delivered)/11 块 "
                + "—— 说明仍把整个 body 收了下来")
    }

    /// 对照组：`200` 且整文件确实很小 → **要**把 body 收下来并算对哈希。
    ///
    /// 这条防止「为了不读 body 而连该读的也不读」。
    func testSmallFullBodyResponseIsAcceptedAndHashed() async throws {
        let url = URL(string: "https://media.example/tiny.srt")!
        let session = TestSupport.mockedSession()
        try await TestSupport.withMock({ request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("abc".utf8))
        }) {
            let hash = try await FileHash.head16MiBMD5(
                from: url, expectedFileSize: 3, session: session)
            XCTAssertEqual(hash, "900150983cd24fb0d6963f7d28e17f72")
        }
    }

    // MARK: - 取消传播（回归检查）

    /// **父任务取消后必须尽快停**（旧实现靠 `session.data(for:)` 天然可取消）。
    ///
    /// 调用方 `DanmakuLoadOrchestrator.mediaHash` 已经在
    /// `catch where CancellationClassifier.isCancellation(error)` 里显式处理取消 ——
    /// 若下游不响应取消，那段代码就成了死码，换片/关页时白等一轮完整下载。
    ///
    /// 桩：头+第一块立刻给，之后每 0.2 s 一块、共 20 块（约 4 s）。
    /// 在 100 ms 时取消父任务，应在 1.5 s 内抛出（而不是等满 4 s）。
    func testParentTaskCancellationStopsTheRequest() async throws {
        let url = URL(string: "https://media.example/slow.mkv")!
        let session = Self.dripBodySession()
        let start = CFAbsoluteTimeGetCurrent()

        // 用一个 Sendable 的包装把「有没有抛错」传回来（`any Error` 不是 Sendable）。
        struct Outcome: Sendable {
            var threw: Bool
            /// 抛出来的是不是「取消」（而不是 `readFailed` 之类）。
            var isCancellation: Bool
        }
        let task = Task { () -> Outcome in
            do {
                _ = try await FileHash.head16MiBMD5(
                    from: url,
                    expectedFileSize: Int64(FileHash.headByteCount),
                    session: session
                )
                return Outcome(threw: false, isCancellation: false)
            } catch {
                // 直接用类型判断（测试目标不依赖 DiagnosticsKit）；
                // 生产方的  认的就是 CancellationError 与
                // NSURLErrorCancelled，这里断言前者即可 —— 它们不该混进 readFailed。
                return Outcome(
                    threw: true,
                    isCancellation: error is CancellationError)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let outcome = await task.value
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertTrue(outcome.threw, "取消后应抛出而不是返回哈希")
        // **必须断言错误类型是「取消」**（审查指出缺这行）：
        // 调用方 `DanmakuLoadOrchestrator.mediaHash` 用
        // `CancellationClassifier.isCancellation(error)` 区分「取消」与「故障」，
        // 若这里退化成 `readFailed`，换片那次会被当成真故障记进 fingerprintFailed。
        XCTAssertTrue(
            outcome.isCancellation,
            "取消必须映射成 CancellationError，否则调用方会把它当故障")
        XCTAssertLessThan(
            elapsed, 1.5,
            "父任务取消后应立刻停，实测 \(String(format: "%.2f", elapsed))s "
                + "（接近 4 s 说明取消没传到底层请求）")
        // 耗时的对照组（约 4 s）有 2 倍余量，留作辅助；真正的判据看桩停在哪。
        XCTAssertTrue(outcome.threw, "取消后必须抛错")
        _ = start
    }

    // MARK: - 流量硬上限

    /// **服务器发超过 16 MiB 必须被硬顶住**（审查指出这条零覆盖）。
    ///
    /// 这是本次「内存 / 流量硬上限」的核心防线，只被注释保护是不够的：
    /// 把 `bodyLimit` 检查改成 `if false`，本包其余用例**全绿**（实测）。
    ///
    /// ## 为什么用「收到的字节数」而不是耗时
    ///
    /// 第一版断言「2 秒内抛错」—— 本地 0.91 s，但 **CI 上 3.03 s 假红**
    /// （runner 慢、调度抖动）。耗时断言在共享 CI 上不可靠。
    ///
    /// 改成断言**桩实际发出去的字节数**：硬顶生效时，发到 ~16 MiB 就会被
    /// `stopLoading` 掐断，桩记的 `delivered` 会停在 17 块附近；没有硬顶则会
    /// 一路发满 100 块。这是确定性的、与机器快慢无关。
    ///
    /// （桩的 `deliver` 会检查 `stopped`，所以停止后不会再发。）
    func testOversizedBodyIsCutOffByHardLimit() async throws {
        let url = URL(string: "https://media.example/flood.mkv")!
        Self.FloodBodyURLProtocol.resetCounters()
        let session = Self.floodBodySession()

        do {
            _ = try await FileHash.head16MiBMD5(
                from: url,
                expectedFileSize: Int64(FileHash.headByteCount) * 6,
                session: session
            )
            XCTFail("超过 16 MiB 的响应体必须被拒绝")
        } catch FileHash.FileHashError.readFailed {
            // expected
        }

        // 硬顶生效：发到 16 MiB 附近就停（桩每块 1 MiB，17 块即超过 16 MiB + 1）。
        // 给一点余量：并发投递可能让在飞的那一两块也落地。
        let delivered = Self.FloodBodyURLProtocol.deliveredChunks
        XCTAssertLessThanOrEqual(
            delivered, 25,
            "应在上限处切断（约 17 块），实际发了 \(delivered) 块 "
                + "—— 说明 bodyLimit 没生效，会一路收满 100 块")
        XCTAssertGreaterThanOrEqual(delivered, 1, "至少要发出第一块，否则用例没测到东西")
    }

    // MARK: - 夹具

    /// 头 + 第一块 body 立刻给，后续 body 每 0.3 秒发一块（共约 3 秒）。
    ///
    /// 见 `testRejectedResponseStopsBeforeBodyFinishes` 里对 `URLProtocol`
    /// 头缓冲特性的说明。
    private final class DripBodyURLProtocol: URLProtocol {
        /// 每次 `didLoad` 的字节数与块数（合计约 3 秒发完）。
        private static let chunkCount = 10
        private static let interChunkDelay: TimeInterval = 0.3

        /// 桩**实际发出去**的块数（确定性判据：停得早说明及时取消了）。
        private static let counterLock = NSLock()
        nonisolated(unsafe) private static var _deliveredChunks = 0

        static var deliveredChunks: Int {
            counterLock.lock(); defer { counterLock.unlock() }
            return _deliveredChunks
        }

        static func resetCounters() {
            counterLock.lock(); _deliveredChunks = 0; counterLock.unlock()
        }

        private static func noteDelivered() {
            counterLock.lock(); _deliveredChunks += 1; counterLock.unlock()
        }

        private let lock = NSLock()
        private var stopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "8000000000"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // 第一块立刻发：让 URLProtocol 把响应头投递出去。
            client?.urlProtocol(self, didLoad: Data(repeating: 0xAB, count: 1024))
            Self.noteDelivered()
            deliverRemaining(0)
        }

        private func deliverRemaining(_ index: Int) {
            guard index < Self.chunkCount else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.interChunkDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                guard !stopped else { return }
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0xAB, count: 1024))
                Self.noteDelivered()
                self.deliverRemaining(index + 1)
            }
        }

        override func stopLoading() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    /// 合法 206，但 body 一直发（每 0.05 s 发 1 MiB），用来压 `bodyLimit` 硬顶。
    private final class FloodBodyURLProtocol: URLProtocol {
        private static let chunkSize = 1024 * 1024
        private static let chunkCount = 100
        private static let interChunkDelay: TimeInterval = 0.02

        /// 桩**实际发出去**的块数（确定性判据，见用例注释）。
        private static let counterLock = NSLock()
        nonisolated(unsafe) private static var _deliveredChunks = 0

        static var deliveredChunks: Int {
            counterLock.lock(); defer { counterLock.unlock() }
            return _deliveredChunks
        }

        static func resetCounters() {
            counterLock.lock(); _deliveredChunks = 0; counterLock.unlock()
        }

        private static func noteDelivered() {
            counterLock.lock(); _deliveredChunks += 1; counterLock.unlock()
        }

        private let lock = NSLock()
        private var stopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // 声明「收前 16 MiB、总长 96 MiB」—— 合法 206，所以不会被头判定拦下。
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-16777215/100663296"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0xCD, count: Self.chunkSize))
            Self.noteDelivered()
            deliver(1)
        }

        private func deliver(_ index: Int) {
            guard index < Self.chunkCount else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.interChunkDelay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                guard !stopped else { return }
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0xCD, count: Self.chunkSize))
                Self.noteDelivered()
                self.deliver(index + 1)
            }
        }

        override func stopLoading() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private static func floodBodySession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FloodBodyURLProtocol.self]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    private static func dripBodySession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DripBodyURLProtocol.self]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }
}
