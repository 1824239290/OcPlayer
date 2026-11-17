import XCTest
@testable import OcPlayer

/// 直连输入弹窗的取值规则（review-20260914 P3-5）。
final class DirectLinkInputTests: XCTestCase {

    func testAcceptsHTTPAndHTTPSLinks() {
        XCTAssertTrue(DirectLinkInput.isAcceptable("http://192.168.1.10:8096/Videos/1/stream?static=true"))
        XCTAssertTrue(DirectLinkInput.isAcceptable("https://media.example.com/a/b.mkv"))
        XCTAssertTrue(DirectLinkInput.isAcceptable("  https://example.com/a.mkv  "), "两侧空白要 trim")
        XCTAssertTrue(DirectLinkInput.isAcceptable("HTTP://example.com/a.mkv"), "scheme 大小写不敏感")
    }

    func testAcceptsLocalAbsolutePaths() {
        XCTAssertTrue(DirectLinkInput.isAcceptable("/Users/me/Movies/某片.mkv"))
        XCTAssertTrue(DirectLinkInput.isAcceptable("~/Movies/某片.mkv"))
        XCTAssertTrue(DirectLinkInput.isAcceptable("/Users/me/Movies/带 空格.mkv"))
    }

    func testRejectsOtherSchemes() {
        XCTAssertFalse(DirectLinkInput.isAcceptable("file:///Users/me/a.mkv"))
        XCTAssertFalse(DirectLinkInput.isAcceptable("smb://nas/media/a.mkv"))
        XCTAssertFalse(DirectLinkInput.isAcceptable("ftp://example.com/a.mkv"))
        XCTAssertFalse(DirectLinkInput.isAcceptable("jellyfin://item/1"))
    }

    func testRejectsGarbageAndEmpty() {
        XCTAssertFalse(DirectLinkInput.isAcceptable(""))
        XCTAssertFalse(DirectLinkInput.isAcceptable("   "))
        XCTAssertFalse(DirectLinkInput.isAcceptable("随便写点什么"))
        XCTAssertFalse(DirectLinkInput.isAcceptable("Movies/a.mkv"), "相对路径不认（工作目录不定）")
        XCTAssertFalse(DirectLinkInput.isAcceptable("example.com/a.mkv"), "没有 scheme 就当路径，不是路径就拒")
    }

    func testRejectsSchemeWithoutHost() {
        XCTAssertFalse(DirectLinkInput.isAcceptable("http://"))
        XCTAssertFalse(DirectLinkInput.isAcceptable("https:///a.mkv"))
    }
}
