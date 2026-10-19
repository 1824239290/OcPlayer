import Foundation

enum DiagnosticRedactor {
    private static let patterns = SensitivePatterns()

    /// 逐趟脱敏。**每趟都有严格必要条件守卫** —— 不满足则跳过。
    ///
    /// ## 为什么要守卫
    ///
    /// 六趟 `NSRegularExpression` 都跑在**调用方线程**上（写盘队列之前）。实测：
    ///
    /// ```
    /// 短消息「播放状态变化」   7.44 µs
    /// 1.2 KB 消息            97.83 µs   ← 线性放大
    /// URL 型消息（~90 B）    25.17 µs
    /// 字段字典（2 个字段）    42.08 µs
    /// ```
    ///
    /// 对照 `P2-39` 之后一条典型 error 日志总共 29.9 µs —— **脱敏现在几乎是全部成本**，
    /// 而播放 / 渲染热路径上每条日志都要付。
    ///
    /// ## 守卫必须「过近似」
    ///
    /// 每个守卫都是「不满足 ⇒ 该正则**必然**不匹配」的必要条件，所以跳过等价于空操作。
    /// 写窄了就是漏脱敏（安全漏洞），因此：
    /// - 带 `(?i)` 的模式，守卫的大小写也必须不敏感（`contains` 用 `.caseInsensitive`）；
    /// - JWT 模式**没有** `(?i)`，守卫就是大小写敏感的字面量 `eyJ`。
    ///
    /// 等价性由 `DiagnosticRedactorGuardTests` 的差分用例证明（300+ 条语料逐字节比对
    /// 「带守卫」与「强制全跑」），不靠推断。
    ///
    /// ## 为什么不按清单建议把脱敏挪到写盘队列
    ///
    /// 那要求消息先以**未脱敏**形态入队 —— 任何绕过 logger 直写 backend 的路径都会把
    /// 凭据写出去；而且它只是把成本从调用线程搬到写线程，**总 CPU 不变**。守卫式跳过
    /// 则真的少做功，安全语义一字未改。
    static func redact(_ value: String) -> String {
        var result = value
        // 先做**一次**小写折叠，供全部大小写不敏感守卫共用。
        //
        // ⚠️ 不要用 `String.range(of:options:.caseInsensitive)`：实测单次就要几微秒，
        // 而这里要问十几个关键词 —— 第一版那么写比不设守卫**慢 5 倍**
        // （短消息 38 µs vs 7.4 µs，1.2 KB 消息 2585 µs vs 97.8 µs）。
        // 一次 `lowercased()` 是 O(n)，之后全是廉价的 UTF-8 子串查找。
        //
        // 对 ASCII 而言小写折叠与正则里的 `(?i)` 等价；非 ASCII 上两者可能不同
        // （如 `İ`），但那种字符不会出现在这些**路径 / 关键词字面量**里 ——
        // 差分测试用含 emoji / 制表符 / 换行的语料覆盖了这一点。
        let folded = result.lowercased()

        if containsASCII(folded, "/users/") || containsASCII(folded, "/home/") {
            result = replace(result, using: patterns.userPath, with: "<user-path>")
        }
        if containsASCII(folded, "/var/mobile") {
            result = replace(result, using: patterns.appContainerPath, with: "<app-container-path>")
        }
        if result.contains("://") {
            result = redactURLs(result)
        }
        if containsASCII(folded, "bearer") || containsASCII(folded, "basic") {
            result = replace(result, using: patterns.authorization, with: "$1 <redacted>")
        }
        if containsAnySensitiveKeyword(folded) {
            // $1..$4 = 开引号 / key / 闭引号 / 分隔符；只换值，保留周边形态。
            result = replace(result, using: patterns.sensitiveAssignment, with: "$1$2$3$4<redacted>")
        }
        // JWT 模式无 `(?i)`：`eyJ` 是 base64url 里 `{"` 的编码，恰好大小写敏感。
        if containsASCII(result, "eyJ") {
            result = replace(result, using: patterns.jwt, with: "<redacted-token>")
        }
        return result
    }

    /// 测试用参考实现：**强制跑完全部六趟**，不带任何守卫。
    ///
    /// 差分测试拿它与带守卫的实现逐字节比对 —— 这是证明「守卫不改变输出」的唯一
    /// 可靠手段。生产中**不要**调用它（慢，且没有守卫的意义）。
    static func redactWithoutGuards(_ value: String) -> String {
        var result = replace(value, using: patterns.userPath, with: "<user-path>")
        result = replace(result, using: patterns.appContainerPath, with: "<app-container-path>")
        result = redactURLs(result)
        result = replace(result, using: patterns.authorization, with: "$1 <redacted>")
        result = replace(result, using: patterns.sensitiveAssignment, with: "$1$2$3$4<redacted>")
        result = replace(result, using: patterns.jwt, with: "<redacted-token>")
        return result
    }

    /// 测试用：`sensitiveAssignment` 的关键词表（守卫与正则必须同步，用例据此校验）。
    static var assignmentKeywordsForTesting: [String] { SensitivePatterns.assignmentKeywords }

