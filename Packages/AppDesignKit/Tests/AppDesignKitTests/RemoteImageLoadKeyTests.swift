import CryptoKit
import Foundation
import XCTest

@testable import AppDesignKit

/// `RemoteImage` 的加载键与凭证指纹。
///
/// ## 为什么要钉
///
/// 加载键是 `.task(id:)` 的身份：它一变，SwiftUI 就当作「新任务」清图重载。
/// 指纹写错会有两种后果，都不报错：
/// - 太敏感（同一凭证算出不同指纹）→ 图反复闪（历史真实事故：authHeader 由
///   Dictionary 拼接、键序抖动导致同语义头产生多种字节串）；
/// - 不够敏感（不同凭证算出同一指纹）→ 换账号后仍显示上一个账号的图。
///
/// 本批把指纹的十六进制编码从 `String(format: "%02x")` 换成查表（4.2×），
/// 又把加载键从「每次 body 现算」改成「`init` 算一次」。两条都必须逐字节等价。
final class RemoteImageLoadKeyTests: XCTestCase {

    /// 与改前完全相同的参考实现（`String(format: "%02x")` 版），做对拍用。
    private static func referenceFingerprint(_ header: String?) -> String {
        guard let header else { return "none" }
        let digest = SHA256.hash(data: Data(header.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// **查表实现必须与 `String(format:)` 逐字节一致。**
    ///
    /// 用真实形状的认证头（含 UUID、版本号、token）与它派生出的 200 个变体对拍 ——
    /// 单测一个固定串不够，十六进制表的高低位写反只在一半字节上暴露。
    func testFingerprintMatchesFormatBasedHex() {
        let base = "MediaBrowser Client=\"OcPlayer\", Device=\"MacBook-Air.local\", "
            + "DeviceId=\"A1B2C3D4-E5F6-7890-ABCD-EF1234567890\", "
            + "Version=\"0.2.1 (567)\", UserId=\"abc123\", "
            + "Token=\"deadbeefcafebabe0123456789abcdef\""

        var headers: [String] = [base, "", "x"]
        for index in 0..<200 {
            headers.append(base + "#\(index)")
            // 也覆盖高位/低位为 0 与 f 的边界：全 0 与全 f 的摘要。
            headers.append(String(repeating: "a", count: index))
        }

        for header in headers {
            XCTAssertEqual(
                RemoteImageTestHook.credentialFingerprint(header),
                Self.referenceFingerprint(header),
                "查表编码与 String(format:) 结果不一致（header 长度 \(header.count)）")
        }
        XCTAssertEqual(RemoteImageTestHook.credentialFingerprint(nil), "none")
    }

    /// 指纹是小写十六进制、固定 16 位。
    func testFingerprintShapeIsLowercaseHex16() {
        let fingerprint = RemoteImageTestHook.credentialFingerprint("any-header")
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(
            fingerprint.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) },
            "必须是小写十六进制，实际 \(fingerprint)")
    }

    /// **不同凭证必须得到不同指纹**（否则换账号后仍显示上一个账号的图）。
    func testFingerprintDistinguishesCredentials() {
        let tokenA = "MediaBrowser Device=\"d\", DeviceId=\"i\", Version=\"1\", UserId=\"u\", Token=\"aaa\""
        let tokenB = "MediaBrowser Device=\"d\", DeviceId=\"i\", Version=\"1\", UserId=\"u\", Token=\"bbb\""
        XCTAssertNotEqual(
            RemoteImageTestHook.credentialFingerprint(tokenA),
            RemoteImageTestHook.credentialFingerprint(tokenB))
    }

    /// 同一输入永远同一指纹。
    func testFingerprintIsStable() {
        let header = "MediaBrowser Device=\"d\", DeviceId=\"i\", Version=\"1\", Token=\"t\""
        let first = RemoteImageTestHook.credentialFingerprint(header)
        for _ in 0..<50 {
            XCTAssertEqual(RemoteImageTestHook.credentialFingerprint(header), first)
        }
    }

    /// 加载键的形状：`url#fingerprint#maxPixelSize`，且 nil 各自有稳定落点。
    func testLoadKeyShape() {
        let url = URL(string: "https://media.example.com/Items/abc/Images/Primary?maxWidth=400")!
        let key = RemoteImageTestHook.loadKey(url: url, authHeader: "h", maxPixelSize: 400)

        let parts = key.split(separator: "#", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "加载键必须是三段：\(key)")
        XCTAssertEqual(String(parts[0]), url.absoluteString)
        XCTAssertEqual(String(parts[1]), RemoteImageTestHook.credentialFingerprint("h"))
        XCTAssertEqual(String(parts[2]), "400")

        // nil 落点稳定且互不相同。
        XCTAssertEqual(
            RemoteImageTestHook.loadKey(url: nil, authHeader: nil, maxPixelSize: nil),
            "#none#0")
        XCTAssertNotEqual(
            RemoteImageTestHook.loadKey(url: url, authHeader: nil, maxPixelSize: 400),
            RemoteImageTestHook.loadKey(url: url, authHeader: "h", maxPixelSize: 400),
            "有/无凭证必须是不同的键，否则换登录态不会重载")
        XCTAssertNotEqual(
            RemoteImageTestHook.loadKey(url: url, authHeader: "h", maxPixelSize: 400),
            RemoteImageTestHook.loadKey(url: url, authHeader: "h", maxPixelSize: 300),
            "解码预算不同必须是不同的键")
    }
}

/// 把 `RemoteImage` 的私有静态方法暴露给测试。
///
/// 不改成 `internal` 是为了不给生产代码留测试缝隙 —— 这个钩子只在
/// `#if DEBUG` 下编译（测试构建天然带 `DEBUG`）。
extension RemoteImage {
    enum TestHook {}
}

enum RemoteImageTestHook {
    static func credentialFingerprint(_ header: String?) -> String {
        RemoteImage.probeCredentialFingerprint(header)
    }

    static func loadKey(url: URL?, authHeader: String?, maxPixelSize: Int?) -> String {
        RemoteImage.probeLoadKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
    }
}
