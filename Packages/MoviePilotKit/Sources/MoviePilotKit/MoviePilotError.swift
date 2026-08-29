import DiagnosticsKit
import Foundation

/// MoviePilot API 统一错误。
public enum MoviePilotError: Error, CustomStringConvertible, LocalizedError, Sendable {
    /// 未登录 / token 已失效且静默重登失败。
    case requireLogin
    case notConfigured
    case network(failure: NetworkErrorClassifier.Kind?, message: String)
    case request(String)
    case badRequest(String)
    case forbidden(String)
    case notFound(String)
    case http(statusCode: Int, response: String)
    case generic(String)
    case notice(String)
    case ignore(String)

    public init(request: String) {
        self = .request(request)
    }

    /// URL 错误码 → 语义类别的映射在 DiagnosticsKit.NetworkErrorClassifier 共享，
    /// 这里只保留本服务精确的面向用户文案。
    public init(networkError error: NSError) {
        switch NetworkErrorClassifier.kind(for: error.code) {
        case .some(.noConnection):
            self = .network(failure: .noConnection, message: "没有网络连接，请检查网络设置或权限后重试")
        case .some(.timedOut):
            self = .network(failure: .timedOut, message: "请求超时，请稍后再试")
        case .some(.cannotResolveHost):
            self = .network(failure: .cannotResolveHost, message: "无法解析 MoviePilot 服务器地址，请检查地址后重试")
        case .some(.cannotConnect):
            self = .network(failure: .cannotConnect, message: "无法连接到 MoviePilot 服务器，请检查网络后重试")
        case .some(.secureConnectionFailed):
            self = .network(failure: .secureConnectionFailed, message: "无法建立安全连接，请检查 MoviePilot 证书或网络环境")
        case .some(.cancelled):
            self = .ignore("请求已取消")
        case .none:
            self = .network(failure: nil, message: "网络请求失败，请稍后再试")
        }
    }

    public init(message: String) {
        self = .generic(message)
    }

    public init(notice: String) {
        self = .notice(notice)
    }

    public init(ignore: String) {
        self = .ignore(ignore)
    }

    public init(code: Int, response: String) {
        switch code {
        case 400:
            self = .badRequest(response)
        case 401:
            self = .requireLogin
        case 403:
            self = .forbidden(response)
        case 404:
            self = .notFound(response)
        default:
            self = .http(statusCode: code, response: response)
        }
    }

    public var userMessage: String {
        switch self {
        case .requireLogin:
            return "MoviePilot 登录状态已失效，请重新登录"
        case .notConfigured:
            return "MoviePilot 服务器未配置，请先在设置页填写地址与账号"
        case .network(_, let message), .generic(let message), .notice(let message):
            return message
        case .request:
            return "请求处理失败，请稍后再试"
        case .badRequest(let response):
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "请求参数有误，请检查后重试" : trimmed
        case .forbidden(let response):
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "请求被拒绝，请检查权限" : trimmed
        case .notFound(let response):
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "请求的内容不存在" : trimmed
        case .http(let statusCode, let response):
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "请求失败（\(statusCode)），请稍后再试" : trimmed
        case .ignore(let message):
            return message
        }
    }

    public var description: String {
        switch self {
        case .requireLogin:
            return "Please login with MoviePilot"
        case .notConfigured:
            return "MoviePilot server not configured"
        case .network(_, let message), .generic(let message), .notice(let message), .ignore(let message):
            return message
        case .request(let message):
            return "Request Error!\n\(message)"
        case .badRequest(let response), .forbidden(let response), .notFound(let response):
            return "\(response)"
        case .http(let statusCode, let response):
            return "HTTP \(statusCode): \(response)"
        }
    }

    public var errorDescription: String? {
        userMessage
    }

    public var isRetryable: Bool {
        switch self {
        case .network(let failure, _):
            return failure == .timedOut || failure == .noConnection
        case .http(let statusCode, _):
            return statusCode == 502 || statusCode == 503 || statusCode == 504
        default:
            return false
        }
    }
}

/// FastAPI 的默认错误体 `{"detail": "..."}`，取出来拼进错误文案。
struct MoviePilotErrorBody: Decodable {
    let detail: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // detail 也可能是数组（校验错误 422），此时取不到可读文案。
        if let text = try? container.decode(String.self, forKey: .detail) {
            detail = text
        } else {
            detail = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case detail
    }

    static func message(from data: Data) -> String? {
        (try? JSONDecoder().decode(Self.self, from: data))?.detail
    }
}
