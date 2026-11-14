import CoreModel
import Foundation
import JellyfinKit
import XCTest
@testable import MetadataKit

final class RustRepositoryFlowTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for retained repository flow tests")
        }
        return path
    }
    private struct Stats: Decodable { var active: Int; var nextToken: UInt64 }
    func testPageIdentityMatchesNativeFullDescriptorAndSignedWindowCorpus() throws {
        let path = try library()
        let rust = try XCTUnwrap(RustMediaRepository.make(configuration: .init(), libraryPath: path))
        for parent in [nil,"","é","e\u{301}"] as [String?] {
            for kinds in [nil,[],[.movie],[.series,.movie,.movie]] as [[MediaItem.Kind]?] {
                for sort in [nil,MediaItemsSort(field:.year,ascending:false),.init(field:.random,ascending:true)] {
                    for state in [nil,MediaItemsWatchState.all,.unwatched] {
                        for start in [Int.min,0,Int.max] {
                            let descriptor = MediaPageDescriptor(parentID:parent,kinds:kinds,recursive:false,
                                sort:sort,watchState:state,searchTerm:"猫\n")
                            let shared: PageKey = try rust.flow("pageKey",RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                                kind:"page",now:Date(),descriptor:descriptor,startIndex:start,limit:Int.max))
                            XCTAssertEqual(shared,descriptor.key(startIndex:start,limit:Int.max))
                        }
                    }
                }
            }
        }
    }
    func testEveryPublicRefreshUsesRetainedFlowsAndRetiresPrimaryFailure() async throws {
        let path = try library(), server = StubMediaServer()
        server.itemResult = .success(makeItem(id:"s",kind:.series))
        server.seasonsResult = .success([makeItem(id:"season",kind:.season,seasonNumber:1)])
        server.episodesResult = .success([makeItem(id:"episode",kind:.episode)])
        server.itemsPageRows = [makeItem(id:"movie",year:Int.max)]
        let repo = MediaRepository(server:server,store:nil,rustCoreLibraryPath:path)
        let sharedCore = await repo.rust
        let rust = try XCTUnwrap(sharedCore)
        let active = await repo.usesCoreRepository;XCTAssertTrue(active)
        _ = await repo.refreshHome()
        _ = try await repo.refreshDetail(itemID:"s",kindHint:.series)
        _ = try await repo.refreshPage(.init(parentID:"lib"),startIndex:0,limit:10)
        let stats: Stats = try rust.decode("flow.stats",[:])
        XCTAssertEqual(stats.active,0);XCTAssertGreaterThanOrEqual(stats.nextToken,5)
        server.itemResult = .failure(JellyfinError(.noNetwork))
        do { _ = try await repo.refreshDetail(itemID:"new",kindHint:.series);XCTFail("Expected primary item failure") }
        catch {
            guard let jellyfin = error as? JellyfinError else { throw error }
            guard case .noNetwork = jellyfin.kind else { XCTFail("Wrong primary error"); return }
        }
        let after: Stats = try rust.decode("flow.stats",[:]);XCTAssertEqual(after.active,0)
        struct Ownership: Decodable { var flights: Int }
        let owned: Ownership = try rust.decode("stats",[:]);XCTAssertEqual(owned.flights,0)
    }
    func testConcurrentDetailWaitersAndAuxiliaryFailureMatchNativeRequestCounts() async throws {
        let path = try library()
        var results: [MediaDetailContent] = []
        var counts: [[String:Int]] = []
        for shared in [false,true] {
            let server = StubMediaServer()
            server.itemHook = { try await Task.sleep(for:.milliseconds(80));return makeItem(id:"s",kind:.series) }
            server.seasonsResult = .success([makeItem(id:"season",kind:.season,seasonNumber:1)])
            server.episodesResult = .failure(JellyfinError(.noNetwork))
            let repo = MediaRepository(server:server,store:nil,
                rustCoreLibraryPath:shared ? path : nil,useSharedCore:shared)
            let tasks = (0..<8).map { _ in Task { try await repo.refreshDetail(itemID:"s",kindHint:.series) } }
            while server.callCount("item")==0 { await Task.yield() }
            tasks.last?.cancel()
            for task in tasks {
                let result = try await task.value
                XCTAssertTrue(result.snapshot.value.episodes.isEmpty)
                XCTAssertTrue(result.failures["episodes"]?.isConnectivity == true)
                results.append(result.snapshot.value)
            }
            counts.append(server.callCounts)
        }
        XCTAssertTrue(results.allSatisfy{$0==results[0]});XCTAssertEqual(counts[0],counts[1])
        XCTAssertEqual(counts[1]["item"],1);XCTAssertEqual(counts[1]["seasons"],1);XCTAssertEqual(counts[1]["episodes"],1)
    }
    private struct CacheBundle: Encodable {
        var home: MediaSnapshot<MediaHomeContent>?
        var detail: MediaSnapshot<MediaDetailContent>?
        var item: MediaSnapshot<MediaItem>?
        var page: MediaSnapshot<MediaPageContent>?
        var episodes: MediaSnapshot<[MediaItem]>?
    }
    func testCompleteDiskAndMemoryOnlyReadsMatchNativeWithoutNetworkEffects() async throws {
        let path = try library()
        var outputs: [Data] = []
        for shared in [false,true] {
            let directory = try TemporaryDirectory(); defer { directory.cleanUp() }
            let server = StubMediaServer(), tenant = TenantID(profile:server.profile)
            let store = try MetadataCache.open(at:directory.url,coreLibraryPath:shared ? path : nil,useSharedCore:shared)
            let date = Date(timeIntervalSinceReferenceDate:-100.125)
            try await store.saveLibraries([.init(id:"lib",name:"Library",collectionType:.movies)],tenant:tenant,now:date)
            try await store.saveRail([makeItem(id:"é",year:Int.max)],rail:"resume",tenant:tenant,now:date)
            try await store.saveRail([makeItem(id:"e\u{301}"),makeItem(id:"next")],rail:"nextUp",tenant:tenant,now:date)
            let series = makeItem(id:"series",kind:.series,year:Int.max)
            let season = makeItem(id:"season",kind:.season,seriesID:"series",seasonNumber:1)
            var episode = makeItem(id:"episode",kind:.episode,seriesID:"series",seasonNumber:1,episodeNumber:Int.max)
            episode.seasonID = "season"
            let movie = makeItem(id:"movie",year:Int.max)
            try await store.saveItems([series,season,episode,movie],tenant:tenant,now:date)
            let descriptor = MediaPageDescriptor(parentID:"lib",sort:.init(field:.year,ascending:false))
            try await store.savePage(.init(items:[movie],startIndex:0,totalRecordCount:Int.max),
                key:descriptor.key(startIndex:0,limit:1),tenant:tenant,now:date)
            let repo = MediaRepository(server:server,store:store,now:{date},
                rustCoreLibraryPath:shared ? path : nil,useSharedCore:shared)
            for source in [MediaDataSource.disk,.memory] {
                let item = await repo.cachedItem(itemID:"movie")
                let home = await repo.cachedHome()
                let detail = await repo.cachedDetail(itemID:"series")
                let page = await repo.cachedPage(descriptor,limit:1)
                let episodes = await repo.cachedEpisodes(seriesID:"series",seasonID:"season")
                XCTAssertEqual(item?.source,source);XCTAssertEqual(home?.source,source)
                XCTAssertEqual(detail?.source,source);XCTAssertEqual(page?.source,source);XCTAssertEqual(episodes?.source,source)
                let bundle = CacheBundle(home:home,detail:detail,item:item,page:page,episodes:episodes)
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
                outputs.append(try encoder.encode(bundle))
                if shared {
                    let core = await repo.rust
                    let rust = try XCTUnwrap(core)
                    let stats: Stats = try rust.decode("flow.stats",[:]);XCTAssertEqual(stats.active,0)
                }
            }
            XCTAssertTrue(server.callCounts.isEmpty)
        }
        XCTAssertEqual(outputs[0],outputs[2]);XCTAssertEqual(outputs[1],outputs[3])
    }
    func testPrefetchAndCollectionConveniencesKeepNativeNetworkAndProjectionBehavior() async throws {
        let path = try library()
        var outputs: [MediaPageContent] = []
        for shared in [false,true] {
            let server = StubMediaServer()
            server.itemResult = .success(makeItem(id:"series",kind:.series))
            server.seasonsResult = .success([makeItem(id:"season",kind:.season,seasonNumber:1)])
            server.episodesResult = .success([makeItem(id:"episode",kind:.episode)])
            let repo = MediaRepository(server:server,store:nil,
                rustCoreLibraryPath:shared ? path : nil,useSharedCore:shared)
            await repo.prefetchDetail(itemID:"series",kindHint:.series)
            let before = server.callCounts
            await repo.prefetchDetail(itemID:"series",kindHint:.series)
            XCTAssertEqual(before,server.callCounts)
            XCTAssertEqual(server.callCount("item"),1)
            server.itemsPageRows = [makeItem(id:"member",year:Int.max)]
            let result = try await repo.refreshCollectionMembers(itemID:"collection")
            let cached = await repo.cachedCollectionMembers(itemID:"collection")
            XCTAssertEqual(result.value,cached?.value);XCTAssertEqual(cached?.source,.memory)
            XCTAssertEqual(server.lastItemsPageQuery?.parentID,"collection")
            XCTAssertEqual(server.lastItemsPageQuery?.recursive,false)
            outputs.append(result.value)
        }
        XCTAssertEqual(outputs[0],outputs[1])
    }
}
