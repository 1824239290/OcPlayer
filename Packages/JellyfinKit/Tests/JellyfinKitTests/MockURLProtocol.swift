import Foundation
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
}
