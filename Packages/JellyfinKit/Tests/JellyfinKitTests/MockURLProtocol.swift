import Foundation
import JellyfinKit
import XCTest

/// 把 SDK 的 URLSession 请求全部拦下来，离线测登录 / 浏览。
/// 用法：`MockURLProtocol.handler = { ... }`，配 `sessionConfiguration.protocolClasses`。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("MockURLProtocol 收到请求但没有 handler：\(request.url?.path ?? "?")")
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

    static func ok(_ json: String, for url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        return (response, Data(json.utf8))
    }
}

enum TestSupport {
    /// 带 mock 协议的 session 配置，塞给 JellyfinClient。
    static func mockedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    /// 拦截到请求体里的 query（Get 的 query 是 URL 编码过的）。
    static func queryItems(of request: URLRequest) -> [String: String] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// 取出请求 body。URLProtocol 拦到的请求里 `httpBody` 常常为空，
    /// 数据在 `httpBodyStream` 里，两边都要读。
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func withMock(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
                         with body: () async throws -> Void) async rethrows -> Void {
        MockURLProtocol.handler = handler
        defer { MockURLProtocol.handler = nil }
        try await body()
    }

    /// 临时设置自定义 UA，退出作用域还原旧值。
    ///
    /// 生产代码的 `ClientIdentity.customUserAgent` 直接读 `UserDefaults.standard`
    /// （没有可注入的 suite），所以这里只能存旧值还原——不能无条件 remove，否则
    /// 会清掉真实偏好或前一个用例留下的值。
    ///
    /// **依赖用例串行**：改的是全局 `UserDefaults.standard`，且 `ClientIdentityTests`
    /// / `EmbyServerTests` / `JellyfinServerTests` 三个类共用同一个键。当前
    /// `swift test` 默认串行，安全；将来若开并行测试，得先把偏好改成可注入的
    /// suite，否则这些用例会互相踩。
    static func withCustomUserAgent(
        _ value: String?,
        _ body: () async throws -> Void
    ) async rethrows -> Void {
        let key = ClientIdentity.customUserAgentKey
        let previous = UserDefaults.standard.string(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try await body()
    }
}
