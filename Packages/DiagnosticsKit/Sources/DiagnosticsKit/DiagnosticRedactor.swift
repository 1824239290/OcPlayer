import Foundation

enum DiagnosticRedactor {
    private static let patterns = SensitivePatterns()

    static func redact(_ value: String) -> String {
        var result = replace(value, using: patterns.userPath, with: "<user-path>")
        result = replace(result, using: patterns.appContainerPath, with: "<app-container-path>")
        result = redactURLs(result)
        result = replace(result, using: patterns.authorization, with: "$1 <redacted>")
        result = replace(result, using: patterns.sensitiveAssignment, with: "$1$2<redacted>")
        result = replace(result, using: patterns.jwt, with: "<redacted-token>")
        return result
    }

    static func redact(_ fields: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        var result: [String: DiagnosticValue] = [:]
        result.reserveCapacity(fields.count)
        for (key, value) in fields {
            let safeKey = redact(key)
            if patterns.isSensitiveKey(key) {
                result[safeKey] = .string("<redacted>")
            } else {
                result[safeKey] = redact(value)
            }
        }
        return result
    }

    private static func redact(_ value: DiagnosticValue) -> DiagnosticValue {
        switch value {
        case .string(let text): return .string(redact(text))
        case .integer, .unsignedInteger, .double, .boolean, .null: return value
        }
    }

    private static func redactURLs(_ input: String) -> String {
        let matches = patterns.url.matches(in: input, range: NSRange(input.startIndex..., in: input))
        var result = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var token = String(result[range])
            var trailing = ""
            while let last = token.last, ".,;:)]}".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                token.removeLast()
            }
            guard let schemeEnd = token.range(of: "://")?.upperBound else { continue }
            let authorityEnd = token[schemeEnd...].firstIndex(of: "/")
                ?? token[schemeEnd...].endIndex
            var authority = String(token[schemeEnd..<authorityEnd])
            if authority.contains("@") { authority = "<redacted>@" + (authority.split(separator: "@").last.map(String.init) ?? "") }
            var replacement = String(token[..<schemeEnd]) + authority
            let suffix = String(token[authorityEnd...])
            if let query = suffix.firstIndex(of: "?") {
                replacement += String(suffix[..<query]) + "?<redacted>"
            } else if let fragment = suffix.firstIndex(of: "#") {
                replacement += String(suffix[..<fragment]) + "#<redacted>"
            } else {
                replacement += suffix
            }
            replacement += trailing
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func replace(_ input: String,
                                using regex: NSRegularExpression,
                                with template: String) -> String {
        regex.stringByReplacingMatches(in: input,
                                        range: NSRange(input.startIndex..., in: input),
                                        withTemplate: template)
    }
}

private final class SensitivePatterns: @unchecked Sendable {
    /// 本机家目录前缀。
    ///
    /// **不能写成 `/(?:Users|home)/…` 的泛匹配**：`/Users/` 同时也是 Jellyfin / Emby
    /// 的 API 路由前缀（`/Users/{userId}/Items/Resume`），泛匹配会把网络日志里最需要
    /// 的那一列——请求路径——整段抹成 `<user-path>`，排障时看不出是哪个端点慢。
    /// 锚定到本机用户名，既只抹真正要抹的东西，也不误伤 API 路径。
    ///
    /// 取舍：同机上**别的**用户的家目录路径不再被抹。App 只写自己的容器和用户显式
    /// 选中的文件，不会去读别人的家目录，所以这个面很小。
    let userPath = try! NSRegularExpression(
        pattern: "(?i)(?:file://)?(?:\(SensitivePatterns.homeRoots))(?:/[^\\s\"'<>]*)?")

    /// `/Users/<name>` 与 `/home/<name>`，用户名按正则字面量转义。
    private static var homeRoots: String {
        let name = NSRegularExpression.escapedPattern(for: NSUserName())
        return "/Users/\(name)|/home/\(name)"
    }

    let appContainerPath = try! NSRegularExpression(
        pattern: #"(?i)/(?:var/mobile|private/var/mobile)/Containers/[^\s"'<>]+"#)
    let url = try! NSRegularExpression(
        pattern: #"https?://[^\s"'<>]+"#,
        options: [.caseInsensitive])
    let authorization = try! NSRegularExpression(
        pattern: #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#)
    let sensitiveAssignment = try! NSRegularExpression(
        pattern: #"(?i)\b(access[_-]?token|refresh[_-]?token|token|authorization|password|passwd|secret|api[_-]?key|cookie|set-cookie)\b(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,\s;&]+)"#)
    let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#)

    func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["token", "access_token", "refresh_token", "authorization", "password",
                "passwd", "secret", "api_key", "cookie", "set_cookie", "credential",
                "credentials", "private_key", "client_secret"].contains(normalized)
            || normalized.contains("token") || normalized.contains("password")
            || normalized.contains("secret") || normalized.contains("authorization")
    }
}
