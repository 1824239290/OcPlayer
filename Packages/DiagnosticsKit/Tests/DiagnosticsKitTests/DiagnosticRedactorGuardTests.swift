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
