@testable import OcPlayer
import CoreModel
import XCTest

/// 详情页外部站点链接（Bangumi / TMDB）的解析。
///
/// 这里钉的都是「宁可少一个图标，也不给一个指错的地址」这类判定：ProviderIds 是
/// 服务器元数据插件写的字符串，脏值（空串 / 非数字 / 0）与「粒度不对」的 id 都在
/// 真实服务器上出现过（分集条目的 Tmdb 是集级的，拼 `/tv/{id}` 会指到别的作品）。
final class DetailExternalLinksTests: XCTestCase {

    private func movie(tmdb: String?) -> MediaItem {
        MediaItem(id: "m1", name: "沙丘", kind: .movie, tmdbID: tmdb)
    }

    private func series(tmdb: String?) -> MediaItem {
        MediaItem(id: "s1", name: "某番", kind: .series, tmdbID: tmdb)
    }

    // MARK: - TMDB 地址

    func testMovieAndSeriesURLByKind() {
        XCTAssertEqual(
            ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "603"))?.absoluteString,
            "https://www.themoviedb.org/movie/603")
        XCTAssertEqual(
            ExternalMetadataLinks.tmdbURL(for: series(tmdb: "209867"))?.absoluteString,
            "https://www.themoviedb.org/tv/209867")
    }

    /// 分集 / 季拿不到确定的剧集级 id：一律不给链接，而不是拼一个会指错作品的地址。
    func testSeasonAndEpisodeGetNoTMDBLink() {
        let episode = MediaItem(id: "e1", name: "第 1 集", kind: .episode,
                                seasonNumber: 1, episodeNumber: 1, tmdbID: "241535")
        let season = MediaItem(id: "se1", name: "第 1 季", kind: .season,
                               seasonNumber: 1, tmdbID: "999")
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: episode))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: season))
    }

    func testDirtyProviderIDsAreTreatedAsMissing() {
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: nil)))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "")))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "   ")))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "abc")))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "0")))
        XCTAssertNil(ExternalMetadataLinks.tmdbURL(for: movie(tmdb: "-5")))
        // 前后空白是服务器脏数据里最常见的一种，能被 trim 到可用值。
        XCTAssertEqual(
            ExternalMetadataLinks.tmdbURL(for: movie(tmdb: " 603 "))?.absoluteString,
            "https://www.themoviedb.org/movie/603")
    }

    // MARK: - Bangumi 地址

    func testBangumiURL() {
        XCTAssertEqual(
            ExternalMetadataLinks.bangumiURL(subjectID: 42)?.absoluteString,
            "https://bgm.tv/subject/42")
        XCTAssertNil(ExternalMetadataLinks.bangumiURL(subjectID: nil))
        XCTAssertNil(ExternalMetadataLinks.bangumiURL(subjectID: 0))
        XCTAssertNil(ExternalMetadataLinks.bangumiURL(subjectID: -1))
    }

    // MARK: - 组合

    func testLinksIncludeOnlyResolvedSites() {
        let both = ExternalMetadataLinks.links(item: movie(tmdb: "603"), bangumiSubjectID: 42)
        XCTAssertEqual(both.map(\.id), ["bangumi", "tmdb"])
        XCTAssertEqual(both.map(\.title), ["在 Bangumi 打开", "在 TMDB 打开"])
        // 品牌图标：两个都用各自的彩色图（详情页行内原色渲染，不做单色化）。
        XCTAssertEqual(both.map(\.assetName), ["bangumi-logo-color", "tmdb-logo"])
        // 宽高都钉死：Bangumi 是正方形标记，TMDb 是宽扁字标，两者高度不同是有意的。
        XCTAssertEqual(both.map(\.size), [CGSize(width: 15, height: 15), CGSize(width: 28, height: 12)])

        XCTAssertEqual(
            ExternalMetadataLinks.links(item: movie(tmdb: "603"), bangumiSubjectID: nil).map(\.id),
            ["tmdb"])
        XCTAssertEqual(
            ExternalMetadataLinks.links(item: series(tmdb: nil), bangumiSubjectID: 7).map(\.id),
            ["bangumi"])
        XCTAssertTrue(
            ExternalMetadataLinks.links(item: series(tmdb: nil), bangumiSubjectID: nil).isEmpty)
    }
}
