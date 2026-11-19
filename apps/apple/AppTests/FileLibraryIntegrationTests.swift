import Foundation
import JellyfinKit
import OcPlayerCore
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

@MainActor
final class FileLibraryIntegrationTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, FileLibraryCoordinator, AppModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-library-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "file-library-app-test-\(UUID().uuidString)"))
        let coordinator = FileLibraryCoordinator(directory: directory.appendingPathComponent("catalog"))
        let app = AppModel(store: ServerStore(defaults: defaults), fileLibrary: coordinator, preferences: defaults)
        return (directory, defaults, coordinator, app)
    }

    func testPermanentCatalogLoadsWithServerMigrationDisabled() async throws {
        let (directory, _, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(OcpCoreFeature.isEnabled)
        try await library.setup()
        XCTAssertEqual(library.capabilities?.sourceKinds, ["localFolder"])
        XCTAssertFalse(try XCTUnwrap(library.capabilities).aggregation)
        XCTAssertNil(app.server)
        XCTAssertTrue(library.sources.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog/Library.sqlite").path))
    }

    func testSettingChangesRevokeCreationWithoutRemovingCatalog() async throws {
        let (directory, _, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await library.setup()
        app.tmdb.setAPIKey("a-test-key")
        let old = app.fileLibraryCredentialRevision
        app.tmdb.setAPIKey("a-replacement-key")
        XCTAssertNotEqual(old, app.fileLibraryCredentialRevision)
        app.tmdb.setAPIKey(nil)
        do {
            _ = try await library.create(draftID: "draft", verificationID: "invented", credentialRevision: old,
                                         apiBase: app.fileLibraryAPIBase, source: nil, root: directory,
                                         subdirectory: "", sourceName: "Files", name: "Movies", type: .movies)
            XCTFail("Cleared credentials authorized library creation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("TMDB")) }
        XCTAssertTrue(library.sources.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog/Library.sqlite").path))
    }

    func testSwitchingToServerClearsFileProjectionAndPersistsOneSelection() async throws {
        let (directory, defaults, _, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.phase = .ready
        app.activeFileSourceID = "file-source"
        let stub = StubMediaServer()
        await app.activate(server: stub)
        app.initialDataTask?.cancel()
        app.userAvatarTask?.cancel()
        XCTAssertNil(app.activeFileSourceID)
        XCTAssertEqual(app.server?.profile.id, stub.profile.id)
        XCTAssertEqual(defaults.string(forKey: AppModel.activeMediaSourceKey), "server:\(stub.profile.id)")
    }

    func testFileIdentityAndHeadersSurviveRequestAndSourceComparison() throws {
        let (directory, _, _, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlaybackController()
        app.playback = controller
        let identity = FileLibraryPlaybackIdentity(sourceID: "s", itemID: "i", assetID: "a")
        let request = PlaybackRequest(title: "Movie", uri: "/movie.mkv", headers: ["X-Test": "value"], fileLibraryIdentity: identity)
        XCTAssertNil(request.sessionContext)
        XCTAssertEqual(request.fileLibraryIdentity, identity)
        XCTAssertFalse(controller.samePlaybackSource(request, PlaybackRequest(title: "Movie", uri: "/movie.mkv")))
        XCTAssertEqual(request.headers, ["X-Test": "value"])
    }

    func testCompletionRequiresStoppedKnownDurationAndNoFailure() {
        XCTAssertFalse(AppModel.fileLibraryReachedEnd(stopped: false, failed: false, position: 100, duration: 100))
        XCTAssertFalse(AppModel.fileLibraryReachedEnd(stopped: true, failed: true, position: 100, duration: 100))
        XCTAssertFalse(AppModel.fileLibraryReachedEnd(stopped: true, failed: false, position: 20, duration: 100))
        XCTAssertFalse(AppModel.fileLibraryReachedEnd(stopped: true, failed: false, position: 100, duration: 0))
        XCTAssertTrue(AppModel.fileLibraryReachedEnd(stopped: true, failed: false, position: 99.8, duration: 100))
    }

    func testUnavailableSelectedSourceDoesNotRestoreADifferentProfile() async throws {
        let (directory, defaults, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await library.setup()
        for selection in ["file:missing", "server:missing"] {
            defaults.set(selection, forKey: AppModel.activeMediaSourceKey)
            let handled = await app.restoreSelectedMediaSource()
            XCTAssertTrue(handled)
            XCTAssertEqual(app.phase, .onboarding)
            XCTAssertNil(app.server)
            XCTAssertNil(app.activeFileSourceID)
            XCTAssertTrue(app.isMediaSourcesPresented)
            XCTAssertEqual(defaults.string(forKey: AppModel.activeMediaSourceKey), selection)
        }
    }

    #if os(macOS)
    func testOnlineScrapingManualMatchAndOfflineSnapshotsCrossRealCore() async throws {
        let tmdb = try LibraryTMDBFixture()
        defer { tmdb.stop() }
        let (directory, defaults, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("videos")
        for relative in ["Movies/1917 (2019).mkv", "Movies/1917.mkv", "TV/Show (2024)/Season 0/Show S00E01.mkv"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        defaults.set(true, forKey: SettingsKeys.tmdbMirrorEnabled)
        defaults.set(tmdb.apiBase, forKey: SettingsKeys.tmdbMirrorAPIBaseURL)
        app.tmdb.setAPIKey("test-valid")
        let revision = app.fileLibraryCredentialRevision
        let receipt = try await library.validate(key: "test-valid", apiBase: tmdb.apiBase, draftID: "movies")
        let movies = try await library.create(draftID: "movies", verificationID: receipt.verificationId, credentialRevision: revision,
            apiBase: tmdb.apiBase, source: nil, root: root, subdirectory: "Movies", sourceName: "Files", name: "Movies", type: .movies)
        let source = try XCTUnwrap(library.sources.first)
        try await waitForScrape(library, sourceID: source.sourceId, libraryID: movies.library.libraryId, status: "needsMatch")
        let page = try await library.page(.init(sourceId: source.sourceId, libraryId: movies.library.libraryId))
        let unmatched = try XCTUnwrap(page.items.first { $0.year == nil })
        let automatic = try XCTUnwrap(page.items.first { $0.year == 2019 })
        XCTAssertEqual(automatic.matchStatus, "matched")
        XCTAssertNil(unmatched.metadata)
        XCTAssertNotNil(automatic.metadata)
        let results = try await library.candidates(item: unmatched, query: "1917", key: "test-valid", apiBase: tmdb.apiBase, language: "zh-CN")
        XCTAssertEqual(results.candidates.first?.mediaType, "movie")
        try await library.bind(item: unmatched, inputVersion: results.inputVersion, tmdbID: 18)
        try await waitForScrape(library, sourceID: source.sourceId, libraryID: movies.library.libraryId, status: "completed")
        let manualDetail = try await library.detail(sourceID: source.sourceId, itemID: unmatched.itemId)
        XCTAssertEqual(manualDetail.item.title, "人工选择的电影")
        let tvReceipt = try await library.validate(key: "test-valid", apiBase: tmdb.apiBase, draftID: "tv")
        let tv = try await library.create(draftID: "tv", verificationID: tvReceipt.verificationId, credentialRevision: revision,
            apiBase: tmdb.apiBase, source: source, root: root, subdirectory: "TV", sourceName: "Files", name: "TV", type: .tvshows)
        try await waitForScrape(library, sourceID: source.sourceId, libraryID: tv.library.libraryId, status: "completed")
        let shows = try await library.page(.init(sourceId: source.sourceId, libraryId: tv.library.libraryId))
        let show = try XCTUnwrap(shows.items.first)
        let seasons = try await library.page(.init(sourceId: source.sourceId, parentId: show.itemId))
        let season = try XCTUnwrap(seasons.items.first)
        XCTAssertEqual(season.seasonNumber, 0)
        XCTAssertEqual(season.title, "特别篇")
        let episodes = try await library.page(.init(sourceId: source.sourceId, parentId: season.itemId))
        XCTAssertEqual(episodes.totalCount, 1)
        XCTAssertEqual(episodes.items.first?.title, "第一特别篇")
        app.tmdb.setAPIKey(nil)
        let reopened = FileLibraryCoordinator(directory: directory.appendingPathComponent("catalog"))
        try await reopened.setup()
        let retained = try await reopened.detail(sourceID: source.sourceId, itemID: unmatched.itemId)
        XCTAssertEqual(retained.item.title, "人工选择的电影")
        XCTAssertNotNil(retained.item.metadata)
        _ = try await reopened.preparePlayback(item: retained.item, asset: XCTUnwrap(retained.assets.first))
        try await reopened.unbind(item: retained.item)
        let unbound = try await reopened.detail(sourceID: source.sourceId, itemID: unmatched.itemId)
        XCTAssertNil(unbound.item.metadata)
        XCTAssertEqual(unbound.item.title, "1917")
    }

    func testRealValidationCategoryTreeBookmarkRestoreAndPermanentResume() async throws {
        let tmdb = try LibraryTMDBFixture()
        defer { tmdb.stop() }
        let (directory, defaults, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("videos")
        let moviePath = root.appendingPathComponent("Movies/1917 (2019).mkv")
        let episodePath = root.appendingPathComponent("TV/Show/Season 0/Show S00E01.mkv")
        for url in [moviePath, episodePath] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test fixture".utf8).write(to: url)
        }
        defaults.set(true, forKey: SettingsKeys.tmdbMirrorEnabled)
        defaults.set(tmdb.apiBase, forKey: SettingsKeys.tmdbMirrorAPIBaseURL)
        app.tmdb.setAPIKey("test-valid")
        let revision = app.fileLibraryCredentialRevision
        let verification = try await library.validate(key: "test-valid", apiBase: tmdb.apiBase, draftID: "movies")
        let movieLibrary = try await library.create(draftID: "movies", verificationID: verification.verificationId,
            credentialRevision: revision, apiBase: tmdb.apiBase, source: nil, root: root,
            subdirectory: "Movies", sourceName: "Files", name: "Movies", type: .movies)
        try await waitForScan(library, sourceID: movieLibrary.library.sourceId)
        let source = try XCTUnwrap(library.sources.first)
        let tvVerification = try await library.validate(key: "test-valid", apiBase: tmdb.apiBase, draftID: "tv")
        let tvLibrary = try await library.create(draftID: "tv", verificationID: tvVerification.verificationId,
            credentialRevision: revision, apiBase: tmdb.apiBase, source: source, root: root,
            subdirectory: "TV", sourceName: "Files", name: "TV", type: .tvshows)
        try await waitForScan(library, sourceID: source.sourceId)
        XCTAssertEqual(library.sources.count, 1)
        let categories = try await library.libraries(sourceID: source.sourceId)
        XCTAssertEqual(Set(categories.map(\.type)), [.movies, .tvshows])
        let movies = try await library.page(.init(sourceId: source.sourceId, libraryId: movieLibrary.library.libraryId))
        let movie = try XCTUnwrap(movies.items.first)
        XCTAssertEqual(movie.title, "1917")
        let shows = try await library.page(.init(sourceId: source.sourceId, libraryId: tvLibrary.library.libraryId))
        let show = try XCTUnwrap(shows.items.first)
        let seasons = try await library.page(.init(sourceId: source.sourceId, parentId: show.itemId))
        XCTAssertEqual(seasons.items.first?.seasonNumber, 0)
        let season = try XCTUnwrap(seasons.items.first)
        let episodes = try await library.page(.init(sourceId: source.sourceId, parentId: season.itemId))
        XCTAssertEqual(episodes.items.first?.episodeNumber, 1)
        let progress = OcpFileLibrary.Progress(sourceId: source.sourceId, itemId: movie.itemId,
            positionSeconds: 123, durationSeconds: 500, played: false, completed: false, recordedAt: Date().timeIntervalSince1970)
        await library.record(progress).value
        app.tmdb.setAPIKey(nil)
        let detail = try await library.detail(sourceID: source.sourceId, itemID: movie.itemId)
        let playback = try await library.preparePlayback(item: movie, asset: XCTUnwrap(detail.assets.first))
        XCTAssertEqual(playback.progress?.positionSeconds, 123)
        let preparedURL = try XCTUnwrap(URL(string: playback.uri))
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: moviePath.path)
        let preparedAttributes = try FileManager.default.attributesOfItem(atPath: preparedURL.path)
        XCTAssertEqual(originalAttributes[.systemFileNumber] as? NSNumber, preparedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(originalAttributes[.systemNumber] as? NSNumber, preparedAttributes[.systemNumber] as? NSNumber)
        let reopened = FileLibraryCoordinator(directory: directory.appendingPathComponent("catalog"))
        try await reopened.setup()
        XCTAssertNil(reopened.permissionErrors[source.sourceId])
        try reopened.authorize(source: source, root: root)
        let foreignRoot = directory.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try reopened.authorize(source: source, root: foreignRoot))
        XCTAssertNil(reopened.permissionErrors[source.sourceId])
        let resume = try await reopened.resume(sourceID: source.sourceId)
        XCTAssertEqual(resume.first?.itemId, movie.itemId)
        await app.activateFileSource(source.sourceId)
        XCTAssertNil(app.server)
        XCTAssertEqual(app.activeFileSourceID, source.sourceId)
        XCTAssertEqual(defaults.string(forKey: AppModel.activeMediaSourceKey), "file:\(source.sourceId)")

        // Cross the same controller open hook used by PlayerScreen, with a
        // fake decoder so this test checks host wiring without decoding bytes.
        let previousEngine = PlaybackEngineRegistry.storedSelectionID
        let engine = FileLibraryTestEngine()
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.register(FileLibraryTestEngine.descriptor) { engine }
        PlaybackEngineRegistry.select(FileLibraryTestEngine.descriptor.id)
        let controller = PlaybackController()
        app.playback = controller
        defer {
            app.finishReporting()
            controller.stopPlayback()
            PlaybackEngineRegistry.resetForTesting()
            if let previousEngine { PlaybackEngineRegistry.select(previousEngine) }
            else { PlaybackEngineRegistry.clearSelection() }
            PlaybackEngineAssembly.registerAll()
        }
        try await app.playFileLibraryItem(movie, asset: XCTUnwrap(detail.assets.first), fromStart: false)
        let request = try XCTUnwrap(app.presentedPlayer)
        XCTAssertNil(request.sessionContext)
        XCTAssertEqual(request.fileLibraryIdentity?.sourceID, source.sourceId)
        XCTAssertEqual(request.fileLibraryIdentity?.itemID, movie.itemId)
        XCTAssertEqual(request.resumeSeconds, 123)
        controller.openIfNeeded(request)
        engine.continuation.yield(.durationChanged(.seconds(500)))
        engine.continuation.yield(.stateChanged(.playing))
        engine.continuation.yield(.positionChanged(.seconds(200)))
        for _ in 0..<100 {
            if controller.hasLoadedSource && controller.state.position == .seconds(200) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.hasLoadedSource)
        XCTAssertEqual(engine.openedSource?.uri, preparedURL.path)
        XCTAssertEqual(controller.state.position, .seconds(200))
        let finished = app.finishReporting()
        let server = StubMediaServer()
        await app.activate(server: server)
        app.initialDataTask?.cancel()
        app.userAvatarTask?.cancel()
        await finished?.value
        let savedProgress = try await library.detail(sourceID: source.sourceId, itemID: movie.itemId)
        XCTAssertEqual(savedProgress.progress?.positionSeconds, 200)
        XCTAssertFalse(savedProgress.progress?.completed ?? true)
        XCTAssertNil(app.activeFileSourceID)
    }

    private func waitForScan(_ library: FileLibraryCoordinator, sourceID: String) async throws {
        for _ in 0..<100 {
            let jobs = try await library.jobs(sourceID: sourceID)
            if jobs.allSatisfy({ $0.status == "completed" }) { return }
            if let failed = jobs.first(where: { $0.status == "failed" || $0.status == "waitingPermission" }) {
                XCTFail(failed.lastError ?? failed.status); return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Directory scan did not finish")
    }
    private func waitForScrape(_ library: FileLibraryCoordinator, sourceID: String, libraryID: String, status: String) async throws {
        for _ in 0..<200 {
            let runs = try await library.scrapes(sourceID: sourceID)
            if runs.first(where: { $0.libraryId == libraryID })?.status == status { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("TMDB scrape did not reach \(status)")
    }
    #endif
}

#if os(macOS)
private final class FileLibraryTestEngine: PlaybackEngine, @unchecked Sendable {
    static let descriptor = PlaybackEngineDescriptor(id: "file-library-test", displayName: "File Library Test", summary: "Test", supportsKernelDanmaku: false)
    let events: AsyncStream<PlayerEvent>
    let continuation: AsyncStream<PlayerEvent>.Continuation
    private let lock = NSLock()
    private var opened: PlaybackSource?
    var openedSource: PlaybackSource? { lock.withLock { opened } }
    var latestMediaTime: Duration { .zero }
    var latestStats: PlaybackStats { .init() }
    init() { (events, continuation) = AsyncStream.makeStream() }
    @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }
    func open(_ source: PlaybackSource) throws { lock.withLock { opened = source } }
    func play() throws {}
    func pause() throws {}
    func stop() throws {}
    func seek(to position: Duration) throws {}
    func setRate(_ rate: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func tracks() throws -> [TrackInfo] { [] }
    func selectAudioTrack(_ id: Int64) throws {}
    func selectSubtitleTrack(_ id: Int64?) throws {}
    func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
    func setSubtitleScale(_ scale: Double) throws {}
    func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }
}

private final class LibraryTMDBFixture {
    let process = Process()
    let apiBase: String
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = """
        import http.server, json, urllib.parse
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                valid = query.get('api_key') == ['test-valid']
                self.send_response(200 if valid else 401)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                movie = {'id': 17, 'title': '1917', 'release_date': '2019-12-01', 'overview': '电影简介', 'poster_path': '/movie.jpg'}
                show = {'id': 24, 'name': 'Show', 'first_air_date': '2024-01-01', 'overview': '整剧简介', 'poster_path': '/show.jpg'}
                if not valid: payload = {'status_code': 7}
                elif parsed.path.endswith('/search/movie'): payload = {'results': [movie]}
                elif parsed.path.endswith('/search/tv'): payload = {'results': [show]}
                elif parsed.path.endswith('/movie/17'): payload = movie
                elif parsed.path.endswith('/movie/18'): payload = {'id': 18, 'title': '人工选择的电影', 'overview': '人工选择简介'}
                elif parsed.path.endswith('/tv/24'): payload = show
                elif parsed.path.endswith('/tv/24/season/0'): payload = {'season_number': 0, 'name': '特别篇', 'episodes': [{'id': 241, 'episode_number': 1, 'name': '第一特别篇'}, {'id': 242, 'episode_number': 2, 'name': '未入库特别篇'}]}
                else: payload = {'images': {'secure_base_url': 'https://image.tmdb.org/t/p/', 'poster_sizes': ['w500']}, 'change_keys': ['title']}
                self.wfile.write(json.dumps(payload).encode())
            def log_message(self, *args): pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """
        process.arguments = ["-u", "-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var port = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else { throw OcpCoreError(message: "TMDB fixture did not start") }
            if byte == Data([10]) { break }
            port.append(byte)
        }
        apiBase = "http://127.0.0.1:\(String(decoding: port, as: UTF8.self))/3"
    }
    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }
}
#endif
