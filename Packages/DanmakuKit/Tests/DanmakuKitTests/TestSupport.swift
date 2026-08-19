import Foundation
import XCTest

/// 离线测网关客户端：把 URLSession 请求拦下来，按 path 分派 mock 响应。
/// 用法与 JellyfinKit 的 MockURLProtocol 一致。
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

enum TestSupport {
    static func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func response(_ json: String,
                         status: Int = 200,
                         url: URL,
                         cache: String? = nil) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        if let cache { headers["X-Gateway-Cache"] = cache }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (resp, Data(json.utf8))
    }

    static func queryItems(of request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func withMock(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
                         _ body: () async throws -> Void) async rethrows {
        MockURLProtocol.handler = handler
        defer { MockURLProtocol.handler = nil }
        try await body()
    }
}
