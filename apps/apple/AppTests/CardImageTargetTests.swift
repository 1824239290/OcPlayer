import CoreModel
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 取图链的「没有 tag 就不发请求」。
///
/// 现场（应用户反馈排查，`~/Library/Logs/OcPlayer` 累计 18 条 `图片请求返回非 200`）：
/// 服务端返回的 `ImageTags` 就是「这个条目有没有这张图」的事实来源，缺键 = 本来就没图，
/// 而修复前**照样拼 URL**，于是每个无图条目都白打一次 404：
/// - 合集库（UserView，实测 `ImageTags: {}`）——每次进首页都打一次；
/// - 手工建的合集条目（Jellyfin 新建合集默认不带封面）；
/// - 没头像的演员（演员走 `castImageTarget`，另一条路径，本次不动）。
/// `RemoteImage` 拿到 404 后显示的占位与「url == nil」分支**完全一样**，
/// 所以这条修复只有收益：少一次请求、少一条日志，观感不变（合集另有专属占位图标）。
final class CardImageTargetTests: XCTestCase {

    private func item(
        primaryTag: String? = nil,
        thumbTag: String? = nil,
        backdropTag: String? = nil,
        logoTag: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: "item-1", name: "条目", kind: .movie,
            primaryImageTag: primaryTag, thumbImageTag: thumbTag,
            backdropImageTag: backdropTag, logoImageTag: logoTag)
    }

    func testMissingPrimaryTagProducesNoURL() {
        let server = StubMediaServer()

        let target = item().imageTarget(server, kind: .primary, width: 400)

        XCTAssertNil(target.url, "没有 Primary tag = 服务端没有这张图，不该拼 URL 去打 404")
        XCTAssertEqual(target.authHeader, server.authorizationHeader, "凭证照常带出（占位分支不用它无妨）")
    }

    func testMissingThumbBackdropAndLogoProduceNoURL() {
        let server = StubMediaServer()
        let bare = item()

        XCTAssertNil(bare.imageTarget(server, kind: .thumb, width: 400).url)
        XCTAssertNil(bare.imageTarget(server, kind: .backdrop, width: 1600).url)
        XCTAssertNil(bare.imageTarget(server, kind: .logo, width: 400).url)
    }

    func testExistingTagStillProducesURLWithThatTag() throws {
        let server = StubMediaServer()
        let tagged = item(primaryTag: "tag-abc")

        let target = tagged.imageTarget(server, kind: .primary, width: 400)
        let url = try XCTUnwrap(target.url)

        XCTAssertTrue(url.absoluteString.contains("item-1"), "按条目 id 拼地址")
        XCTAssertTrue(url.absoluteString.contains("tag-abc"), "tag 要进 URL（换图后缓存自然失效）")
    }

    func testNoServerStillProducesNilURL() {
        let target = item(primaryTag: "tag-abc").imageTarget(nil, kind: .primary, width: 400)

        XCTAssertNil(target.url)
        XCTAssertNil(target.authHeader)
    }

    /// 剧集 / 分集的横版图链（`homeStillImageChoice`）不受影响：
    /// 有 tag 的那一档仍然出地址。
    func testHomeStillTargetStillResolvesWhenTagsExist() throws {
        let server = StubMediaServer()
        let episode = MediaItem(
            id: "e-1", name: "第 1 集", kind: .episode,
            seriesID: "s-1", thumbImageTag: "thumb-tag")

        let url = try XCTUnwrap(episode.homeStillImageTarget(server, width: 400).url)

        XCTAssertTrue(url.absoluteString.contains("thumb-tag"))
        XCTAssertTrue(url.absoluteString.contains("e-1"))
    }
}
