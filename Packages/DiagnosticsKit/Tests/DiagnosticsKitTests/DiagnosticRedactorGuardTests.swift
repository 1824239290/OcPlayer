import Foundation
import XCTest

@testable import DiagnosticsKit

/// 脱敏守卫（性能审查清单 `P2-31` 第二半）的**等价性**与**不漏**验证。
///
/// ## 为什么这组用例是必需的
///
/// 为了让脱敏少跑几趟正则，给每趟加了「严格必要条件」守卫（不含 `://` 就不可能命中
/// URL 规则，等等）。守卫写错的后果是**安全漏洞**（那一类凭据不再被脱敏），而且
/// **不会报错** —— 只是导出包里突然出现明文 token。
///
/// 所以这里两条腿走路：
/// 1. **差分**：把「带守卫的实现」与「强制全跑的参考实现」在大量真实形状的语料上
///    逐字节比对。任何守卫写窄了都会在这里暴露。
/// 2. **不漏**：对每类敏感值造多个变体，断言脱敏后原值不出现。
final class DiagnosticRedactorGuardTests: XCTestCase {

    // MARK: - 参考实现（强制全跑，无守卫）

    /// 与生产实现同序、但**不带任何守卫**——等价性基准。
    ///
    /// 走 `DiagnosticRedactor.redactWithoutGuards`：它刻意保留加守卫之前的那六趟。
    private func unguardedRedact(_ value: String) -> String {
        DiagnosticRedactor.redactWithoutGuards(value)
    }

    // MARK: - 语料

    /// 覆盖守卫两侧的语料：应当被跳过 / 应当被处理 / 边界。
    private var corpus: [String] {
        var values: [String] = [
            // 普通消息（所有守卫都应跳过）
            "",
            "播放状态变化",
            "缓存命中 rate=0.93",
            "弹幕条数 2283",
            "MediaBrowser Client=OcPlayer Device=mac",   // 含 Bearer? 否
            // 用户路径
            "/Users/jumusu/Library/Application Support/OcPlayer/Media.sqlite",
            "/users/JUMUSU/lowercase-home",              // 大小写边界
            "/home/jumusu/.config/x",
            "/home/other/user/file.txt",
            "file:///Users/jumusu/Desktop/a.mkv",
            // App 容器
            "/var/mobile/Containers/Data/Application/ABC/Documents/x.log",
            "/private/var/mobile/Containers/Data/Application/ABC/tmp",
            // URL
            "GET https://media.example.com/Items/abc/Images/Primary?maxWidth=400&tag=dead",
            "http://192.168.5.107:8096/Items/1/Images/Backdrop?tag=t",
            "https://user:pass@host.example.com/path?x=1",
            "see http://example.com/a.",
            "HTTPS://UPPER.EXAMPLE.COM/PATH?Q=1",        // 大小写边界
            // Authorization 头
            #"Authorization: Bearer abcdefghijklmnop"#,
            #"authorization: bearer lowercase-token"#,   // 大小写边界
            #"Basic dXNlcjpwYXNz"#,
            // JSON / 头字典形态的凭据
            #"{"api_key":"SECRET-VALUE-1"}"#,
            #"{"Token":"SECRET-VALUE-2"}"#,
            #"["X-Emby-Token": "SECRET-VALUE-3"]"#,
            #"{"client_secret":"SECRET-VALUE-4"}"#,
            #"{"password":"SECRET-VALUE-5"}"#,
            #"token=SECRET-VALUE-6"#,
            #"ACCESS_TOKEN="SECRET-VALUE-7""#,           // 大写关键词
            #"{"cookie":"SECRET-VALUE-8"}"#,
            // JWT
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "not-a-jwt eyJshort",
            "EYJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig",  // 大写 EYJ：模式无 (?i)，不该命中
            // 混合 / 多次出现
            #"failed for {"password":"P1"} at /Users/jumusu/x via https://h.example.com/p?token=Q"#,
            // 边界字符
            "带 emoji 🎬 的日志",
            "含制表符\t与换行\n的消息",
            "极长 " + String(repeating: "内容 abcdef ", count: 200),
            String(repeating: "/Users/jumusu/", count: 50),
        ]
        // 再补一批组合，覆盖「半含」边界
        for keyword in ["token", "Token", "TOKEN", "password", "secret", "api_key",
                        "apikey", "cookie", "client_secret", "authorization"] {
            values.append("prefix \(keyword) suffix")
            values.append("prefix \(keyword)=value suffix")
            values.append("prefix \"\(keyword)\": \"value\" suffix")
        }
        for scheme in ["http", "https", "HTTP", "HTTPS", "ftp"] {
            values.append("\(scheme)://host.example.com/a?b=c")
        }
        return values
    }

