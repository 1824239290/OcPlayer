import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 服务端**合集**（Jellyfin / Emby 的 BoxSet）→ TMDb 合集的定位与补全。
///
/// 现场（2026-10-10 实测本机 Jellyfin 12.1.0 + 真实 TMDb key）：
/// - 合集自己**没有**可用的 `ProviderIds["Tmdb"]`（手工建的合集是空 Map）；
/// - 成员电影的 `/movie/{id}` 里有 `belongs_to_collection`，且同一合集的两个成员
///   给出**同一个** id：EVA → 210303、中二病 → 1192656；
/// - 名字却对不上（Jellyfin「新世纪福音战士新剧场版（系列）」vs TMDb「福音战士新剧场版（系列）」），
///   所以按名字搜合集是条不可信的路。
final class TMDbCollectionTests: XCTestCase {

    private var dir: TemporaryDirectory!
    private var store: MetadataStore!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        store = MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: dir.url))
    }

    override func tearDown() {
        dir?.cleanUp()
        super.tearDown()
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    private func makeEnricher(
        apiKey: String? = "0123456789abcdef0123456789abcdef",
        language: String = "zh-CN",
        routes: @escaping (String) -> (Int, Data)
    ) -> TMDbEnricher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in routes(request.url?.path ?? "") }
        let defaults = UserDefaults(suiteName: "TMDbCollectionTests-\(UUID().uuidString)")!
        let prefs = TMDbPreferences(defaults: defaults)
        prefs.language = language
        let client = TMDbClient(
            session: URLSession(configuration: config),
            credentials: CollectionCredential(key: apiKey),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0))
        return TMDbEnricher(client: client, store: store, preferences: prefs)
    }

    override func tearDownWithError() throws {
        StubProtocol.handler = nil
    }

    private func boxSet(id: String = "box-1") -> MediaItem {
        makeItem(id: id, name: "新世纪福音战士新剧场版（系列）", kind: .boxSet)
    }

    private func member(_ id: String, tmdb: String?) -> MediaItem {
        makeItem(id: id, name: id, kind: .movie, tmdbID: tmdb)
    }

    // MARK: - 成员路线（权威）

    /// 成员的 `belongs_to_collection` 决定合集键：不搜名字，直接拉 `/collection/{id}`。
    func testCollectionResolvesThroughMemberBelongsToCollection() async throws {
        var requestedPaths: [String] = []
        let enricher = makeEnricher { path in
            requestedPaths.append(path)
            if path.hasSuffix("/movie/75629") { return (200, Self.movieInCollectionJSON) }
            if path.hasSuffix("/collection/210303") { return (200, Self.collectionJSON) }
            return (404, Data())
        }
        let box = boxSet()
        let members = [member("m-q", tmdb: "75629"), member("m-final", tmdb: "283566")]

        let didFetch = await enricher.refreshCollection(item: box, members: members, tenant: tenant)
        XCTAssertTrue(didFetch)

        let link = try await store.tmdbLink(itemID: "box-1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .collection(210303))
        XCTAssertEqual(link?.source, .providerID, "成员里的 id 是服务端 ProviderIds 一路带来的，算权威")
        XCTAssertEqual(link?.confidence ?? 0, 1.0, accuracy: 0.0001)

        XCTAssertFalse(requestedPaths.contains { $0.contains("search") },
                       "有成员线索时不该去搜名字：实测名字与 TMDb 对不上")

        let overlay = await enricher.overlay(for: box, tenant: tenant)
        XCTAssertEqual(overlay?.entityKey, .collection(210303))
        XCTAssertEqual(overlay?.title, "福音战士新剧场版（系列）")
        XCTAssertEqual(overlay?.backdropPath, "/eva-backdrop.jpg")
        XCTAssertEqual(overlay?.posterPath, "/eva-poster.jpg")
    }

    /// 第一个成员在 TMDb 上没归集合（`belongs_to_collection` 缺失）时，继续试下一个成员。
    func testCollectionFallsThroughToLaterMember() async throws {
        let enricher = makeEnricher { path in
            if path.hasSuffix("/movie/1") { return (200, Self.movieWithoutCollectionJSON) }
            if path.hasSuffix("/movie/2") { return (200, Self.movieInCollectionJSON) }
            if path.hasSuffix("/collection/210303") { return (200, Self.collectionJSON) }
            return (404, Data())
        }
        let members = [member("m-1", tmdb: "1"), member("m-2", tmdb: "2")]

        await enricher.refreshCollection(item: boxSet(), members: members, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "box-1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .collection(210303), "应跳到有集合归属的那个成员")
    }

    /// 已有对应且数据未过期 → **一个请求都不发**。这是成本闸门：合集页每次打开都会调这里。
    func testCollectionSkipsWhenFreshWithoutAnyRequest() async throws {
        var calls = 0
        let enricher = makeEnricher { path in
            calls += 1
            if path.hasSuffix("/movie/75629") { return (200, Self.movieInCollectionJSON) }
            if path.hasSuffix("/collection/210303") { return (200, Self.collectionJSON) }
            return (404, Data())
        }
        let box = boxSet()
        let members = [member("m-q", tmdb: "75629")]
        await enricher.refreshCollection(item: box, members: members, tenant: tenant)
        let afterFirst = calls
        XCTAssertGreaterThan(afterFirst, 0)

        let again = await enricher.refreshCollection(item: box, members: members, tenant: tenant)

        XCTAssertFalse(again, "未过期不该回源")
        XCTAssertEqual(calls, afterFirst, "第二次打开合集页不该发任何请求")
    }

    // MARK: - 不猜的边界

    /// 成员都没有 TMDb id（未刮削 / Emby 没配 TMDb）→ **不发任何请求**、不落库。
    func testCollectionWithoutMemberIDsDoesNothing() async throws {
        var calls = 0
        let enricher = makeEnricher { _ in
            calls += 1
            return (200, Self.collectionJSON)
        }

        let didFetch = await enricher.refreshCollection(
            item: boxSet(), members: [member("m-1", tmdb: nil)], tenant: tenant)

        XCTAssertFalse(didFetch)
        XCTAssertEqual(calls, 0, "定位不出来时连名字搜索都不该发（那是猜）")
        let link = try await store.tmdbLink(itemID: "box-1", tenant: tenant)
        XCTAssertNil(link, "不许猜一个合集落库")
    }

    /// 成员在 TMDb 上确实没有集合归属 → 同样不落库（页面照旧没有 TMDb 数据）。
    func testCollectionWithoutTMDbCounterpartIsNotLinked() async throws {
        let enricher = makeEnricher { path in
            if path.contains("/movie/") { return (200, Self.movieWithoutCollectionJSON) }
            return (200, Self.collectionJSON)
        }

        let didFetch = await enricher.refreshCollection(
            item: boxSet(), members: [member("m-1", tmdb: "1")], tenant: tenant)

        XCTAssertFalse(didFetch)
        let link = try await store.tmdbLink(itemID: "box-1", tenant: tenant)
        XCTAssertNil(link)
    }

    /// 剧集成员不参与定位（TMDb 的合集只装电影）。
    func testSeriesMembersAreNotUsedForLookup() async throws {
        var calls = 0
        let enricher = makeEnricher { _ in
            calls += 1
            return (200, Self.collectionJSON)
        }
        let seriesMember = makeItem(id: "s-1", name: "剧", kind: .series, tmdbID: "153217")

        let didFetch = await enricher.refreshCollection(
            item: boxSet(), members: [seriesMember], tenant: tenant)

        XCTAssertFalse(didFetch)
        XCTAssertEqual(calls, 0, "剧集没有 belongs_to_collection，不该为它发请求")
    }

    /// 脏 `ProviderIds`（空串 / 0 / 非数字）一律当没有——照旧不发请求。
    func testDirtyProviderIDsAreIgnored() async throws {
        var calls = 0
        let enricher = makeEnricher { _ in
            calls += 1
            return (200, Self.collectionJSON)
        }
        let members = [member("a", tmdb: ""), member("b", tmdb: "0"), member("c", tmdb: "abc")]

        let didFetch = await enricher.refreshCollection(item: boxSet(), members: members,
                                                        tenant: tenant)

        XCTAssertFalse(didFetch)
        XCTAssertEqual(calls, 0)
    }

    // MARK: - 夹具

    /// 真实响应的裁剪版（取自我用这个 App 的 key 抓下来的 `/movie/75629`）。
    static let movieInCollectionJSON = Data(#"""
    {"id":75629,"title":"福音战士新剧场版：Q","original_title":"ヱヴァンゲリヲン新劇場版：Q",
     "overview":"简介","poster_path":"/q.jpg","backdrop_path":"/q-bd.jpg",
     "belongs_to_collection":{"id":210303,"name":"福音战士新剧场版（系列）",
                              "poster_path":"/eva-poster.jpg","backdrop_path":"/eva-backdrop.jpg"}}
    """#.utf8)

    static let movieWithoutCollectionJSON = Data(#"""
    {"id":1,"title":"某片","overview":"简介","poster_path":"/x.jpg"}
    """#.utf8)

    /// 裁剪版 `/collection/210303`。
    static let collectionJSON = Data(#"""
    {"id":210303,"name":"福音战士新剧场版（系列）","overview":"再构建作品。",
     "poster_path":"/eva-poster.jpg","backdrop_path":"/eva-backdrop.jpg",
     "parts":[{"id":75629,"title":"福音战士新剧场版：Q"},
              {"id":283566,"title":"天鹰战士：最后的冲击"}]}
    """#.utf8)
}

/// 本文件自己的凭证替身（同目录里的另外两份都是 `private`）。
private struct CollectionCredential: TMDbCredentialProviding {
    let key: String?
    func apiKey() -> String? { key }
}
