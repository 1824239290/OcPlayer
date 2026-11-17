import Foundation
import XCTest

@testable import MetadataKit

/// 镜像源（设置 → 镜像源）在 MetadataKit 这一侧的**契约**：键名、地址规范化、
/// 退化语义、以及三处真正用端点的代码（客户端请求 / 图片 URL / host 判据）。
///
/// 全部离线：解析是纯函数；客户端用例用 `StubProtocol` 挡网络，注入**显式端点**
/// （不读写本机偏好，避免与其他并行用例互相污染）。
final class TMDbEndpointSettingsTests: XCTestCase {

    // MARK: - 键名（跨包契约的字面量）

    /// 开关与 Bangumi 的开关**不是**同一个键（镜像按线路配，两家常是不同的提供方）。
    /// App 层 `MirrorKeyContractTests` 另有一条跨 import 的一致性钉子。
    func testKeyLiteralsAreStable() {
        XCTAssertEqual(TMDbEndpointSettings.mirrorEnabledKey,
                       "dev.jumusu.ocplayer.tmdb.mirrorEnabled")
        XCTAssertEqual(TMDbEndpointSettings.apiMirrorKey,
                       "dev.jumusu.ocplayer.tmdb.mirrorAPIBaseURL")
        XCTAssertEqual(TMDbEndpointSettings.imageMirrorKey,
                       "dev.jumusu.ocplayer.tmdb.mirrorImageBaseURL")
    }

    // MARK: - API 根规范化