    // MARK: - 差分

    /// **守卫不得改变输出**：逐条比对带守卫与强制全跑的结果。
    ///
    /// 这是本批最重要的一条：守卫写窄了只会在某些输入上不一致，靠「人眼过一遍」
    /// 根本发现不了。
    func testGuardedRedactionIsByteIdenticalToUnguarded() {
        var differed: [(input: String, guarded: String, unguarded: String)] = []
        for value in corpus {
            let guarded = DiagnosticRedactor.redact(value)
            let reference = unguardedRedact(value)
            if guarded != reference {
                differed.append((value, guarded, reference))
            }
        }
        XCTAssertTrue(
            differed.isEmpty,
            "守卫改变了脱敏输出（说明某个守卫写窄了，会漏脱敏）：\n"
                + differed.prefix(5).map {
                    "输入: \($0.input.prefix(80))\n  带守卫: \($0.guarded.prefix(80))\n"
                        + "  全跑:   \($0.unguarded.prefix(80))"
                }.joined(separator: "\n"))
    }

    /// 差分语料必须真的**触发过**每一趟守卫的两侧 —— 否则这条测试形同虚设。
    ///
    /// 具体判据：语料里既有「守卫全跳过」的普通消息，也有分别含
    /// 路径 / 容器 / URL / Bearer / 关键词 / JWT 的样本，且这些样本的脱敏结果
    /// **确实被改过**（与原始输入不同）。
    func testCorpusExercisesBothSidesOfEveryGuard() {
        let skipsAll = corpus.filter { value in
            DiagnosticRedactor.redact(value) == value
        }
        XCTAssertFalse(skipsAll.isEmpty, "语料里没有「所有守卫都跳过」的普通消息")

        // 逐类断言「至少一条被脱敏改过」。
        func changedSample(where predicate: (String) -> Bool) -> Bool {
            corpus.contains { predicate($0) && DiagnosticRedactor.redact($0) != $0 }
        }
        XCTAssertTrue(changedSample { $0.contains("/Users/") }, "用户路径类没有生效样本")
        XCTAssertTrue(changedSample { $0.contains("/var/mobile") }, "容器路径类没有生效样本")
        XCTAssertTrue(changedSample { $0.contains("://") && $0.uppercased() != $0 }, "URL 类没有生效样本")
        XCTAssertTrue(changedSample { $0.contains("Bearer") }, "Bearer 类没有生效样本")
        XCTAssertTrue(changedSample { $0.contains("SECRET-VALUE") }, "敏感赋值类没有生效样本")
        XCTAssertTrue(changedSample { $0.contains("eyJhbGci") }, "JWT 类没有生效样本")
    }

    // MARK: - 不漏（安全判据）

