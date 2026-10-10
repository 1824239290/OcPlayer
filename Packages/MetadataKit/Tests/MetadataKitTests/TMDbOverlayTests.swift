import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 叠加层取值策略（文本优先 / 图片只补缺）+ 落库往返。
final class TMDbOverlayTests: XCTestCase {

    private func entity(
        id: Int = 603, type: TMDbMediaType = .movie,
        title: String? = "黑客帝国", overview: String? = "TMDb 简介",
        genres: [String] = ["动作"], rating: Double? = 8.2,
        cast: [CastMember] = [], poster: String? = "/p.jpg", backdrop: String? = "/b.jpg"
    ) -> TMDbEntity {
        TMDbEntity(id: id, mediaType: type, title: title, originalTitle: "The Matrix",
                   overview: overview, posterPath: poster, backdropPath: backdrop,
                   voteAverage: rating, genres: genres, cast: cast)
    }

    private func overlay(
        entity e: TMDbEntity? = nil,
        source: TMDbLinkSource = .providerID,
        confidence: Double = 1.0
    ) -> TMDbOverlay {
        let link = TMDbLink(itemID: "i1", entityKey: .movie(603), source: source,
                            confidence: confidence, linkedAt: Date())
        return TMDbOverlay(entity: e ?? entity(), link: link, fetchedAt: Date(), isExpired: false)
    }

    // MARK: - 文本策略

    /// `preferTMDbText = true`：TMDb 顶替服务端。
    func testPreferTMDbReplacesServerText() {
        let o = overlay()
        XCTAssertEqual(o.displayTitle(serverValue: "服务端标题", preferTMDb: true), "黑客帝国")
        XCTAssertEqual(o.displayOverview(serverValue: "服务端简介", preferTMDb: true), "TMDb 简介")
    }

    /// `preferTMDbText = false`：只补空缺，不顶替。
    func testNotPreferTMDbOnlyFillsGaps() {
        let o = overlay()
        XCTAssertEqual(o.displayTitle(serverValue: "服务端标题", preferTMDb: false), "服务端标题")
        XCTAssertEqual(o.displayOverview(serverValue: "服务端简介", preferTMDb: false), "服务端简介")
        // 服务端缺 → 用 TMDb
        XCTAssertEqual(o.displayTitle(serverValue: "", preferTMDb: false), "黑客帝国")
        XCTAssertEqual(o.displayOverview(serverValue: nil, preferTMDb: false), "TMDb 简介")
        XCTAssertEqual(o.displayOverview(serverValue: "", preferTMDb: false), "TMDb 简介")
    }

    /// **TMDb 的空串必须当作「没有」**：它用空串表示「这门语言没这个字段」。
    /// 用 `??` 会把空串当有效值，于是把服务端的简介顶成空白。
    func testTMDbEmptyStringFallsBackToServerValue() {
        let o = overlay(entity: entity(title: "", overview: ""))
        XCTAssertEqual(o.displayTitle(serverValue: "服务端标题", preferTMDb: true), "服务端标题")
        XCTAssertEqual(o.displayOverview(serverValue: "服务端简介", preferTMDb: true), "服务端简介")
        XCTAssertEqual(o.displayTitle(serverValue: "", preferTMDb: true), "")
    }

    func testGenresAndRatingFollowSamePolicy() {
        let o = overlay()
        XCTAssertEqual(o.displayGenres(serverValue: ["服务端类型"], preferTMDb: true), ["动作"])
        XCTAssertEqual(o.displayGenres(serverValue: ["服务端类型"], preferTMDb: false), ["服务端类型"])
        XCTAssertEqual(o.displayGenres(serverValue: [], preferTMDb: false), ["动作"])
        XCTAssertEqual(o.displayRating(serverValue: 7.0, preferTMDb: true), 8.2)
        XCTAssertEqual(o.displayRating(serverValue: 7.0, preferTMDb: false), 7.0)
        XCTAssertEqual(o.displayRating(serverValue: nil, preferTMDb: false), 8.2)
    }