    /// `sensitiveAssignment` 的守卫：只要可能命中这条正则，必然含其中某个关键词。
    ///
    /// 必须与正则里的关键词表**同步**（`SensitivePatterns.sensitiveAssignment`）。
    /// 漏一个就是那一类凭据不再被脱敏 —— 所以宁可过近似。
    ///
    /// - Parameter folded: **已经 `lowercased()` 过**的文本（关键词表全是小写）。
    private static func containsAnySensitiveKeyword(_ folded: String) -> Bool {
        for keyword in SensitivePatterns.assignmentKeywords
        where containsASCII(folded, keyword) {
            return true
        }
        return false
    }

    /// 无分配的子串搜索，**只用于 ASCII 针**。
    ///
    /// ## 为什么不用 `String.contains`
    ///
    /// 实测（1.24 KB 中文文本，问 10 个 ASCII 关键词）：
    ///
    /// ```
    /// String.contains       213.6 µs   （每次 ≈21.5 µs）
    /// strstr                  6.8 µs   （每次 ≈0.67 µs）← 31×
    /// ```
    ///
    /// `String.contains` 走 **Character（字素簇）视图** —— 对中文/emoji 这类多字节字符
    /// 每次比较都要做字素边界对齐，所以与文本长度成昂贵的线性关系。而这里要找的全是
    /// ASCII 字面量（`/users/`、`token`…），用 `strstr` 直接在 UTF-8 字节上找即可 ——
    /// **安全性不受影响**：ASCII 字节永远不会出现在多字节 UTF-8 字符内部
    /// （UTF-8 是自同步的），所以字节级匹配不会切在字符中间。
    ///
    /// - Note: 仅对 `needle` 是纯 ASCII 时正确。关键词表与路径字面量都满足。
    static func containsASCII(_ haystack: String, _ needle: String) -> Bool {
        needle.withCString { needlePointer in
            haystack.withCString { haystackPointer in
                strstr(haystackPointer, needlePointer) != nil
            }
        }
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
    /// key 两侧可能是引号（JSON：`{"api_key":"…"}`、头字典：`["X-Emby-Token": "…"]`），
    /// 所以 key 与分隔符**两侧都要允许引号**。
    ///
    /// 早期版本要求 key 后紧跟 `\s*[:=]\s*`，于是**所有 JSON 形态的凭据都原样落盘**：
    /// 分隔符前面隔着 key 的收尾引号，正则必然不匹配。这不是理论缺口——`BangumiError
    /// .description` 对 4xx 直接回原始响应体，而错误文本会被插进日志消息（`\(error)`），
    /// 所以服务端只要在错误体里回显请求 JSON，凭据就原文进 `diagnostics.jsonl`，
    /// 再原文进用户附件到公开 issue 的导出包。
    ///
    /// 关键词补了 `accesstoken` / `x-emby-token` / `x-api-key` / `api-key` / `apikey` /
    /// `client_secret`：Emby 用 `X-Emby-Token` 头，OAuth 用 `client_secret`，都不含
    /// 裸 `token` 之外的既有关键词形态。
    let sensitiveAssignment = try! NSRegularExpression(
        pattern: #"(?i)("|')?\b(access[_-]?token|refresh[_-]?token|accesstoken|token|authorization|password|passwd|secret|api[_-]?key|apikey|api-key|x-emby-token|x-api-key|client[_-]?secret|cookie|set-cookie)\b("|')?(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,\s;&}\]]+)"#)
    let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#)

    /// `sensitiveAssignment` 正则里的关键词表（供 `DiagnosticRedactor` 的守卫使用）。
    ///
    /// **必须与上面那条 pattern 同步**：两边不一致时，守卫会漏掉正则能匹配的关键词，
    /// 于是那一类凭据不再被脱敏 —— 而 `isSensitiveKey` 只覆盖「字段名」场景，兜不住这里。
    static let assignmentKeywords: [String] = [
        "access_token", "access-token", "accesstoken",
        "refresh_token", "refresh-token",
        "token", "authorization",
        "password", "passwd",
        "secret", "api_key", "api-key", "apikey", "x-api-key",
        "x-emby-token", "client_secret", "client-secret",
        "cookie",
    ]

    func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["token", "access_token", "refresh_token", "authorization", "password",
                "passwd", "secret", "api_key", "cookie", "set_cookie", "credential",
                "credentials", "private_key", "client_secret"].contains(normalized)
            || normalized.contains("token") || normalized.contains("password")
            || normalized.contains("secret") || normalized.contains("authorization")
            // `x_api_key` / `x_emby_token` 这类带前缀的头名：前缀让上面的等值比较
            // 失效，而它们既不含 "token" 也不含 "secret"，必须显式补。
            || normalized.contains("api_key") || normalized.contains("apikey")
    }
}

/// 把**非日志管线来源**的文本过一遍同一套脱敏规则。
///
/// 管线内的记录由 `DiagnosticLogger` 在写盘前自动脱敏，不需要调用这里；
/// 这个入口是给宿主准备的——典型场景是内核自己直接写盘的 trace 文件
/// （`erika_http_trace.jsonl` 等，记录了逐请求 URI），导出诊断包前必须显式
/// 过一遍，否则用户直连的带签名 query 的 URL 会裸着进导出包。
public enum DiagnosticSanitizer {
    public static func redact(_ text: String) -> String {
        DiagnosticRedactor.redact(text)
    }
}
