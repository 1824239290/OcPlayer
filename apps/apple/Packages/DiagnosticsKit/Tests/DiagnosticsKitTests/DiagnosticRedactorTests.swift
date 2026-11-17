import Foundation
import XCTest
@testable import DiagnosticsKit

final class DiagnosticRedactorTests: XCTestCase {

    func testRedactsUserHomePaths() {
        // 按当前用户名构造，测试才不依赖跑测试的机器是谁。
        let home = "/Users/\(NSUserName())/Movies/a.mkv"
        let output = DiagnosticRedactor.redact("播放文件 \(home) 失败")
        XCTAssertTrue(output.contains("<user-path>"))
        XCTAssertFalse(output.contains(NSUserName()))
        // 裸家目录（没有后续路径段）也要抹掉。
        let bare = DiagnosticRedactor.redact("工作目录 /Users/\(NSUserName()) 不可写")
        XCTAssertTrue(bare.contains("<user-path>"))
    }

    /// 回归：脱敏正则曾写成 `/(?:Users|home)/…` 的泛匹配，而 `/Users/` 同时是
    /// Jellyfin / Emby 的 API 路由前缀 —— 于是网络日志里最需要的请求路径整段变成
    /// `<user-path>`，排障时看不出是哪个端点慢。锚定本机用户名后不再误伤。
    func testKeepsServerAPIRoutesIntact() {
        for path in ["/Users/user-e/Views",
                     "/Users/user-e/Items/Resume",
                     "/Users/user-e/Items/Latest",
                     "/Users/user-e/PlayedItems/ep-9",
                     "/Users/abc123/Items/abc"] {
            let output = DiagnosticRedactor.redact("请求成功 path=\(path) duration_ms=382")
            XCTAssertTrue(output.contains(path), "API 路径不该被脱敏：\(path) → \(output)")
        }
    }

    func testRedactsAppContainerPaths() {
        let output = DiagnosticRedactor.redact(
            "缓存目录 /var/mobile/Containers/Data/Application/ABCDEF/Library 已满"
        )
        XCTAssertTrue(output.contains("<app-container-path>"))
        XCTAssertFalse(output.contains("/var/mobile/Containers"))
    }

    func testRedactsURLUserinfoAndQuery() {
        let input = "请求 https://admin:s3cret@jellyfin.local:8096/Items/abc?api_key=xyz&b=2 超时"
        let output = DiagnosticRedactor.redact(input)
        XCTAssertFalse(output.contains("s3cret"))
        XCTAssertFalse(output.contains("api_key=xyz"))
        XCTAssertTrue(output.contains("https://<redacted>@jellyfin.local:8096/Items/abc?<redacted>"))
    }

    func testRedactsAuthorizationHeader() {
        let output = DiagnosticRedactor.redact("Authorization: Bearer abc123def456ghi789")
        XCTAssertFalse(output.contains("abc123def456ghi789"))
        XCTAssertTrue(output.contains("<redacted>"))
    }

    func testRedactsJWTs() {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let output = DiagnosticRedactor.redact("登录 token=\(token) 成功")
        XCTAssertFalse(output.contains("eyJ"))
        XCTAssertTrue(output.contains("<redacted>"))
    }

    func testRedactsSensitiveFieldKeys() {
        let redacted = DiagnosticRedactor.redact([
            "access_token": .string("super-secret"),
            "user_name": .string("ok"),
            "password": .string("hunter2"),
        ])
        XCTAssertEqual(redacted["access_token"], .string("<redacted>"))
        XCTAssertEqual(redacted["password"], .string("<redacted>"))
        XCTAssertEqual(redacted["user_name"], .string("ok"))
    }

    /// 回归：`sensitiveAssignment` 曾要求 key 后**紧跟** `\s*[:=]`，于是 JSON 形态
    /// （`"key":"value"`，分隔符前隔着 key 的收尾引号）整类漏网，凭据原文落盘。
    /// 触发面是真实存在的：`BangumiError.description` 对 4xx 直接回原始响应体，
    /// 而错误文本会以 `\(error)` 插进日志消息，再随诊断包发给别人。
    func testRedactsJSONWrappedCredentials() {
        let cases: [(input: String, secret: String)] = [
            (#"{"api_key":"sk-live-abc123"}"#, "sk-live-abc123"),
            (#"{"access_token":"abcdef123456ghijkl"}"#, "abcdef123456ghijkl"),
            (#"{"refresh_token":"rt-9f8e7d6c5b4a"}"#, "rt-9f8e7d6c5b4a"),
            (#"播放失败 error=HTTP 400: {"AccessToken":"zzz999"}"#, "zzz999"),
            (#"{"token": "sekret-value"}"#, "sekret-value"),
            (#"{"client_secret":"cs-abcdef123456"}"#, "cs-abcdef123456"),
            (#"{"password":"hunter2"}"#, "hunter2"),
            (#"headers=["X-Emby-Token": "abc123secret"]"#, "abc123secret"),
            (#"headers=["X-Api-Key": "xyz789key"]"#, "xyz789key"),
        ]
        for (input, secret) in cases {
            let output = DiagnosticRedactor.redact(input)
            XCTAssertFalse(output.contains(secret), "JSON 形态凭据漏网：\(input) → \(output)")
            XCTAssertTrue(output.contains("<redacted>"), "没打脱敏标记：\(input) → \(output)")
        }
    }

    /// 反向用例：脱敏不能把正常日志吃掉——Jellyfin 的 `/Users/{id}/Items` 路由、
    /// 普通字段名与裸数字都不该变成 `<redacted>`。
    func testKeepsOrdinaryJSONFieldsIntact() {
        for input in [
            #"{"Name":"败犬女主太多了","Type":"Series"}"#,
            #"{"tokenCount":12}"#,
            #"{"apiVersion":"10.9.0"}"#,
        ] {
            let output = DiagnosticRedactor.redact(input)
            XCTAssertEqual(output, input, "不该误伤：\(input) → \(output)")
        }
    }

    /// `isSensitiveKey` 走的是结构化字段那条路（可靠路径）：带前缀的头名也要命中，
    /// 否则各包把 `X-Emby-Token` 当字段名时会漏。
    func testRedactsPrefixedHeaderFieldKeys() {
        let redacted = DiagnosticRedactor.redact([
            "X-Emby-Token": .string("abc123secret"),
            "X-Api-Key": .string("xyz789key"),
            "api_key": .string("sk-live-abc123"),
        ])
        XCTAssertEqual(redacted["X-Emby-Token"], .string("<redacted>"))
        XCTAssertEqual(redacted["X-Api-Key"], .string("<redacted>"))
        XCTAssertEqual(redacted["api_key"], .string("<redacted>"))
    }
}
