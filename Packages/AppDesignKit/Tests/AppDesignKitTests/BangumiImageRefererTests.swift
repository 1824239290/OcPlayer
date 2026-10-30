import Foundation
import XCTest

@testable import AppDesignKit

/// Bangumi 图床的 Referer 判定（`ImagePipeline.bangumiReferer(forHost:)`）。
///
/// 这条判据同时决定两件事：**发不发** Browser UA + Referer，以及**发给谁**。
/// 镜像源上线后 host 从 `lain.bgm.tv` 变成 `lain.<任意根域>`，老写法
/// （`host.contains("bgm.tv")`）会静默不再发 Referer——真被镜像沿用防盗链时
/// 表现是「整面海报裂成占位块」，而不是报错，所以必须钉住。
final class BangumiImageRefererTests: XCTestCase {

    func testOfficialCDNUsesOfficialReferer() {
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "lain.bgm.tv"), "https://bgm.tv/")
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "LAIN.BGM.TV"), "https://bgm.tv/")
    }

    /// 镜像图床：Referer 跟着镜像主站走（`lain.<root>` → `https://<root>/`）。
    func testMirrorCDNDerivesRefererFromRootDomain() {
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "lain.bangumi.lat"),
                       "https://bangumi.lat/")
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "lain.bgm.example.com"),
                       "https://bgm.example.com/")
    }

    /// 自建反代常带端口：Referer 里要保留端口，否则镜像主站对不上。
    func testMirrorCDNKeepsPortInReferer() {
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "lain.127.0.0.1:8080"),
                       "https://127.0.0.1:8080/")
    }

    func testOfficialMainDomainsAlsoGetBrowserHeaders() {
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "bgm.tv"), "https://bgm.tv/")
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "next.bgm.tv"), "https://bgm.tv/")
        XCTAssertEqual(ImagePipeline.bangumiReferer(forHost: "api.bgm.tv"), "https://bgm.tv/")
    }

    /// 非 Bangumi 图源一个头都不加（TMDB CDN / 自家 Jellyfin 用项目统一 UA）。
    func testOtherHostsAreUntouched() {
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "image.tmdb.org"))
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "192.168.5.107"))
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "ocplayer.invalid"))
    }

    /// 老判据 `contains("bgm.tv")` 的漏洞：伪装域名会被当成官方图床、白送 Referer。
    func testLookalikeHostsAreNotTreatedAsBangumi() {
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "bgm.tv.evil.example"))
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "notbgm.tv"))
    }

    /// `lain.` 后面为空（畸形输入）不产出空 Referer。
    func testEmptyRootAfterCDNPrefixIsIgnored() {
        XCTAssertNil(ImagePipeline.bangumiReferer(forHost: "lain."))
    }
}
