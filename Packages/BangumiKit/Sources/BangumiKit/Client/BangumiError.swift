import Foundation

/// Bangumi API 统一错误。
public enum BangumiError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case requireLogin
    case network(String)
    case request(String)
    case badRequest(String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case http(statusCode: Int, response: String, requestID: String?)
    case generic(String)
    case notice(String)
    case ignore(String)

    public init(request: String) {
        self = .request(request)
    }

    public init(networkError error: NSError) {
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            self = .network("没有网络连接，请检查网络设置或权限后重试")
        case NSURLErrorTimedOut:
            self = .network("请求超时，请稍后再试")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            self = .network("无法解析服务器地址，请稍后再试")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            self = .network("无法连接到服务器，请检查网络后重试")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired, NSURLErrorCannotLoadFromNetwork:
            self = .network("无法建立安全连接，请检查网络环境或稍后再试")
        case NSURLErrorCancelled:
            self = .ignore("请求已取消")
        default:
            self = .network("网络请求失败，请稍后再试")
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

    public init(code: Int, response: String, requestID: String?) {
        switch code {
        case 400:
            self = .badRequest(response)
        case 401:
            self = .requireLogin
        case 403:
            self = .forbidden(response)
        case 404:
            self = .notFound(response)
        case 409:
            self = .conflict(response)
        default:
            self = .http(statusCode: code, response: response, requestID: requestID)
        }
    }

    public var userMessage: String {
        switch self {
        case .requireLogin:
            return "登录状态已失效，请重新登录"
        case .network(let message), .generic(let message), .notice(let message):
            return message
        case .request:
            return "请求处理失败，请稍后再试"
        case .badRequest:
            return "请求参数有误，请检查后重试"
        case .forbidden:
            return "请求被拒绝，请检查权限"
        case .notFound:
            return "请求的内容不存在"
        case .conflict:
            return "请求与当前状态冲突，请刷新后重试"
        case .http(let statusCode, let response, let requestID):
            return HTTPErrorDetails(
                statusCode: statusCode,
                responseBody: response,
                requestID: requestID
            ).userMessage
        case .ignore(let message):
            return message
        }
    }

    public var description: String {
        switch self {
        case .requireLogin:
            return "Please login with Bangumi"
        case .network(let message), .generic(let message), .notice(let message), .ignore(let message):
            return message
        case .request(let message):
            return "Request Error!\n\(message)"
        case .badRequest(let response), .forbidden(let response), .notFound(let response),
            .conflict(let response):
            return "\(response)"
        case .http(let statusCode, let response, _):
            return "HTTP \(statusCode): \(response)"
        }
    }

    public var errorDescription: String? {
        userMessage
    }

    public var isRetryable: Bool {
        switch self {
        case .network(let message):
            return message == "请求超时，请稍后再试" || message == "无法连接到服务器，请检查网络后重试"
        case .notice(let message):
            return message == "请求超时，请稍后再试" || message == "请求过于频繁，请稍后再试"
        case .http(let statusCode, _, _):
            return statusCode == 502 || statusCode == 503
                || statusCode == 504
        default:
            return false
        }
    }
}

private struct HTTPErrorDetails {
    let statusCode: Int
    let responseBody: String
    let requestID: String?

    var userMessage: String {
        switch statusCode {
        case 401:
            return "登录状态已失效，请重新登录"
        case 403:
            return "请求被拒绝，请检查权限"
        case 404:
            return "请求的内容不存在"
        default:
            return "请求失败（\(statusCode)），请稍后再试"
        }
    }
}
