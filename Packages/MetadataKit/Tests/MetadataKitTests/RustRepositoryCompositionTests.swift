import CoreModel
import Foundation
import JellyfinKit
import XCTest
@testable import MetadataKit

final class RustRepositoryCompositionTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for repository composition differential tests")
        }
        return path
    }
    private func core() throws -> RustMediaRepository {
        let path = try library()
        return try XCTUnwrap(RustMediaRepository.make(configuration: .init(), libraryPath: path))
    }
    func testDiskPageReductionMatchesIndependentNativeAcrossGapsAndDuplicates() throws {
        let rust = try core()
        var seed: UInt64 = 123
        for _ in 0..<500 {
            func random(_ count: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 32) % UInt64(count))
            }
            var rows: [CachedPage] = []
            for _ in 0..<random(8) {
                let items = (0..<random(5)).map { _ in
                    makeItem(id: ["é", "e\u{301}", "cat", "dog"][random(4)], year: Int.max)
                }
                rows.append(.init(items: items, totalRecordCount: random(2) == 0 ? nil : Int.max,
                    fetchedAt: Date(), startIndex: random(7), limit: random(5) - 1))
            }
            let shared: MediaPageContent = try rust.compose("diskPage", RustMediaRepository.DiskPage(rows: rows.map(RustMediaRepository.DiskRow.init)))
            XCTAssertEqual(shared, MediaRepository.merge(rows: rows))
        }
    }
    func testAllHomePartialFailureCombinationsMatchNativeWithoutExtraRequests() async throws {
        let path = try library()
        for mask in 0..<16 {
            var values: [MediaHomeRefresh] = []
            for shared in [false, true] {
                let server = StubMediaServer()
                let repo = MediaRepository(server: server, store: nil,
                    now: { Date(timeIntervalSinceReferenceDate: 10.125) },
                    rustCoreLibraryPath: shared ? path : nil, useSharedCore: shared)
                let active = await repo.usesCoreRepository; XCTAssertEqual(active, shared)
                server.userViewsResult = .success([.init(id: "lib", name: "Library", collectionType: .movies)])
                server.resumeResult = .success([makeItem(id: "é", year: Int.max)])
                server.nextUpResult = .success([makeItem(id: "e\u{301}"), makeItem(id: "next")])
                server.latestResult = .success([makeItem(id: "old")])
                _ = await repo.refreshHome()
                server.userViewsResult = mask & 1 == 0 ? .success([]) : .failure(JellyfinError(.noNetwork))
                server.resumeResult = mask & 2 == 0 ? .success([]) : .failure(JellyfinError(.serverUnreachable))
                server.nextUpResult = mask & 4 == 0 ? .success([makeItem(id: "new")]) : .failure(CancellationError())
                server.latestResult = mask & 8 == 0 ? .success([]) : .failure(JellyfinError(.noNetwork))
                let result = await repo.refreshHome(); values.append(result)
                XCTAssertEqual(server.callCount("userViews"),2)
                XCTAssertEqual(server.callCount("resumeItems"),2)
                XCTAssertEqual(server.callCount("nextUp"),2)
                XCTAssertEqual(server.callCount("latestItems"),2)
            }
            XCTAssertEqual(values[0].snapshot.value, values[1].snapshot.value)
            XCTAssertEqual(values[0].snapshot.source, values[1].snapshot.source)
            XCTAssertEqual(values[0].snapshot.fetchedAt, values[1].snapshot.fetchedAt)
            XCTAssertEqual(values[0].failures,values[1].failures)
        }
    }
    func testSeriesMissingHintSpecialSeasonAndCollectionFallbackMatchNative() async throws {
        let path = try library()
        for scenario in 0..<6 {
            var values: [MediaDetailRefresh] = []
            var calls: [[String:Int]] = []
            for shared in [false,true] {
                let server = StubMediaServer()
                let kind: MediaItem.Kind = scenario < 4 ? .series : .boxSet
                server.itemResult = .success(makeItem(id:"item",kind:kind,year:Int.max))
                server.seasonsResult = .success([
                    makeItem(id:"special",kind:.season,seasonNumber:0),
                    makeItem(id:"missing",kind:.season),
                    makeItem(id:"regular",kind:.season,seasonNumber:1)])
                server.episodesResult = .success([makeItem(id:"episode",kind:.episode,episodeNumber:Int.max)])
                server.itemsPageRows = [makeItem(id:"member",year:Int.max)]
                let repo = MediaRepository(server: server,store:nil,
                    now: { Date(timeIntervalSinceReferenceDate:-10.125) },
                    rustCoreLibraryPath:shared ? path : nil,useSharedCore:shared)
                let hint: MediaItem.Kind? = scenario == 0 ? nil : kind
                _ = try await repo.refreshDetail(itemID:"item",kindHint:hint)
                if scenario == 2 { server.episodesResult = .failure(JellyfinError(.noNetwork)) }
                if scenario == 3 { server.seasonsResult = .failure(JellyfinError(.noNetwork)) }
                if scenario == 5 { server.itemsPageResult = .failure(JellyfinError(.noNetwork)) }
                values.append(try await repo.refreshDetail(itemID:"item",kindHint:hint))
                calls.append(server.callCounts)
            }
            XCTAssertEqual(values[0].snapshot.value,values[1].snapshot.value)
            XCTAssertEqual(values[0].snapshot.fetchedAt,values[1].snapshot.fetchedAt)
            XCTAssertEqual(values[0].failures,values[1].failures)
            XCTAssertEqual(calls[0],calls[1])
            if scenario < 4 { XCTAssertEqual(values[1].snapshot.value.episodesSeasonID,"missing") }
        }
    }
}