    /// 每类敏感值造多个变体，断言**原值不出现**在脱敏结果里。
    ///
    /// 差分测试只能证明「守卫没让行为变化」；这条直接证明「该抹的抹掉了」，
    /// 两者互补 —— 万一守卫与参考实现**同时**写错，只有这条能发现。
    func testSensitiveValuesNeverSurviveRedaction() {
        let secret = "SUPERSECRETVALUE12345"
        let cases: [String] = [
            #"{"password":"\#(secret)"}"#,
            #"{"token":"\#(secret)"}"#,
            #"{"access_token":"\#(secret)"}"#,
            #"{"refresh_token":"\#(secret)"}"#,
            #"{"api_key":"\#(secret)"}"#,
            #"{"apikey":"\#(secret)"}"#,
            #"{"api-key":"\#(secret)"}"#,
            #"{"x-api-key":"\#(secret)"}"#,
            #"{"x-emby-token":"\#(secret)"}"#,
            #"{"client_secret":"\#(secret)"}"#,
            #"{"cookie":"\#(secret)"}"#,
            #"{"secret":"\#(secret)"}"#,
            #"{"passwd":"\#(secret)"}"#,
            #"{"authorization":"\#(secret)"}"#,
            #"["X-Emby-Token": "\#(secret)"]"#,
            #"password=\#(secret)"#,
            #"token=\#(secret)"#,
            #"PASSWORD = \#(secret)"#,
            #"Api_Key: \#(secret)"#,
            "Authorization: Bearer \(secret)",
            "authorization: bearer \(secret)",
            "Basic \(secret)",
            // 关键词大小写变体
            #"{"TOKEN":"\#(secret)"}"#,
            #"{"Password":"\#(secret)"}"#,
            #"{"CLIENT_SECRET":"\#(secret)"}"#,
        ]
        for input in cases {
            let redacted = DiagnosticRedactor.redact(input)
            XCTAssertFalse(
                redacted.contains(secret),
                "凭据漏进脱敏结果（输入 \(input) → \(redacted)）")
        }
    }

    /// **内嵌 NUL 不能挡住脱敏。**
    ///
    /// 这是本轮自查发现并修掉的**真实凭据泄漏**：第一版守卫用
    /// `withCString` + `strstr`，而 C 串在内嵌 `\0` 处截断 ——
    /// 「NUL 之后才出现的关键词」看不见，于是整趟跳过、凭据原样留在导出包里。
    ///
    /// ```
    /// 输入      "prefix\0token=SUPERSECRET123"
    /// 修复前    "prefix\0token=SUPERSECRET123"   ← 泄漏
    /// 修复后    "prefix\0token=<redacted>"
    /// ```
    ///
    /// 日志里出现 `\0` 不是天方夜谭：错误文本会插进服务端响应体，
    /// 而某些畸形响应就带 NUL。
    func testEmbeddedNULDoesNotBypassRedaction() {
        let secret = "SUPERSECRETNUL123"
        let inputs = [
            "prefix\u{0}token=\(secret)",
            "\u{0}token=\(secret)",
            "a\u{0}b\u{0}c password=\(secret)",
            "before\u{0}Authorization: Bearer \(secret)",
            "p\u{0}https://h.example.com/a?token=\(secret)",
        ]
        for input in inputs {
            let guarded = DiagnosticRedactor.redact(input)
            let unguarded = DiagnosticRedactor.redactWithoutGuards(input)
            // 判据一：守卫不得改变输出（漏判会让这里不等）。
            XCTAssertEqual(
                guarded, unguarded,
                "含 NUL 的输入守卫与全跑结果不一致（守卫漏判）：\(input.debugDescription)")
            // 判据二：凡是带触发关键词的输入，凭据都必须消失。
            XCTAssertFalse(
                guarded.contains(secret),
                "含 NUL 时凭据漏进脱敏结果：\(guarded.debugDescription)")
        }
    }

