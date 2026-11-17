import CoreModel
import JellyfinKit
import XCTest
@testable import OcPlayer

/// 媒体库排序的 UI 层口径：按库类型的候选集、每库持久化 rawValue 的回落解析、
/// 默认方向。服务端键值映射（sortBy/sortOrder 落 query）在 JellyfinKitTests。
final class LibrarySortTests: XCTestCase {

    // MARK: - 按库类型的候选集

    func testMoviesLibraryOffersAllFields() {
        let options = MediaItemsSortField.options(for: .movies)
        XCTAssertEqual(options, [.name, .dateAdded, .year, .rating, .runtime, .random])
    }

    func testBoxSetsOfferAllFields() {
        XCTAssertEqual(
            MediaItemsSortField.options(for: .boxsets),
            MediaItemsSortField.options(for: .movies)
        )
    }

    func testTVShowsLibraryDropsRuntime() {
        let options = MediaItemsSortField.options(for: .tvshows)
        XCTAssertEqual(options, [.name, .dateAdded, .year, .rating, .random])
        XCTAssertFalse(options.contains(.runtime), "剧集的 Runtime 是单集时长，不该出现在剧集库候选里")
    }

    func testOtherLibrariesOnlyOfferGenericFields() {
        let genericTypes: [MediaLibrary.CollectionType] =
            [.homevideos, .music, .musicvideos, .books, .photos, .playlists, .folders, .livetv, .unknown]
        for type in genericTypes {
            XCTAssertEqual(
                MediaItemsSortField.options(for: type),
                [.name, .dateAdded, .random],
                "\(type) 库的评分 / 年份常常缺失，只该给通用三项"
            )
        }
    }

    func testEveryOptionSetStartsAndContainsName() {
        let allTypes: [MediaLibrary.CollectionType] =
            [.movies, .tvshows, .music, .musicvideos, .homevideos, .boxsets, .books, .photos,
             .playlists, .folders, .livetv, .unknown]
        for type in allTypes {
            let options = MediaItemsSortField.options(for: type)
            XCTAssertEqual(options.first, MediaItemsSortField.name, "\(type) 库的第一项必须是名称（回落目标）")
            XCTAssertEqual(Set(options).count, options.count, "\(type) 库候选集不该有重复项")
        }
    }

    // MARK: - 持久化回落解析

    func testResolvedFieldAcceptsValidStoredValue() {
        XCTAssertEqual(
            LibrarySort.resolvedField(rawValue: "dateAdded", collectionType: .movies),
            .dateAdded
        )
    }

    func testResolvedFieldFallsBackToNameOnGarbage() {
        XCTAssertEqual(
            LibrarySort.resolvedField(rawValue: "nonsense", collectionType: .movies),
            .name
        )
        XCTAssertEqual(
            LibrarySort.resolvedField(rawValue: nil, collectionType: .movies),
            .name
        )
    }

    func testResolvedFieldFallsBackWhenFieldNotOfferedForLibrary() {
        // 换服务器 / 库类型变化后，存档字段可能不在新库候选集里。
        XCTAssertEqual(
            LibrarySort.resolvedField(rawValue: "runtime", collectionType: .tvshows),
            .name
        )
        XCTAssertEqual(
            LibrarySort.resolvedField(rawValue: "rating", collectionType: .homevideos),
            .name
        )
    }

    // MARK: - 方向语义

    func testDefaultDirection() {
        XCTAssertTrue(MediaItemsSortField.name.defaultAscending, "名称默认 A→Z")
        XCTAssertFalse(MediaItemsSortField.dateAdded.defaultAscending, "最近添加默认新→旧")
        XCTAssertFalse(MediaItemsSortField.rating.defaultAscending, "评分默认高→低")
    }

    func testRandomHasNoDirection() {
        XCTAssertFalse(MediaItemsSortField.random.hasSortDirection)
        for field in MediaItemsSortField.allCases where field != .random {
            XCTAssertTrue(field.hasSortDirection, "\(field) 应该有方向")
        }
    }

    // MARK: - 观看状态筛选

    func testResolvedWatchStateFallsBackToAll() {
        XCTAssertEqual(LibrarySort.resolvedWatchState(rawValue: nil), .all)
        XCTAssertEqual(LibrarySort.resolvedWatchState(rawValue: "nonsense"), .all)
    }

    func testResolvedWatchStateAcceptsStoredValue() {
        XCTAssertEqual(LibrarySort.resolvedWatchState(rawValue: "watched"), .watched)
        XCTAssertEqual(LibrarySort.resolvedWatchState(rawValue: "unwatched"), .unwatched)
        XCTAssertEqual(LibrarySort.resolvedWatchState(rawValue: "all"), .all)
    }

    // MARK: - rawValue 稳定性（持久化键）

    func testRawValuesAreStable() {
        // 这些字符串会落进 UserDefaults（library.sort.field.<id>），改了等于全员丢记忆。
        XCTAssertEqual(MediaItemsSortField.name.rawValue, "name")
        XCTAssertEqual(MediaItemsSortField.dateAdded.rawValue, "dateAdded")
        XCTAssertEqual(MediaItemsSortField.year.rawValue, "year")
        XCTAssertEqual(MediaItemsSortField.rating.rawValue, "rating")
        XCTAssertEqual(MediaItemsSortField.runtime.rawValue, "runtime")
        XCTAssertEqual(MediaItemsSortField.random.rawValue, "random")
    }
}
