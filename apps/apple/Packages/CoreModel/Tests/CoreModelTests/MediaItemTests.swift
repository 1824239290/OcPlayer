import XCTest
@testable import CoreModel

final class MediaItemTests: XCTestCase {

    // MARK: - episodeLabel

    func testEpisodeLabelWithSeason() {
        let item = MediaItem(id: "e1", name: "Pilot", kind: .episode, seasonNumber: 1, episodeNumber: 4)
        XCTAssertEqual(item.episodeLabel, "S1E4")
    }

    func testEpisodeLabelWithoutSeason() {
        let item = MediaItem(id: "e2", name: "OVA", kind: .episode, episodeNumber: 7)
        XCTAssertEqual(item.episodeLabel, "E7")
    }

    func testEpisodeLabelNilForNonEpisode() {
        // 非剧集条目一律 nil，即使误填了集数。
        let movie = MediaItem(id: "m1", name: "Movie", kind: .movie, seasonNumber: 1, episodeNumber: 2)
        XCTAssertNil(movie.episodeLabel)
        // episode 缺集数也是 nil。
        XCTAssertNil(MediaItem(id: "e3", name: "Episode", kind: .episode).episodeLabel)
    }

    // MARK: - logoItemID

    func testLogoItemIDInheritsParentWhenOwnTagMissing() {
        let episode = MediaItem(id: "ep1", name: "Ep", kind: .episode, parentLogoItemID: "series1")
        XCTAssertEqual(episode.logoItemID, "series1")
    }

    func testLogoItemIDFallsBackToSelf() {
        // 无父级继承时用自身 id；显式 nil 也是自身。
        XCTAssertEqual(MediaItem(id: "x1", name: "X", kind: .movie).logoItemID, "x1")
        let noParent = MediaItem(id: "x2", name: "X", kind: .movie, parentLogoItemID: nil)
        XCTAssertEqual(noParent.logoItemID, "x2")
    }

    // MARK: - PlayState 语义

    func testPlayStatePercentageIsZeroToOne() {
        // 映射层已把 Jellyfin 的 0–100 除以 100，这里钉住语义：0.375 = 37.5%。
        let state = MediaItem.PlayState(played: false, percentage: 0.375, positionSeconds: 2700)
        XCTAssertEqual(state.percentage, 0.375, accuracy: 1e-12)
        XCTAssertEqual(state.positionSeconds, 2700, accuracy: 1e-12)
        XCTAssertNil(state.unplayedCount)
        XCTAssertFalse(state.played)
    }

    func testPlayStateBoundaryValues() {
        let start = MediaItem.PlayState(played: true, percentage: 0, positionSeconds: 0)
        let end = MediaItem.PlayState(played: true, percentage: 1, positionSeconds: .infinity)
        XCTAssertEqual(start.percentage, 0)
        XCTAssertEqual(end.percentage, 1)
    }

    // MARK: - Kind / CollectionType 原始值

    func testKindRawValuesAreStable() {
        // rawValue 是跨版本落盘/解码的契约，改动就是 breaking。
        XCTAssertEqual(MediaItem.Kind(rawValue: "episode"), .episode)
        XCTAssertEqual(MediaItem.Kind(rawValue: "boxSet"), .boxSet)
        XCTAssertEqual(MediaItem.Kind(rawValue: "musicAlbum"), .musicAlbum)
        XCTAssertNil(MediaItem.Kind(rawValue: "nonexistent"))

        XCTAssertEqual(MediaLibrary.CollectionType(rawValue: "tvshows"), .tvshows)
        XCTAssertEqual(MediaLibrary.CollectionType(rawValue: "boxsets"), .boxsets)
        XCTAssertNil(MediaLibrary.CollectionType(rawValue: "moviesets"))
    }

    // MARK: - Identifiable / Hashable

