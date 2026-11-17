import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AppDesignKit

/// `ImagePipeline` × `ImageHostFailureBreaker` 的接线回归。
///
/// 三条必须同时成立的结论，缺一条都会变成用户可见的故障：
/// 1. 熔断打开时**立刻失败**，不再发请求（否则一墙海报排队等 15 秒超时）；
/// 2. 内存命中 / 磁盘字节命中**不受熔断影响**（离线出图是本项目的主路径）；
/// 3. 成功会复位（否则一次网络抖动之后要等满整个冷却窗口才恢复）。
final class ImagePipelineBreakerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BreakerProbeProtocol.mode = .ok
        BreakerProbeProtocol.requests = []
    }

    private func makePipeline(
        breaker: ImageHostFailureBreaker
    ) throws -> (ImagePipeline, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Breaker-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pipeline = ImagePipeline(
            cacheDirectory: dir,
            protocolClasses: [BreakerProbeProtocol.self],
            breaker: breaker
        )
        return (pipeline, dir)
    }

    private func url(_ path: String, host: String = "media.example.com") -> URL {
        URL(string: "https://\(host)/Items/\(path)/Images/Primary?maxWidth=400")!
    }

    /// 熔断打开后：请求**不出网**，直接抛 `OpenCircuit`。
    func testOpenCircuitFailsFastWithoutNetwork() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        BreakerProbeProtocol.mode = .timeout
        do {
            _ = try await pipeline.load(url("a"), authHeader: nil)
            XCTFail("网络失败的图不该成功返回")
        } catch is ImageHostFailureBreaker.OpenCircuit {
            XCTFail("第一次失败时熔断还没打开，应当抛出网络错误")
        } catch {
            // 期望：真实网络错误原样上抛。
        }
        XCTAssertEqual(BreakerProbeProtocol.requests.count, 1)

        do {
            _ = try await pipeline.load(url("b"), authHeader: nil)
            XCTFail("熔断打开时不该成功")
        } catch is ImageHostFailureBreaker.OpenCircuit {
            // 期望路径。
        }
        XCTAssertEqual(
            BreakerProbeProtocol.requests.count, 1,
            "熔断打开后必须一个请求都不发，否则就是「一墙海报各等一次超时」")
    }

    /// 内存命中在熔断闸门**之前**：图已经解码在手上，凭什么叫它失败。
    func testMemoryHitIgnoresOpenCircuit() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        let cachedURL = url("cached")
        let loaded = try await pipeline.load(cachedURL, authHeader: nil)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(BreakerProbeProtocol.requests.count, 1)

        // 换成坏网络，用同 host 的另一张图把熔断打开。
        BreakerProbeProtocol.mode = .timeout
        _ = try? await pipeline.load(url("broken"), authHeader: nil)
        XCTAssertEqual(BreakerProbeProtocol.requests.count, 2)

        // 已经解码在内存里的那张必须照常返回，且不产生新请求。
        let again = try await pipeline.load(cachedURL, authHeader: nil)
        XCTAssertNotNil(again, "内存命中不该受熔断影响")
        XCTAssertEqual(
            BreakerProbeProtocol.requests.count, 2,
            "内存命中连熔断检查都不该走到网络")
    }

    /// 磁盘字节命中在熔断闸门**之前**：这是「断网重启后海报还在」的主路径。
    func testBlobHitIgnoresOpenCircuit() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        let cachedURL = url("cached")
        let primed = try await pipeline.load(cachedURL, authHeader: nil)
        XCTAssertNotNil(primed)

        // 只清内存：字节还在磁盘上。
        pipeline.clearMemoryCache()

        BreakerProbeProtocol.mode = .timeout
        _ = try? await pipeline.load(url("broken"), authHeader: nil)
        let requestCountAfterTrip = BreakerProbeProtocol.requests.count

        let offline = try await pipeline.load(cachedURL, authHeader: nil)
        XCTAssertNotNil(offline, "磁盘命中必须照常出图——离线可用性不能被熔断吃掉")
        XCTAssertEqual(
            BreakerProbeProtocol.requests.count, requestCountAfterTrip,
            "磁盘命中同样不该产生网络请求")
    }

    /// 成功会复位连续失败计数：好一张就能把计数清零，不必等冷却。
    func testSuccessfulResponseResetsFailureCount() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 2, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        BreakerProbeProtocol.mode = .timeout
        _ = try? await pipeline.load(url("fail-1"), authHeader: nil)
        XCTAssertEqual(breaker.snapshot(for: url("x")).consecutiveFailures, 1)

        BreakerProbeProtocol.mode = .ok
        let recovered = try await pipeline.load(url("ok"), authHeader: nil)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(
            breaker.snapshot(for: url("x")).consecutiveFailures, 0,
            "宿主应答成功就要复位计数，否则偶发失败会攒成一次误熔断")
        XCTAssertFalse(breaker.snapshot(for: url("x")).isOpen)

        BreakerProbeProtocol.mode = .timeout
        _ = try? await pipeline.load(url("fail-2"), authHeader: nil)
        XCTAssertEqual(breaker.snapshot(for: url("x")).consecutiveFailures, 1)
        XCTAssertTrue(
            breaker.shouldAllowRequest(for: url("probe"), at: Date()),
            "复位之后计数从 1 重新开始，不该已经熔断")
    }

    /// 非 200 不该算 host 故障：主机是活的，只是这张图没有。
    func testHTTPErrorDoesNotTripCircuit() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        BreakerProbeProtocol.mode = .notFound
        _ = try await pipeline.load(url("missing"), authHeader: nil)

        XCTAssertFalse(
            breaker.snapshot(for: url("missing")).isOpen,
            "404 说明 host 正常，熔断不该被一张缺失的图打开")
        XCTAssertTrue(breaker.shouldAllowRequest(for: url("other")))
    }

    /// 取消不算失败：滚动带走的请求不能把服务器误判成下线。
    func testCancellationDoesNotTripCircuit() async throws {
        let breaker = ImageHostFailureBreaker(failureThreshold: 1, cooldown: 600)
        let (pipeline, _) = try makePipeline(breaker: breaker)

        BreakerProbeProtocol.mode = .cancelled
        _ = try? await pipeline.load(url("cancelled"), authHeader: nil)

        XCTAssertFalse(
            breaker.snapshot(for: url("cancelled")).isOpen,
            "取消是滚动时的常态，记成故障会让正常浏览把服务器打黑")
        XCTAssertEqual(breaker.snapshot(for: url("cancelled")).consecutiveFailures, 0)
    }
}

// MARK: - 可控网络

/// 可切换结局的 `URLProtocol`：记录每一次真实请求，用于断言「熔断后确实没出网」。
final class BreakerProbeProtocol: URLProtocol {
    enum Mode {
        case ok
        case timeout
        case notFound
        case cancelled
    }

    nonisolated(unsafe) static var mode: Mode = .ok
    nonisolated(unsafe) static var requests: [URL] = []

    /// 1×1 PNG：能真的解码出位图，才能走到「存进内存 / 字节缓存」那一步。
    private static let pngBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """)!

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.requests.append(url)
        }
        switch Self.mode {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .cancelled:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .notFound:
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .ok:
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.pngBytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
