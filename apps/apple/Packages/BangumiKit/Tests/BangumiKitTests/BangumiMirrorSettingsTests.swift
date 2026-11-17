import Foundation
import Testing

@testable import BangumiKit

/// 镜像源（设置 → 镜像源）在 BangumiKit 这一侧的**契约**。
///
/// 设置页只写两个键：总开关 + 根域。这里钉住「写进去的值怎么变成域名」——
/// 特别是三种退化（开关关 / 空串 / 解析不出 host）**必须**落回官方，
/// 否则用户填了一个坏地址就会把整个 Bangumi 分区连到不存在的域名上。
///
/// 全程用纯函数驱动（`resolvedMirrorRootDomain(enabled:rawValue:)`），
/// 不碰 `UserDefaults.standard`：包测试并行跑，改全局键会串台。
@Suite("Bangumi 镜像根域解析")
struct BangumiMirrorSettingsTests {

    // MARK: - 键名（跨包契约的字面量）

    /// 键名是写进 `UserDefaults` 的字面量，**改一个字就等于全网静默失效**
    /// （设置页写 A，包里读 B：开关拨了没反应）。这里把它固定下来；
    /// 总开关与 MetadataKit 那一侧的一致性由 App 层的 `MirrorKeyContractTests` 钉住。
    @Test func keyLiteralsAreStable() {
        #expect(BangumiURL.mirrorEnabledKey == "dev.jumusu.ocplayer.bangumi.mirrorEnabled")
        #expect(BangumiURL.mirrorRootDomainKey == "dev.jumusu.ocplayer.bangumi.mirrorRootDomain")
    }

    // MARK: - 生效解析

    @Test func disabledSwitchAlwaysFallsBackToOfficial() {
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: false, rawValue: "bangumi.lat") == nil)
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: false, rawValue: nil) == nil)
    }

    @Test func enabledAcceptsBareHost() {
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "bangumi.lat")
            == "bangumi.lat")
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "api.bangumi.lat")
            == "api.bangumi.lat")
    }

    /// 用户从浏览器地址栏复制出来的形态（带 scheme / 路径 / 大小写 / 端口）
    /// 都要能收：设置页有「保存」动作，保存时不该因为多了一个斜杠就判失败。
    @Test func enabledNormalizesPastedURLs() {
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "https://bangumi.lat/")
            == "bangumi.lat")
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: " https://Bangumi.LAT ")
            == "bangumi.lat")
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "bangumi.lat/subject/1")
            == "bangumi.lat")
        // 自建反代常带端口：端口必须留在域名里，否则请求会打到 443。
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "http://127.0.0.1:8080")
            == "127.0.0.1:8080")
    }

    @Test func enabledRejectsEmptyAndMalformedValues() {
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: nil) == nil)
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "") == nil)
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "   ") == nil)
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "https://") == nil)
        #expect(BangumiURL.resolvedMirrorRootDomain(enabled: true, rawValue: "http://") == nil)
    }

    // MARK: - 根域 → 四个子域

    /// 根域按约定派生子域：主站 / API / 图床 / 网关。设置页的文案与帮助文字
    /// 就是按这张表写给用户看的（`api.<root>` / `lain.<root>`），
    /// 派生规则一变，文案就不成立。
    @Test func mirrorRootDerivesAllFourDomains() throws {
        let domains = BangumiDomains(mirrorRootDomain: "bangumi.lat")
        #expect(domains.main == "bangumi.lat")
        #expect(domains.api == "api.bangumi.lat")
        #expect(domains.image == "lain.bangumi.lat")
        #expect(domains.next == "next.bangumi.lat")
        #expect(try #require(domains.apiURL(path: "v0/subjects/1").host()) == "api.bangumi.lat")
    }

    /// 端口版的根域要能带到每个子域上（自建反代是一个端口上的四张 vhost）。
    @Test func mirrorRootKeepsPortOnDerivedDomains() throws {
        let domains = BangumiDomains(mirrorRootDomain: "http://127.0.0.1:8080")
        #expect(domains.api == "api.127.0.0.1:8080")
        #expect(try #require(domains.apiURL().port) == 8080)
    }

    // MARK: - 授权页（用户浏览器打开的那一步）

    /// 镜像模式下授权页改走镜像主站：路径与查询原样保留
    /// （`client_id` / `redirect_uri` / `state` 都在查询里，换 host 不改语义）。
    @Test func authorizePageFollowsMirrorMainDomain() throws {
        let official = try #require(
            URL(string: "https://bgm.tv/oauth/authorize?client_id=abc&redirect_uri=ocplayer%3A%2F%2Foauth%2Fcallback&state=s1"))
        let rewritten = BangumiURL.rewrittenMainSiteURL(official, mirrorRootDomain: "bangumi.lat")

        #expect(rewritten.host() == "bangumi.lat")
        #expect(rewritten.path() == "/oauth/authorize")
        let query = URLComponents(url: rewritten, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "client_id" })?.value == "abc")
        #expect(query.first(where: { $0.name == "redirect_uri" })?.value == "ocplayer://oauth/callback")
        #expect(query.first(where: { $0.name == "state" })?.value == "s1")
    }

    /// 官方路线**逐字**返回（不重写、不改 scheme）——登录失败时不该混进镜像的行为。
    @Test func authorizePageIsUntouchedWhenMirrorIsOff() throws {
        let official = try #require(URL(string: "http://bgm.tv/oauth/authorize?state=s1"))
        #expect(BangumiURL.rewrittenMainSiteURL(official, mirrorRootDomain: nil) == official)
    }

    /// 自建反代带端口：端口必须跟过去，否则授权页会打到 443。
    @Test func authorizePageKeepsMirrorPort() throws {
        let official = try #require(URL(string: "https://bgm.tv/oauth/authorize?state=s1"))
        let rewritten = BangumiURL.rewrittenMainSiteURL(
            official, mirrorRootDomain: "127.0.0.1:8080")
        #expect(rewritten.host() == "127.0.0.1")
        #expect(rewritten.port == 8080)
        #expect(rewritten.scheme == "https")
    }

    /// 图片 URL 重写：官方 CDN 的 `lain.bgm.tv` 换成镜像图床；别的图源不动。
    @Test func imageRewriteFollowsMirrorRoot() {
        let cached = BangumiURL.composeImageURLString(
            from: "https://lain.bgm.tv/pic/cover/l/42.jpg", mirror: "bangumi.lat")
        #expect(cached == "https://lain.bangumi.lat/pic/cover/l/42.jpg")

        let untouched = BangumiURL.composeImageURLString(
            from: "https://example.com/pic.jpg", mirror: "bangumi.lat")
        #expect(untouched == "https://example.com/pic.jpg")
    }
}
