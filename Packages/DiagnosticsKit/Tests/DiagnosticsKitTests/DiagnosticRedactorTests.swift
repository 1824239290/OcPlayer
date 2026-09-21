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
}