    /// **U+017F `ſ`（长 s）：守卫与正则必须是同一个大小写视角。**
    ///
    /// 这是审查实测发现的**第二个真实泄漏**，同样是本批守卫引入的：
    /// ICU 的 `(?i)` 认为 `ſ` 等于 `s`，而 `String.lowercased()` **不折叠它**
    /// （`"ſ".lowercased() == "ſ"`）。于是守卫查不到 `ſecret` 里的关键词、
    /// 整趟跳过，凭据明文留下：
    ///
    /// ```
    /// 输入      "ſecret=Zx9QwErTyUiOp42"
    /// 修复前    "ſecret=Zx9QwErTyUiOp42"   ← 泄漏
    /// 强制全跑  "ſecret=<redacted>"
    /// ```
    ///
    /// 修法是换用**同一套 ICU 折叠** `folding(options: .caseInsensitive, locale: en_US_POSIX)`
    /// —— 穷举全部 1,114,112 个 Unicode 标量 × 26 个 ASCII 字母，两种视角零分歧。
    ///
    /// secret 值刻意用**不含任何关键词子串**的串，否则会被别的关键词规则顺带抹掉、
    /// 让用例失去鉴别力（审查在 `passwd` 那条上就逮到过这个问题）。
    func testLongSDoesNotBypassRedaction() {
        let secret = "Zx9QwErTyUiOp42"   // 不含 s / token / password 等任何关键词
        // ⚠️ 用户路径正则里的用户名是**按 `NSUserName()` 动态构造**的
        // （`SensitivePatterns.homeRoots`），所以这里必须用当前用户名拼路径。
        // 写死 `/Users/jumusu/...` 只在本机通过，CI runner 上用户是 `runner`
        // —— 正则压根不匹配，断言必然红（本 PR 第一次 CI 就是这么红的）。
        let user = NSUserName()
        let inputs = [
            "\u{017F}ecret=\(secret)",          // ſecret
            "ba\u{017F}ic \(secret)",           // baſic（Authorization 头）
            "/U\u{017F}ERS/\(user)/x",          // /UſERS/<user>/（用户路径）
            "\u{017F}ecret: \u{017F}\(secret)",
        ]
        for input in inputs {
            let guarded = DiagnosticRedactor.redact(input)
            let unguarded = DiagnosticRedactor.redactWithoutGuards(input)
            XCTAssertEqual(
                guarded, unguarded,
                "含 U+017F 的输入守卫与全跑不一致：\(input.debugDescription)")
        }
        // 凭据必须消失（前两条带触发关键词；第三条是路径、断言被换成占位符）。
        XCTAssertFalse(DiagnosticRedactor.redact("\u{017F}ecret=\(secret)").contains(secret))
        XCTAssertFalse(DiagnosticRedactor.redact("ba\u{017F}ic \(secret)").contains(secret))
        XCTAssertEqual(DiagnosticRedactor.redact("/U\u{017F}ERS/\(NSUserName())/x"), "<user-path>",
                       "ICU 折叠下 /UſERS/ 应等于 /Users/（正则带 (?i)）")
    }

    /// 守卫在我实际会遇到的**所有** C 串陷阱下都要与全跑一致。
    ///
    /// 除 NUL 外还有两个已知的字节级坑：
    /// - 空字符串 / 只有 NUL：不能因「针比文本长」之类的边界判断错而漏；
    /// - 极长文本（> 1024）：确认不是只在短样本上成立。
    func testGuardMatchesUnguardedOnByteLevelEdgeCases() {
        let cases: [String] = [
            "",
            "\u{0}",
            "\u{0}\u{0}\u{0}",
            String(repeating: "a", count: 5_000) + " token=SECRET",
            String(repeating: "媒体", count: 2_000) + " password=SECRET",
            "token", // 只有针本身
            "/users/",
        ]
        for input in cases {
            XCTAssertEqual(
                DiagnosticRedactor.redact(input),
                DiagnosticRedactor.redactWithoutGuards(input),
                "边界输入下守卫改变了输出：\(input.prefix(40).debugDescription)")
        }
    }

