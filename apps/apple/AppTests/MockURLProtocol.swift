import Foundation

/// 拦下 URLSession 请求做离线断言（沿用 MoviePilotKit / DanmakuKit 的同名模式）。
/// 用法：`MockURLProtocol.handler = { ... }` + `TestSupport.mockedSessionConfiguration()`。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// handler 跑在 URLSession 的后台线程上，「发了几次请求」这类计数要自己加锁
/// （严格并发下捕获局部 var 也是数据竞争）。
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum TestSupport {
    static func mockedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    /// 每个测试独立的 UserDefaults suite，互不串（也别碰 `.standard` 真域）。
    static func isolatedDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func response(_ body: String, status: Int, for url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    static func releaseJSON(tag: String) -> String {
        """
        {
            "tag_name": "\(tag)",
            "name": "OcPlayer \(tag)",
            "html_url": "https://github.com/test/test/releases/tag/\(tag)",
            "published_at": "2026-09-01T10:00:00Z",
            "prerelease": false
        }
        """
    }
}