    func testIdentityAndEqualitySemantics() {
        let a = MediaItem(id: "same", name: "旧标题", kind: .movie)
        var b = MediaItem(id: "same", name: "新标题", kind: .movie)
        // Hashable 全字段合成：标题变了 hash 就变（刷新时能驱动 SwiftUI diff）。
        XCTAssertNotEqual(a, b)
        b.name = "旧标题"
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, "same")
    }

    func testLibraryEquality() {
        let lib1 = MediaLibrary(id: "lib1", name: "电影", collectionType: .movies)
        let lib2 = MediaLibrary(id: "lib1", name: "电影", collectionType: .movies)
        XCTAssertEqual(lib1, lib2)
        XCTAssertEqual(lib1.collectionType, .movies)
    }

    // MARK: - 默认值

    // MARK: - 默认值

    func testInitDefaultsKeepOptionalsNilAndCollectionsEmpty() {
        let item = MediaItem(id: "d1", name: "D", kind: .series)
        XCTAssertNil(item.overview)
        XCTAssertNil(item.year)
        XCTAssertNil(item.runtimeSeconds)
        XCTAssertTrue(item.genres.isEmpty)
        XCTAssertNil(item.communityRating)
        XCTAssertNil(item.officialRating)
        XCTAssertNil(item.seriesID)
        XCTAssertNil(item.playState)
        XCTAssertTrue(item.cast.isEmpty)
        XCTAssertNil(item.primaryImageTag)
        XCTAssertNil(item.logoImageTag)
        XCTAssertNil(item.tmdbID)
    }

    // MARK: - homeStillImageChoice（首页剧照卡取图链）

    // 链序对齐 Jellyfin Web cardBuilder getImgInfo（preferThumb + inheritThumb 默认）：
    // Thumb(自己) → Thumb(剧) → Thumb(父) → Backdrop(自己) → Backdrop(父,仅集)
    // → Primary(自己) → Primary(剧) → Primary(父)。

    func testHomeStillImageEpisodePrefersParentThumbOverOwnPrimary() {
        // 官方默认口径：分集卡片显示剧集横版剧照，而非分集自己的截图。
        let ep = MediaItem(
            id: "ep", name: "第 1 集", kind: .episode, seriesID: "series",
            primaryImageTag: "ep-primary",
            parentThumbItemID: "series", parentThumbImageTag: "series-thumb"
        )
        XCTAssertEqual(
            ep.homeStillImageChoice,
            StillImageChoice(itemID: "series", kind: .thumb, tag: "series-thumb")
        )
    }

    func testHomeStillImageOwnThumbWinsOverParentThumb() {
        let ep = MediaItem(
            id: "ep", name: "第 2 集", kind: .episode,
            thumbImageTag: "own-thumb",
            parentThumbItemID: "series", parentThumbImageTag: "series-thumb"
        )
        XCTAssertEqual(
            ep.homeStillImageChoice,
            StillImageChoice(itemID: "ep", kind: .thumb, tag: "own-thumb")
        )
    }

    func testHomeStillImageSeriesThumbBeatsParentThumb() {
        let ep = MediaItem(
            id: "ep", name: "第 3 集", kind: .episode, seriesID: "series",
            seriesThumbImageTag: "series-thumb",
            parentThumbItemID: "season", parentThumbImageTag: "season-thumb"
        )
        XCTAssertEqual(
            ep.homeStillImageChoice,
            StillImageChoice(itemID: "series", kind: .thumb, tag: "series-thumb")
        )
    }

    func testHomeStillImageMovieUsesBackdropWhenNoThumb() {
        let movie = MediaItem(
            id: "m", name: "电影", kind: .movie,
            primaryImageTag: "poster", backdropImageTag: "fanart"
        )
        XCTAssertEqual(
            movie.homeStillImageChoice,
            StillImageChoice(itemID: "m", kind: .backdrop, tag: "fanart")
        )
    }

    func testHomeStillImageMovieIgnoresParentBackdropAndUsesOwnPrimary() {
        // ParentBackdrop 回退只对分集生效（官方条件 Type === 'Episode'）。
        let movie = MediaItem(
            id: "m", name: "电影", kind: .movie,
            primaryImageTag: "poster",
            parentBackdropItemID: "box", parentBackdropImageTag: "box-fanart"
        )
        XCTAssertEqual(
            movie.homeStillImageChoice,
            StillImageChoice(itemID: "m", kind: .primary, tag: "poster")
        )
    }

    func testHomeStillImageEpisodeUsesParentBackdropWhenNoThumbs() {
        let ep = MediaItem(
            id: "ep", name: "第 4 集", kind: .episode, seriesID: "series",
            parentBackdropItemID: "series", parentBackdropImageTag: "series-fanart"
        )
        XCTAssertEqual(
            ep.homeStillImageChoice,
            StillImageChoice(itemID: "series", kind: .backdrop, tag: "series-fanart")
        )
    }

    func testHomeStillImageFallsThroughToPrimaryChain() {
        // 分集自己有截图时优先自己；三张都没有才轮到剧集海报 / 季海报。
        let ep = MediaItem(
            id: "ep", name: "第 5 集", kind: .episode, seriesID: "series",
            primaryImageTag: "ep-primary"
        )
        XCTAssertEqual(
            ep.homeStillImageChoice,
            StillImageChoice(itemID: "ep", kind: .primary, tag: "ep-primary")
        )

        let orphan = MediaItem(
            id: "ep2", name: "第 6 集", kind: .episode, seriesID: "series",
            seriesPrimaryImageTag: "series-poster"
        )
        XCTAssertEqual(
            orphan.homeStillImageChoice,
            StillImageChoice(itemID: "series", kind: .primary, tag: "series-poster")
        )

        let noSeries = MediaItem(
            id: "ep3", name: "第 7 集", kind: .episode,
            parentPrimaryImageItemID: "season", parentPrimaryImageTag: "season-poster"
        )
        XCTAssertEqual(
            noSeries.homeStillImageChoice,
            StillImageChoice(itemID: "season", kind: .primary, tag: "season-poster")
        )
    }

    func testHomeStillImageNilWhenNoImagesAtAll() {
        XCTAssertNil(MediaItem(id: "x", name: "空", kind: .movie).homeStillImageChoice)
        // 有 tag 但没有可请求的目标 id（如父级 Primary 缺 itemID）时也跳过。
        XCTAssertNil(
            MediaItem(id: "y", name: "缺 id", kind: .episode, parentPrimaryImageTag: "season-poster")
                .homeStillImageChoice
        )
    }
}