    /// 演员映射必须带 `kind: "Actor"`——UI 只显示 Actor，传别的会让 TMDb 补的
    /// 演员一个都不显示（而且不报错）。
    func testCastMappingCarriesActorKind() {
        let o = overlay(entity: entity(cast: [CastMember(id: 1, name: "基努", character: "Neo")]))
        let mapped = o.displayCast(serverValue: [], preferTMDb: true)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].kind, "Actor", "kind 必须是 Actor，否则 UI 不显示")
        XCTAssertEqual(mapped[0].role, "Neo")
        XCTAssertEqual(mapped[0].id, "tmdb-1", "id 要加前缀，避免与服务端的演员 id 撞")
    }

    /// **TMDb 演员的头像必须能反查到路径**。
    ///
    /// 这是一次真实缺陷的回归：演员头像原先一律由「服务端条目 id」拼 URL，而 TMDb
    /// 演员的 id 在服务端根本不存在——实测服务端返回 **400**（日志实证
    /// `/Items/tmdb-1254052/Images/Primary` → 400），每个演员一张破图 + 一次白打的
    /// 请求（一页最多 20 个）。修法是让叠加层能由 `Person.id` 反查 TMDb 头像路径。
    func testCastProfilePathIsResolvableFromPersonID() {
        let o = overlay(entity: entity(cast: [
            CastMember(id: 1254052, name: "内田雄马", character: "百川稻子", profilePath: "/a.jpg"),
            CastMember(id: 999, name: "无头像的人", character: nil, profilePath: nil),
        ]))
        let people = o.displayCast(serverValue: [], preferTMDb: true)

        XCTAssertEqual(o.profilePath(forPersonID: people[0].id), "/a.jpg")
        XCTAssertNil(o.profilePath(forPersonID: people[1].id), "TMDb 没有头像时返回 nil")
        // 服务端的演员 id 不该被误认为 TMDb 的
        XCTAssertNil(o.profilePath(forPersonID: "server-actor-id"))
        XCTAssertNil(o.profilePath(forPersonID: ""))
        // 前缀不对但数字对：也不认
        XCTAssertNil(o.profilePath(forPersonID: "1254052"))
    }

    /// 前缀是**两套编号的隔离带**：服务端与 TMDb 的演员 id 可能撞号，
    /// 撞了就会「拿服务端 id 问服务端、拿到另一个人的头像」这种静默错图。
    func testCastIDsArePrefixed() {
        let o = overlay(entity: entity(cast: [CastMember(id: 42, name: "某人")]))
        let people = o.displayCast(serverValue: [], preferTMDb: true)
        XCTAssertEqual(people[0].id, "tmdb-42")
        XCTAssertTrue(people[0].id.hasPrefix(TMDbOverlay.tmdbPersonPrefix))
    }

    /// 服务端自己的演员**不该**被当成 TMDb 演员（`preferTMDb: false` 且服务端有数据时
    /// 原样返回，id 保持服务端形态）。
    func testServerCastIsLeftAlone() {
        let o = overlay(entity: entity(cast: [CastMember(id: 1, name: "TMDb 的人")]))
        let serverPeople = [MediaItem.Person(id: "srv-1", name: "服务端的人",
                                             role: "角色", kind: "Actor")]
        let kept = o.displayCast(serverValue: serverPeople, preferTMDb: false)
        XCTAssertEqual(kept.map(\.id), ["srv-1"])
        XCTAssertNil(o.profilePath(forPersonID: kept[0].id))
    }

    func testEmptyOverlayLeavesServerValuesUntouched() {
        let empty = TMDbOverlay(source: .search, confidence: 0.9, entityKey: .movie(1))
        XCTAssertEqual(empty.displayTitle(serverValue: "服务端", preferTMDb: true), "服务端")
        XCTAssertEqual(empty.displayGenres(serverValue: ["A"], preferTMDb: true), ["A"])
        XCTAssertNil(empty.displayOverview(serverValue: nil, preferTMDb: true))
    }

    // MARK: - 分集（季叠加层）

    private func seasonOverlay(episodes: [EpisodeEntry]) -> TMDbOverlay {
        let season = TMDbSeason(seasonNumber: 2, name: "第 2 季", overview: "第二季简介",
                                posterPath: "/s2.jpg", episodes: episodes)
        let link = TMDbLink(itemID: "series", entityKey: .tv(100),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        return TMDbOverlay(season: season, link: link, fetchedAt: Date(), isExpired: false)
    }

    /// **服务端的「第 N 集」是没数据的表现，不是用户的元数据**——无论开关如何都该
    /// 被 TMDb 的真标题顶掉。用户实测指出图一里 S1E9 就显示成「第 9 集」。
    func testPlaceholderEpisodeNameIsReplacedEvenWhenTMDbIsNotPreferred() {
        let o = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 9, name: "妹妹的发明")])
        // preferTMDb = false（只补缺）时，占位名仍应被顶掉
        XCTAssertEqual(o.displayEpisodeTitle(number: 9, serverValue: "第 9 集", preferTMDb: false),
                       "妹妹的发明")
        XCTAssertEqual(o.displayEpisodeTitle(number: 9, serverValue: "第9集", preferTMDb: false),
                       "妹妹的发明")
        XCTAssertEqual(o.displayEpisodeTitle(number: 9, serverValue: "Episode 9", preferTMDb: false),
                       "妹妹的发明")
    }

    /// 但**真实的**服务端标题不该被顶掉（`preferTMDb = false` 时）。
    func testRealServerEpisodeTitleIsKeptWhenNotPreferred() {
        let o = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 1, name: "TMDb 的标题")])
        XCTAssertEqual(o.displayEpisodeTitle(number: 1, serverValue: "服务端的真标题", preferTMDb: false),
                       "服务端的真标题")
        // 开了 TMDb 优先就该换
        XCTAssertEqual(o.displayEpisodeTitle(number: 1, serverValue: "服务端的真标题", preferTMDb: true),
                       "TMDb 的标题")
    }

    /// 服务端名字为空 → 用 TMDb。
    func testEmptyServerEpisodeNameUsesTMDb() {
        let o = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 1, name: "TMDb 标题")])
        XCTAssertEqual(o.displayEpisodeTitle(number: 1, serverValue: "", preferTMDb: false), "TMDb 标题")
    }

    /// TMDb 没有这一集 / 没有标题 → 原样返回服务端值（不能弄丢标题）。
    func testMissingTMDbEpisodeFallsBackToServerValue() {
        let o = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 1, name: "只有第一集")])
        XCTAssertEqual(o.displayEpisodeTitle(number: 99, serverValue: "第 99 集", preferTMDb: true),
                       "第 99 集")
        let noName = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 2, name: nil)])
        XCTAssertEqual(noName.displayEpisodeTitle(number: 2, serverValue: "第 2 集", preferTMDb: true),
                       "第 2 集")
    }

    func testEpisodeOverviewFollowsPolicy() {
        let o = seasonOverlay(episodes: [EpisodeEntry(episodeNumber: 3, name: "X",
                                                      overview: "TMDb 的分集简介")])
        XCTAssertEqual(o.displayEpisodeOverview(number: 3, serverValue: "服务端简介", preferTMDb: true),
                       "TMDb 的分集简介")
        XCTAssertEqual(o.displayEpisodeOverview(number: 3, serverValue: "服务端简介", preferTMDb: false),
                       "服务端简介")
        XCTAssertEqual(o.displayEpisodeOverview(number: 3, serverValue: nil, preferTMDb: false),
                       "TMDb 的分集简介")
        XCTAssertNil(o.displayEpisodeOverview(number: 99, serverValue: nil, preferTMDb: true))
    }

    func testEpisodeLookupAndStillPath() {
        let o = seasonOverlay(episodes: [
            EpisodeEntry(episodeNumber: 1, name: "A", stillPath: "/a.jpg"),
            EpisodeEntry(episodeNumber: 2, name: "B", stillPath: nil),
        ])
        XCTAssertEqual(o.episode(number: 1)?.name, "A")
        XCTAssertNil(o.episode(number: 3))
        XCTAssertEqual(o.episodeStillPath(number: 1), "/a.jpg")
        XCTAssertNil(o.episodeStillPath(number: 2))
        XCTAssertEqual(o.episodes.count, 2)
    }

    /// 电影/剧叠加层不该有分集（`episodes` 为空）——否则会拿别的季的数据当自己的。
    func testEntityOverlayHasNoEpisodes() {
        let o = overlay()
        XCTAssertTrue(o.episodes.isEmpty)
        XCTAssertNil(o.episode(number: 1))
        XCTAssertEqual(o.displayEpisodeTitle(number: 1, serverValue: "服务端", preferTMDb: true),
                       "服务端")
    }

    /// 占位名识别的边界：`第 9 集`/`第9話`/`Episode 9`/纯数字 算占位；
    /// **有真实内容的标题不算**（不能把「9 号球衣」这种真标题顶掉）。
    func testPlaceholderNameDetection() {
        for placeholder in ["第 9 集", "第9集", "第 9 話", "Episode 9", "episode 9",
                            "EP9", "Ep. 9", "9", "  ", "",
                            // 实测服务端的文件名派生形态（锚开头就抓不到它）
                            "我的朋友很少 - S01E00 - 第 0 集",
                            "Some.Show.S01E03.第 3 集"] {
            XCTAssertTrue(TMDbOverlay.isPlaceholderEpisodeName(placeholder),
                          "「\(placeholder)」应判为占位名")
        }
        for real in ["妹妹的发明", "第 9 集的秘密", "9 号球衣", "Episode", "第九集", "S1E9"] {
            XCTAssertFalse(TMDbOverlay.isPlaceholderEpisodeName(real),
                           "「\(real)」是真实标题，不该被顶掉")
        }
    }

    // MARK: - 图片策略

    /// **默认 TMDb 优先**（用户口径：填了 key 就是想要完整补全，能用 TMDb 就用）。
    ///
    /// 但仍然保留「只补缺」这条路：用户显式关掉开关时必须尊重，
    /// 因为刮削器精修过的海报被顶掉是**单向损失**。
    func testPosterPrefersTMDbByDefault() {
        let server = URL(string: "http://server/Items/x/Images/Primary?maxWidth=400")!
        let o = overlay()
        let policy = TMDbImagePolicy()

        XCTAssertEqual(DisplayMetadata.posterURL(serverURL: server, overlay: o,
                                                 requestedWidth: 400, policy: policy)?.host,
                       "image.tmdb.org", "默认 TMDb 优先：服务端有图也用 TMDb")
    }

    /// 显式关掉后只补缺：服务端已有图就不动。
    func testPosterOnlyFillsMissingWhenDisabled() {
        let server = URL(string: "http://server/Items/x/Images/Primary?maxWidth=400")!
        let o = overlay()
        let policy = TMDbImagePolicy(replacesExisting: false)

        XCTAssertEqual(DisplayMetadata.posterURL(serverURL: server, overlay: o,
                                                 requestedWidth: 400, policy: policy), server,
                       "服务端有图 → 保留服务端")
        let tmdb = DisplayMetadata.posterURL(serverURL: nil, overlay: o,
                                            requestedWidth: 400, policy: policy)
        XCTAssertEqual(tmdb?.absoluteString, "https://image.tmdb.org/t/p/w500/p.jpg",
                       "服务端缺图 → 用 TMDb，且按宽度映射档位（400→w500）")
    }

    func testPosterReplacesWhenPolicyAllows() {
        let server = URL(string: "http://server/x.jpg")!
        let o = overlay()
        let url = DisplayMetadata.posterURL(serverURL: server, overlay: o, requestedWidth: 400,
                                            policy: TMDbImagePolicy(replacesExisting: true))
        XCTAssertEqual(url?.host, "image.tmdb.org", "允许顶替时应换成 TMDb 图")
    }

    /// TMDb 没有海报时回落服务端（不能因为「想用 TMDb」而把已有的图弄没）。
    func testFallsBackToServerWhenTMDbHasNoImage() {
        let o = overlay(entity: entity(poster: nil))
        let server = URL(string: "http://server/x.jpg")!
        XCTAssertEqual(DisplayMetadata.posterURL(serverURL: server, overlay: o, requestedWidth: 400,
                                                 policy: TMDbImagePolicy(replacesExisting: true)),
                       server)
        XCTAssertNil(DisplayMetadata.posterURL(serverURL: nil, overlay: o, requestedWidth: 400,
                                              policy: TMDbImagePolicy()))
    }

    func testBackdropFollowsSameRule() {
        let o = overlay()
        let url = DisplayMetadata.backdropURL(serverURL: nil, overlay: o, requestedWidth: 1600,
                                             policy: TMDbImagePolicy())
        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/original/b.jpg")
    }

    /// 识别 TMDb 图：决定要不要带服务端认证头（给 CDN 发 Jellyfin 凭证无意义且多送一处）。
    func testIdentifiesTMDbImages() {
        XCTAssertTrue(DisplayMetadata.isTMDbImage(URL(string: "https://image.tmdb.org/t/p/w500/x.jpg")))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(URL(string: "http://192.168.1.1:8096/Items/x/Images/Primary")))
        XCTAssertFalse(DisplayMetadata.isTMDbImage(nil))
    }

    // MARK: - 实体键

    func testEntityKeyRoundTrips() {
        for key in [TMDbEntityKey.movie(603), .tv(1399), .season(tvID: 1399, number: 2),
                    .collection(210303)] {
            XCTAssertEqual(TMDbEntityKey(storageKey: key.storageKey), key)
        }
    }

    func testEntityKeyRejectsGarbage() {
        for bad in ["", "movie", "movie/abc", "tv/1/season/x", "album/1", "movie/1/season/2",
                    "collection/abc", "collection/1/2"] {
            XCTAssertNil(TMDbEntityKey(storageKey: bad), "「\(bad)」不该被解析")
        }
    }

    /// 合集的键：`collection/{id}`、`kind` 是 collection、`tmdbID` 就是合集 id。
    func testCollectionKeyShape() {
        let key = TMDbEntityKey.collection(210303)
        XCTAssertEqual(key.storageKey, "collection/210303")
        XCTAssertEqual(key.kind, .collection)
        XCTAssertEqual(key.tmdbID, 210303)
    }

    /// 季的 `tmdbID` 是**所含的剧 id**（季没有独立 id），`kind` 仍是 season。
    func testSeasonKeyExposesParentTVID() {
        let key = TMDbEntityKey.season(tvID: 241535, number: 1)
        XCTAssertEqual(key.tmdbID, 241535)
        XCTAssertEqual(key.kind, .season)
        XCTAssertEqual(key.storageKey, "tv/241535/season/1")
    }
}
