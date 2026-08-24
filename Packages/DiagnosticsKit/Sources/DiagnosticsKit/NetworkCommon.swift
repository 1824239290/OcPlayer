import Foundation

/// 网络层诊断日志共享实现：四个网络包（JellyfinKit / BangumiKit / MoviePilotKit /
/// DanmakuKit）各自保留命名不同的薄 wrapper 委托到这里，category 不同即可。
///
/// 只记请求**路径**不记 query（路径足够定位问题）；token 等敏感字段由红actor 兜底。
public enum NetworkLog {
    private static let registry = LoggerRegistry()

    /// 按 category 缓存共享 logger。各包暴露给调用方的 `logger` 也应来自这里，
    /// 避免同一 category 起两份实例写同一份 JSONL 文件。
    public static func logger(category: String) -> DiagnosticLogger {
        registry.logger(category: category)
    }

    public static func requestStarted(category: String, path: String) {
        logger(category: category).debug("请求开始 path=\(path)")
    }

    public static func requestSucceeded(
        category: String,
        path: String,
        duration: TimeInterval,
        level: DiagnosticLevel = .debug
    ) {
        logger(category: category).log(
            level: level,
            "请求成功 path=\(path) duration_ms=\(Int(duration * 1000))")
    }

    public static func requestFailed(
        category: String,
        path: String,
        error: Error,
        duration: TimeInterval,
        level: DiagnosticLevel = .error
    ) {
        logger(category: category).log(
            level: level,
            "请求失败 path=\(path) error=\(error) duration_ms=\(Int(duration * 1000))")
    }

    /// 带结构化字段的通用上报（Danmaku 的 matchRequested、Jellyfin 的 reportFailed 用）。
    public static func report(
        category: String,
        level: DiagnosticLevel,
        _ message: @autoclosure () -> String,
        fields: [String: DiagnosticValue] = [:]
    ) {
        logger(category: category).log(level: level, message(), fields: fields)
    }

    /// `URL` 只取 path 部分入日志（query 可能带 userId 这类半敏感信息）。
    public static func logPath(for url: URL?) -> String {
        guard let url else { return "?" }
        return url.path.isEmpty ? url.absoluteString : url.path
    }

    /// 按 category 缓存 DiagnosticLogger 的锁保护注册表（enum 静态可变字典会触发
    /// 并发安全检查，实例化到 @unchecked Sendable 类里由 NSLock 保护）。
    private final class LoggerRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var loggers: [String: DiagnosticLogger] = [:]

        func logger(category: String) -> DiagnosticLogger {
            lock.lock()
            defer { lock.unlock() }
            if let existing = loggers[category] { return existing }
            let logger = DiagnosticLogger(category: category)
            loggers[category] = logger
            return logger
        }
    }
}

/// NSURLError 分类器：把「URL 错误码 → 语义类别」的映射抽出来共享。
/// Bangumi / MoviePilot 两个服务端错误枚举各自保留精确的面向用户文案，只在这里按码分类，
/// 避免一整段 24 行 switch 抄两份。
public enum NetworkErrorClassifier {
    public enum Kind: Sendable {
        case noConnection
        case timedOut
        case cannotResolveHost
        case cannotConnect
        case secureConnectionFailed
        case cancelled
    }

    /// 返回 nil 表示没有命中任何已知类别（调用方走默认文案）。
    public static func kind(for code: Int) -> Kind? {
        switch code {
        case NSURLErrorNotConnectedToInternet:
            return .noConnection
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .cannotResolveHost
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return .cannotConnect
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorCannotLoadFromNetwork:
            return .secureConnectionFailed
        case NSURLErrorCancelled:
            return .cancelled
        default:
            return nil
        }
    }
}

public extension Duration {
    /// 秒（Double）。历史上有两个包各自私有一份换算（Bangumi / MoviePilot），统一放这里。
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
