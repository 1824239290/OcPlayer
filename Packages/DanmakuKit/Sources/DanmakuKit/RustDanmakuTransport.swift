import DiagnosticsKit
import Foundation
import OcPlayerCore

/// Keeps the complete native resolver, cache and intro flow on the shared pool.
/// Each call is one attempt; GatewayClient owns its configured retry policy.
struct RustDanmakuTransport: Sendable {
    let core: OcpCoreClient
    let configuration: DandanplayConfiguration
    let timeout: TimeInterval

    func exchange(_ spec: HTTPRequestSpec) async throws -> HTTPExchange {
        var arguments: [String: Any] = [
            "gateway": ["base_url": configuration.baseURL.absoluteString,
                        "api_key": configuration.apiKey, "user_agent": configuration.userAgent],
            "url": spec.url.absoluteString, "httpMethod": spec.method,
            "timeoutSeconds": spec.timeout ?? timeout,
        ]
        if let body = spec.body { arguments["bodyBase64"] = body.base64EncodedString() }
        let response = try await core.callAsync("danmaku.exchange", argumentsJSON:
            String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        guard response.ok else {
            switch response.code {
            case 1003: throw CancellationError()
            case 1503: throw HTTPTransportError.url(URLError(.timedOut))
            case 1501: throw HTTPTransportError.url(URLError(.cannotConnectToHost))
            default: throw HTTPTransportError.other(response.message)
            }
        }
        struct RawExchange: Decodable {
            let status: Int
            let headers: [String: String]
            let bodyBase64: String
        }
        let raw = try response.data.decode(RawExchange.self)
        guard let bytes = Data(base64Encoded: raw.bodyBase64),
              let http = HTTPURLResponse(url: spec.url, statusCode: raw.status,
                  httpVersion: "HTTP/1.1", headerFields: raw.headers) else {
            throw HTTPTransportError.other("Invalid Core gateway response")
        }
        return HTTPExchange(data: bytes, response: http)
    }
}