    /// **关键词表与正则必须双向同步。**
    ///
    /// 审查实测：去掉表里的 `passwd` / `client-secret` / `access-token` /
    /// `x-emby-token`，**84 条用例全绿** —— 因为没有任何用例检查同步性。
    /// 而表漏词的方向就是**真泄漏**（守卫跳过 → 该类凭据明文留下）。
    ///
    /// ## 判据怎么取
    ///
    /// 不能用「守卫版 ≠ 全跑版」——正则会命中时两者**都会**脱敏、结果相同。
    /// 正确的判据是**直接看守卫放行与否**：关键词表的语义就是「含这个词 ⇒ 放行
    /// `sensitiveAssignment` 这趟」。所以对每个关键词断言
    /// `containsAnySensitiveKeywordProbe`（即 `containsASCII(折叠串, 关键词)`）为真。
    ///
    /// 这条同时钉住了「折叠视角」——`ſ` 那类反例会让 `containsASCII` 查不到。
    func testEveryKeywordInTheTableActuallyTripsTheGuard() {
        let keywords = DiagnosticRedactor.assignmentKeywordsForTesting
        XCTAssertFalse(keywords.isEmpty, "关键词表空了")

        var notTripping: [String] = []
        for keyword in keywords {
            // ⚠️ 必须**逐词**问「这个词自己认不认得出」，不能问「整表是否命中」——
            // 后者会被别的词顺带命中，去掉任何一个词都仍然全绿（审查实测）。
            if !DiagnosticRedactor.containsSensitiveKeywordForTesting(keyword) {
                notTripping.append(keyword)
            }
            // 大小写变体也必须被认出（守卫是大小写不敏感的）。
            if !DiagnosticRedactor.containsSensitiveKeywordForTesting(keyword.uppercased()) {
                notTripping.append("\(keyword)（大写）")
            }
        }
        XCTAssertTrue(
            notTripping.isEmpty,
            "这些关键词在表里，但**单独查它查不到**（折叠/查找有问题 → 该类凭据会漏脱敏）：\(notTripping)")
    }

