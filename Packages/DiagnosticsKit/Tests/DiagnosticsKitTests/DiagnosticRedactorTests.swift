import Foundation
import XCTest
@testable import DiagnosticsKit

final class DiagnosticRedactorTests: XCTestCase {

    func testRedactsUserHomePaths() {
        let output = DiagnosticRedactor.redact("播放文件 /Users/jumusu/Movies/a.mkv 失败")
        XCTAssertTrue(output.contains("<user-path>"))
        XCTAssertFalse(output.contains("/Users/jumusu"))
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