    func testAPIBaseAppendsVersionSegmentWhenOnlyHostGiven() {
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("https://api.tmdb.org")?.absoluteString,
                       "https://api.tmdb.org/3")
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("api.tmdb.org")?.absoluteString,
                       "https://api.tmdb.org/3")
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("https://api.tmdb.org/")?.absoluteString,
                       "https://api.tmdb.org/3")
    }

    func testAPIBaseKeepsExplicitPath() {
        // 镜像常挂在路径前缀下（`/tmdb/3`）——原样保留，只去尾斜杠。
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("https://mirror.example/tmdb/3/")?.absoluteString,
                       "https://mirror.example/tmdb/3")
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("https://mirror.example/3")?.absoluteString,
                       "https://mirror.example/3")
    }

    func testAPIBaseNormalizesCaseAndStripsQuery() {
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("  https://Mirror.Example/3  ")?.absoluteString,
                       "https://mirror.example/3")
        XCTAssertEqual(TMDbEndpointSettings.normalizedAPIBase("https://mirror.example/3?api_key=x")?.absoluteString,
                       "https://mirror.example/3")
    }

    func testAPIBaseRejectsMalformedValues() {
        XCTAssertNil(TMDbEndpointSettings.normalizedAPIBase(nil))
        XCTAssertNil(TMDbEndpointSettings.normalizedAPIBase(""))
        XCTAssertNil(TMDbEndpointSettings.normalizedAPIBase("   "))
        XCTAssertNil(TMDbEndpointSettings.normalizedAPIBase("https://"))
        XCTAssertNil(TMDbEndpointSettings.normalizedAPIBase("ftp://mirror.example"))
    }

    // MARK: - 图片根规范化

    func testImageBaseAppendsSizePrefixWhenOnlyHostGiven() {
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://image.tmdb.org")?.absoluteString,
                       "https://image.tmdb.org/t/p")
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("image.tmdb.org/")?.absoluteString,
                       "https://image.tmdb.org/t/p")
    }

    func testImageBaseKeepsExplicitPath() {
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://img.example/t/p")?.absoluteString,
                       "https://img.example/t/p")
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://img.example/cdn")?.absoluteString,
                       "https://img.example/cdn")
    }

    /// 用户直接粘一张图（含档位段）时把档位段吃掉，否则会拼出 `…/w500/w342/x.jpg`。
    func testImageBaseDropsPastedSizeSegment() {
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://image.tmdb.org/t/p/w500")?.absoluteString,
                       "https://image.tmdb.org/t/p")
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://image.tmdb.org/t/p/original/")?.absoluteString,
                       "https://image.tmdb.org/t/p")
        // 只剩档位段时退回默认前缀，而不是留下根路径。
        XCTAssertEqual(TMDbEndpointSettings.normalizedImageBase("https://image.tmdb.org/w500")?.absoluteString,
                       "https://image.tmdb.org/t/p")
    }

    func testImageBaseRejectsMalformedValues() {
        XCTAssertNil(TMDbEndpointSettings.normalizedImageBase(nil))
        XCTAssertNil(TMDbEndpointSettings.normalizedImageBase("https://"))
    }

    // MARK: - 生效端点（总开关 / 逐项退化）

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "TMDbEndpointSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    func testDefaultsToOfficialEndpoints() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TMDbEndpointSettings(defaults: defaults)
        XCTAssertFalse(settings.mirrorEnabled)
        XCTAssertEqual(settings.endpoints, .official)
    }

    /// 总开关关闭时，**即使键里还留着上次填的镜像地址**也必须直连官方。
    func testDisabledSwitchIgnoresStoredMirrors() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: TMDbEndpointSettings.mirrorEnabledKey)
        defaults.set("https://mirror.example/3", forKey: TMDbEndpointSettings.apiMirrorKey)
        defaults.set("https://img.example/t/p", forKey: TMDbEndpointSettings.imageMirrorKey)

        XCTAssertEqual(TMDbEndpointSettings(defaults: defaults).endpoints, .official)
    }

    func testEnabledUsesMirrorsIndependently() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: TMDbEndpointSettings.mirrorEnabledKey)
        // 只填 API：图片继续直连官方。
        defaults.set("https://mirror.example/3", forKey: TMDbEndpointSettings.apiMirrorKey)

        let endpoints = TMDbEndpointSettings(defaults: defaults).endpoints
        XCTAssertEqual(endpoints.apiBaseURL.absoluteString, "https://mirror.example/3")
        XCTAssertEqual(endpoints.imageBaseURL, TMDbEndpoints.official.imageBaseURL)
    }

    /// 非法值只让**那一项**退化，不连累另一项（用户可能只填错一个框）。
    func testInvalidValueFallsBackPerField() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: TMDbEndpointSettings.mirrorEnabledKey)
        defaults.set("https://", forKey: TMDbEndpointSettings.apiMirrorKey)
        defaults.set("https://img.example/t/p", forKey: TMDbEndpointSettings.imageMirrorKey)

        let endpoints = TMDbEndpointSettings(defaults: defaults).endpoints
        XCTAssertEqual(endpoints.apiBaseURL, TMDbEndpoints.official.apiBaseURL)
        XCTAssertEqual(endpoints.imageBaseURL.absoluteString, "https://img.example/t/p")
    }

    // MARK: - 客户端真的走注入的端点

    func testClientRequestsMirroredAPIBase() async throws {
        var seenHost: String?
        var seenPath: String?
        let client = makeClient(
            endpoints: TMDbEndpoints(
                apiBaseURL: URL(string: "https://mirror.example/3")!,
                imageBaseURL: TMDbEndpoints.official.imageBaseURL)
        ) { request in
            seenHost = request.url?.host
            seenPath = request.url?.path
            return (200, Self.movieJSON)
        }

        _ = try await client.movie(id: 603, language: "zh-CN")

        XCTAssertEqual(seenHost, "mirror.example")
        XCTAssertEqual(seenPath, "/3/movie/603")
    }

    // MARK: - 图片 URL / host 判据

    func testImageURLUsesMirroredImageBase() {
        let endpoints = TMDbEndpoints(
            apiBaseURL: TMDbEndpoints.official.apiBaseURL,
            imageBaseURL: URL(string: "https://img.example/t/p")!)
        XCTAssertEqual(
            TMDbImageSize.url(path: "/abc.jpg", size: .w500, endpoints: endpoints)?.absoluteString,
            "https://img.example/t/p/w500/abc.jpg")
        XCTAssertNil(TMDbImageSize.url(path: nil, size: .w500, endpoints: endpoints))
    }

    func testTMDbImageHostJudgementFollowsEndpoints() {
        let officialURL = URL(string: "https://image.tmdb.org/t/p/w500/x.jpg")
        let mirrorURL = URL(string: "https://img.example/t/p/w500/x.jpg")
        let serverURL = URL(string: "http://192.168.1.1:8096/Items/x/Images/Primary")

        XCTAssertTrue(DisplayMetadata.isTMDbImage(officialURL, endpoints: .official))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(mirrorURL, endpoints: .official))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(serverURL, endpoints: .official))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(nil, endpoints: .official))

        let mirrored = TMDbEndpoints(
            apiBaseURL: TMDbEndpoints.official.apiBaseURL,
            imageBaseURL: URL(string: "https://img.example/t/p")!)
        // 镜像模式下镜像域名是 TMDB 图 → 不带服务端认证头；官方域名反而不再是。
        XCTAssertTrue(DisplayMetadata.isTMDbImage(mirrorURL, endpoints: mirrored))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(officialURL, endpoints: mirrored))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(serverURL, endpoints: mirrored))
    }

    // MARK: - 夹具

    private func makeClient(
        apiKey: String? = "0123456789abcdef0123456789abcdef",
        endpoints: TMDbEndpoints,
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> TMDbClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = handler
        return TMDbClient(
            session: URLSession(configuration: config),
            credentials: EndpointStubCredential(key: apiKey),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0),
            endpointProvider: { endpoints })
    }

    /// 本文件私有：`TMDbClientTests` 里的同名替身是 private，跨文件不可见。
    private struct EndpointStubCredential: TMDbCredentialProviding {
        let key: String?
        func apiKey() -> String? { key }
    }

    private static let movieJSON = """
    {"id":603,"title":"黑客帝国","poster_path":"/poster.jpg"}
    """.data(using: .utf8)!
}