    /// 反向：正则认得出、但表里**没有**的关键词要被发现。
    ///
    /// 防的是「正则加了新关键词、忘了同步表」。做法是从 pattern 里抽出关键词族，
    /// 要求每一族在表里至少有一个形态。
    func testKeywordsTheRegexKnowsAreAllInTheTable() {
        let pattern = DiagnosticRedactor.sensitiveAssignmentPatternForTesting.pattern
        let families = Self.keywordFamilies(inPattern: pattern)
        XCTAssertFalse(families.isEmpty, "没能从正则里抽出关键词组")

        let table = Set(DiagnosticRedactor.assignmentKeywordsForTesting)
        // 判据用**子串包含**而非等值：守卫是子串匹配，所以表里的 `cookie`
        // 能覆盖正则里的 `set-cookie`。只有「正则词的所有形态都不是表里任何词的
        // 子串」才算漏。
        let missing = families.filter { family in
            family.allSatisfy { form in
                !table.contains { $0.isEmpty == false && form.contains($0) }
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "正则里有、守卫表里一个形态都没有的关键词族（守卫会漏判 → 可能泄漏）："
                + "\(missing.map { $0.sorted() })")
    }

    /// 反向：表里的词必须都能追溯到正则的某个形态。
    ///
    /// 防的是「表里塞了一个和正则完全无关的词」。这类多余词在当前实现下**无害**
    /// （守卫过近似只是多跑一趟正则），但它会掩盖「表与正则已经分家」这件事 ——
    /// 今天多一个词，明天就可能少一个词，而少的那次是泄漏。
    ///
    /// 判据用**子串**：允许 `client-secret`（它是 `client[_-]?secret` 的一个具体形态）
    /// 这类合法过近似，只拦完全追溯不到的词。
    func testEveryTableEntryTracesBackToTheRegex() {
        let pattern = DiagnosticRedactor.sensitiveAssignmentPatternForTesting.pattern
        let forms = Self.keywordFamilies(inPattern: pattern).flatMap { $0 }
        XCTAssertFalse(forms.isEmpty, "没能从正则里抽出关键词形态")

        let unrelated = DiagnosticRedactor.assignmentKeywordsForTesting.filter { word in
            !forms.contains { form in form.contains(word) }
        }
        XCTAssertTrue(
            unrelated.isEmpty,
            "守卫表里有正则完全认不得的词（表与正则已分家）：\(unrelated)")
    }

    /// 从 pattern 文本里抽出「表里应该有的」关键词形态。
    ///
    /// 关键词组是**第一个含 `|` 的非 `(?…)` 括号组**——正则开头还有 `(?i)`、
    /// `("|')?` 这些组，直接取第一个括号会抓错。
    /// 对每个分支展开成具体词：`access[_-]?token` 对应表里的
    /// `access-token` / `access_token` / `accesstoken`，只要有一个就算同步。
    private static func keywordFamilies(inPattern pattern: String) -> [Set<String>] {
        var searchStart = pattern.startIndex
        var group: Substring? = nil
        while let open = pattern[searchStart...].firstIndex(of: "(") {
            guard let close = pattern[open...].firstIndex(of: ")") else { break }
            let inner = pattern[pattern.index(after: open)..<close]
            // 跳过 `(?i)` 这类选项组，以及 `("|')?` 这种引号组（以引号开头）。
            if inner.contains("|"), !inner.hasPrefix("?"), !inner.hasPrefix("\"") {
                group = inner
                break
            }
            searchStart = pattern.index(after: open)
        }
        guard let group else { return [] }
        return group.split(separator: "|").compactMap { piece in
            let text = String(piece)
            if text.contains("[_-]?") {
                let parts = text.components(separatedBy: "[_-]?")
                guard parts.count == 2 else { return nil }
                return [parts[0] + "-" + parts[1],
                        parts[0] + "_" + parts[1],
                        parts[0] + parts[1]]
            }
            if text.contains("[_-]") {
                return [text.replacingOccurrences(of: "[_-]", with: "-"),
                        text.replacingOccurrences(of: "[_-]", with: "_")]
            }
            return text.isEmpty ? nil : [text]
        }
    }

    /// JWT 必须被抹掉（`eyJ…` 是 base64url 里 `{"` 的编码）。
    func testJWTIsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0."
            + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let redacted = DiagnosticRedactor.redact("token in log: \(jwt)")
        XCTAssertFalse(redacted.contains(jwt))
        XCTAssertEqual(redacted, "token in log: <redacted-token>")
    }

    /// URL 里的 userinfo 与 query 必须被抹掉，路径与 host 保留（排障要看端点）。
    func testURLQueryAndUserInfoAreRedacted() {
        let redacted = DiagnosticRedactor.redact(
            "GET https://user:pass@media.example.com/Items/abc/Images/Primary?maxWidth=400&tag=dead")
        XCTAssertFalse(redacted.contains("user:pass"))
        XCTAssertFalse(redacted.contains("maxWidth=400"))
        XCTAssertTrue(redacted.contains("/Items/abc/Images/Primary"), "路径必须保留（排障要看端点）")
    }

    /// 脱敏**不是**幂等的 —— 记录这个既有事实，别让后人误以为可以重复跑。
    ///
    /// 实测：`https://h/a?b=c` 第一趟变 `https://h/a?<redacted>`，
    /// 第二趟的 URL 规则又匹配到同一段、把 `?<redacted>` 再替换一次 →
    /// `https://h/a?<redacted><redacted>`。
    ///
    /// 这不影响正确性（管线里每条记录只脱敏一次），但**重复脱敏会让文本逐渐变脏**，
    /// 所以如果有新代码路径要再过一遍，得先想清楚。
    func testRedactionIsNotIdempotentSoDoNotDoubleRedact() {
        let once = DiagnosticRedactor.redact("https://host.example.com/a?b=c")
        let twice = DiagnosticRedactor.redact(once)
        XCTAssertNotEqual(once, twice, "若将来变成幂等，更新这条注释与用法说明")
    }
}
