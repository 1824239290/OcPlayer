import DiagnosticsKit
import Foundation
import OcPlayerCore

/// One retained Core per provider client. Retry and native error boundaries stay
/// with the public client; this bridge never retries or replays a failed call.
struct RustIntroProvider: Sendable {
    let core: OcpCoreClient
    let provider: String
    let baseURL: URL
    let timeout: TimeInterval

    static func make(session: URLSession, provider: String, baseURL: URL) -> Self? {
        guard OcpCoreFeature.isEnabled,
              OcpCoreFeature.supportsNativeTransport(session.configuration),
              let core = try? OcpCoreClient() else { return nil }
        return Self(core: core, provider: provider, baseURL: baseURL,
            timeout: min(session.configuration.timeoutIntervalForRequest,
                         session.configuration.timeoutIntervalForResource))
    }

    func prepare(_ arguments: [String: Any]) throws -> HTTPRequestSpec {
        var arguments = arguments
        arguments["provider"] = provider
        arguments["baseURL"] = baseURL.absoluteString
        arguments["timeoutSeconds"] = timeout
        let response = try core.call("introProvider.request", arguments: arguments)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        struct Request: Decodable {
            let url: String
            let httpMethod: String
            let headers: [String: String]
            let bodyBase64: String?
            let timeoutSeconds: Double
        }
        let request = try response.data.decode(Request.self)
        guard let url = URL(string: request.url) else { throw OcpCoreError(message: "Invalid provider URL") }
        return HTTPRequestSpec(url: url, method: request.httpMethod, headers: request.headers,
            body: request.bodyBase64.flatMap { Data(base64Encoded: $0) }, timeout: request.timeoutSeconds)
    }

    func exchange(_ spec: HTTPRequestSpec) async throws -> HTTPExchange {
        var arguments: [String: Any] = [
            "provider": provider, "baseURL": baseURL.absoluteString,
            "url": spec.url.absoluteString, "httpMethod": spec.method,
            "headers": spec.headers, "timeoutSeconds": spec.timeout ?? timeout,
        ]
        if let body = spec.body { arguments["bodyBase64"] = body.base64EncodedString() }
        let response = try await core.callAsync("introProvider.exchange", argumentsJSON:
            String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        guard response.ok else {
            switch response.code {
            case 1003: throw CancellationError()
            case 1503: throw HTTPTransportError.url(URLError(.timedOut))
            case 1501: throw HTTPTransportError.url(URLError(.cannotConnectToHost))
            default: throw HTTPTransportError.other(response.message)
            }
        }
        struct Raw: Decodable { let status: Int; let headers: [String: String]; let bodyBase64: String }
        let raw = try response.data.decode(Raw.self)
        guard let bytes = Data(base64Encoded: raw.bodyBase64),
              let http = HTTPURLResponse(url: spec.url, statusCode: raw.status,
                httpVersion: "HTTP/1.1", headerFields: raw.headers) else {
            throw HTTPTransportError.other("Invalid Core intro provider response")
        }
        return HTTPExchange(data: bytes, response: http)
    }

    func urlSessionExchange(_ spec: HTTPRequestSpec) async throws -> HTTPExchange {
        do { return try await exchange(spec) }
        catch HTTPTransportError.url(let error) { throw error }
        catch let error as HTTPTransportError {
            throw AnimeSkipClient.AnimeSkipError.transport("\(error)")
        }
    }
}

private struct IntroProviderPayload: Decodable { let payloadJSON: String }

extension RustDanmakuPolicy {
    func provider<T: Decodable>(_ method: String, arguments: [String: Any], as: T.Type = T.self) throws -> T {
        let response = try core.call("introProvider." + method, arguments: arguments)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        let payload = try response.data.decode(IntroProviderPayload.self)
        return try JSONDecoder().decode(T.self, from: Data(payload.payloadJSON.utf8))
    }
    func providerPayload<V: Encodable, T: Decodable>(_ method: String, value: V,
        arguments: [String: Any] = [:], as: T.Type = T.self) throws -> T {
        var arguments = arguments
        arguments["payloadJSON"] = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return try provider(method, arguments: arguments)
    }
}
