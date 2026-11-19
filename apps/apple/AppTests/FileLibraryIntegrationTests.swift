import Foundation
import ErikaKit
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
        XCTAssertEqual(library.capabilities?.sourceKinds, ["localFolder", "webdav", "smb"])
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

    func testWebDAVCreationCredentialRecoveryAndErikaRangePlayback() async throws {
        let began = Date()
        func stage(_ label: String) { XCTContext.runActivity(named: "WebDAV \(label): \(Date().timeIntervalSince(began))s") { _ in } }
        let (directory, _, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("fixture.mkv")
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg fixture generator unavailable") }
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        generator.arguments = ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=128x72:rate=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3", "-c:v", "mpeg4", "-c:a", "aac", media.path]
        generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run()
        while generator.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(generator.terminationStatus, 0)
        stage("generated")
        let server = try await Task.detached { try LibraryWebDAVFixture(media: media) }.value
        defer { server.stop() }
        stage("serverStarted")
        try await library.setup()
        stage("coreOpened")
        let revision = FileLibraryCoordinator.credentialRevision(key: "fixture-tmdb", apiBase: server.base + "/3")
        let verification = try await library.validate(key: "fixture-tmdb", apiBase: server.base + "/3", draftID: "webdav")
        let credential = OcpFileLibrary.WebDAVCredential.basic(username: "user", password: "fixture-password")
        stage("tmdb")
        let access = try await library.prepareWebDAV(rootURL: server.base + "/dav/", credential: credential, accessRef: "dav-ref")
        stage("connected")
        let category = try await library.browseWebDAV(accessID: access.accessId, relativePath: "Movies")
        stage("browsed")
        let created = try await library.createWebDAV(draftID: "webdav", verificationID: verification.verificationId,
            credentialRevision: revision, apiBase: server.base + "/3", source: nil, access: access, category: category,
            credential: credential, accessRef: "dav-ref", sourceName: "WebDAV", name: "电影", type: .movies)
        try await waitForScan(library, sourceID: created.library.sourceId)
        stage("scanned")
        let source = try XCTUnwrap(library.sources.first)
        XCTAssertEqual(source.kind, "webdav")
        XCTAssertEqual(library.storedWebDAVCredential(for: source), credential)
        let credentialFile = directory.appendingPathComponent("catalog/LibraryCredentials.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        library.credentialsChanged()
        let reopened = FileLibraryCoordinator(directory: directory.appendingPathComponent("catalog"))
        try await reopened.setup()
        XCTAssertEqual(reopened.storedWebDAVCredential(for: source), credential)
        let page = try await reopened.page(.init(sourceId: source.sourceId))
        let item = try XCTUnwrap(page.items.first)
        let detail = try await reopened.detail(sourceID: source.sourceId, itemID: item.itemId)
        let asset = try XCTUnwrap(detail.assets.first)
        stage("reopened")
        let prepared = try await reopened.preparePlayback(item: item, asset: asset)
        XCTAssertNotNil(prepared.leaseId)
        XCTAssertTrue(prepared.headers.isEmpty)
        stage("prepared")
        let lifetime = try XCTUnwrap(reopened.retainPlayback(prepared))
        let playbackSource = PlaybackSource(uri: prepared.uri, resourceLifetime: lifetime)
        // Actual liberika open and seek against Core's loopback Range bridge.
        let duration = try await Task.detached {
            let presenter = try ErikaPresenter()
            try presenter.open(playbackSource)
            var duration: Double?
            for _ in 0..<100 {
                _ = try? presenter.audioOnlyTick()
                while let event = try presenter.pollEvent() {
                    if case let .durationChanged(value) = event { duration = Double(value.microseconds) / 1_000_000 }
                }
                if duration != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try presenter.seek(to: .seconds(1))
            try presenter.close()
            return duration
        }.value
        stage("decoded")
        XCTAssertEqual(try XCTUnwrap(duration), 3, accuracy: 0.15)
        await app.activateFileSource(source.sourceId)
        stage("activated")
        try await app.playFileLibraryItem(item, asset: asset, fromStart: true)
        stage("requested")
        let request = try XCTUnwrap(app.presentedPlayer)
        XCTAssertTrue(request.uri.hasPrefix("http://127.0.0.1:"))
        XCTAssertNotNil(request.resourceLifetime)
        XCTAssertNil(request.sessionContext)
        stage("end")
        app.dismissPlayer()
    }

    func testSMBCreationCredentialRecoveryAndErikaRangePlayback() async throws {
        let began = Date()
        func stage(_ label: String) { XCTContext.runActivity(named: "SMB \(label): \(Date().timeIntervalSince(began))s") { _ in } }
        let (directory, _, library, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("fixture.mkv")
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg fixture generator unavailable") }
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        generator.arguments = ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=128x72:rate=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3", "-c:v", "mpeg4", "-c:a", "aac", media.path]
        generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run()
        while generator.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(generator.terminationStatus, 0)
        stage("generated")
        let server = try await Task.detached { try LibrarySMBFixture(media: media) }.value
        defer { server.stop() }
        stage("serverStarted")
        try await library.setup()
        stage("coreOpened")
        let revision = FileLibraryCoordinator.credentialRevision(key: "fixture-tmdb", apiBase: server.base + "/3")
        let verification = try await library.validate(key: "fixture-tmdb", apiBase: server.base + "/3", draftID: "smb")
        let credential = OcpFileLibrary.SMBCredential.password(username: "user", password: "fixture-password")
        stage("tmdb")
        let access = try await library.prepareSMB(rootURL: server.root, credential: credential, accessRef: "smb-ref")
        stage("connected")
        let category = try await library.browseSMB(accessID: access.accessId, relativePath: "Movies")
        stage("browsed")
        let created = try await library.createSMB(draftID: "smb", verificationID: verification.verificationId,
            credentialRevision: revision, apiBase: server.base + "/3", source: nil, access: access, category: category,
            credential: credential, accessRef: "smb-ref", sourceName: "SMB", name: "电影", type: .movies)
        try await waitForScan(library, sourceID: created.library.sourceId)
        stage("scanned")
        let source = try XCTUnwrap(library.sources.first)
        XCTAssertEqual(source.kind, "smb")
        XCTAssertEqual(library.storedSMBCredential(for: source), credential)
        let credentialFile = directory.appendingPathComponent("catalog/LibraryCredentials.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        library.credentialsChanged()
        let reopened = FileLibraryCoordinator(directory: directory.appendingPathComponent("catalog"))
        try await reopened.setup()
        XCTAssertEqual(reopened.storedSMBCredential(for: source), credential)
        let page = try await reopened.page(.init(sourceId: source.sourceId))
        let item = try XCTUnwrap(page.items.first)
        let detail = try await reopened.detail(sourceID: source.sourceId, itemID: item.itemId)
        let asset = try XCTUnwrap(detail.assets.first)
        stage("reopened")
        let prepared = try await reopened.preparePlayback(item: item, asset: asset)
        XCTAssertNotNil(prepared.leaseId)
        XCTAssertTrue(prepared.headers.isEmpty)
        stage("prepared")
        let lifetime = try XCTUnwrap(reopened.retainPlayback(prepared))
        let playbackSource = PlaybackSource(uri: prepared.uri, resourceLifetime: lifetime)
        // Actual liberika open and seek against Core's loopback Range bridge.
        let duration = try await Task.detached {
            let presenter = try ErikaPresenter()
            try presenter.open(playbackSource)
            var duration: Double?
            for _ in 0..<100 {
                _ = try? presenter.audioOnlyTick()
                while let event = try presenter.pollEvent() {
                    if case let .durationChanged(value) = event { duration = Double(value.microseconds) / 1_000_000 }
                }
                if duration != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try presenter.seek(to: .seconds(1))
            try presenter.close()
            return duration
        }.value
        stage("decoded")
        XCTAssertEqual(try XCTUnwrap(duration), 3, accuracy: 0.15)
        await app.activateFileSource(source.sourceId)
        stage("activated")
        try await app.playFileLibraryItem(item, asset: asset, fromStart: true)
        stage("requested")
        let request = try XCTUnwrap(app.presentedPlayer)
        XCTAssertTrue(request.uri.hasPrefix("http://127.0.0.1:"))
        XCTAssertNotNil(request.resourceLifetime)
        XCTAssertNil(request.sessionContext)
        stage("end")
        app.dismissPlayer()
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

private final class LibrarySMBFixture: @unchecked Sendable {
    private let process = Process()
    let base: String
    let root: String
    let directory: String
    init(media: URL) throws {
        let python = ProcessInfo.processInfo.environment["OCP_SMB_TEST_PYTHON"] ?? "/tmp/ocp-smb-test-venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("Set OCP_SMB_TEST_PYTHON to Python with impacket==0.13.0") }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", "-c", Self.script, media.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; data.append(byte)
        }
        struct Configuration: Decodable { let base: String; let root: String; let directory: String }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        base = config.base; root = config.root; directory = config.directory
    }
    // BEGIN GENERATED SMB FIXTURE
    // Generated from core/tests/fixtures/file_library_smb.py.
    // Run core/Scripts/sync-smb-test-fixture.py after editing the shared fixture.
    private static let script = #"""
    #!/usr/bin/env python3
    """Loopback SMB2 protocol fixture. Requires impacket==0.13.0, not a real NAS.

    Optional first argument is playable media. Sparse file content above 4 GiB is
    used to verify 64-bit readAt without allocating a giant fixture.
    """
    import json
    import logging
    import os
    import shutil
    import tempfile
    import threading
    import sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from impacket import smbserver
    from impacket.ntlm import compute_lmhash, compute_nthash
    from impacket import smb3structs as smb2
    from impacket.nt_errors import STATUS_ACCESS_DENIED

    logging.disable(logging.CRITICAL)
    directory = tempfile.mkdtemp(prefix='ocp-smb-fixture-')
    os.makedirs(os.path.join(directory, 'Movies'))
    os.makedirs(os.path.join(directory, 'Denied'))
    os.makedirs(os.path.join(directory, 'Shows', 'Show', 'Season 0'))
    os.makedirs(os.path.join(directory, 'Shows', 'Show', 'Season 1'))
    movie = os.path.join(directory, 'Movies', '中文 100% # & (2020).mkv')
    size = 5 * 1024**3 + 1025
    if len(sys.argv) > 1:
        shutil.copyfile(sys.argv[1], movie)
        size = os.path.getsize(movie)
    else:
        with open(movie, 'wb') as f:
            f.truncate(size)
            for position in (0, 4 * 1024**3 - 16, size - 32):
                f.seek(position)
                f.write(bytes(i % 251 for i in range(position, position + 32)))
    for season in (0, 1):
        with open(os.path.join(directory, 'Shows', 'Show', f'Season {season}', f'Show S0{season}E01.mkv'), 'wb') as f:
            f.write(bytes(range(100)))
    # A reparse-point-like symlink must never escape a scan root (the fixture does
    # not expose Windows reparse metadata; provider path checks are tested separately).
    server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
    server.setSMB2Support(True)
    server.addShare('Media', directory, readOnly='yes')
    server.addCredential('user', 0, compute_lmhash('fixture-password'), compute_nthash('fixture-password'))
    def guarded_create(conn_id, smb_server, packet):
        request = smb2.SMB2Create(packet['Data'])
        if request['Buffer'].decode('utf-16le').replace('\\', '/').strip('/') == 'Denied':
            return [smb2.SMB2Error()], None, STATUS_ACCESS_DENIED
        return original_create(conn_id, smb_server, packet)
    original_create = server.getServer().hookSmb2Command(smb2.SMB2_CREATE, guarded_create)
    threading.Thread(target=server.start, daemon=True).start()
    guest = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
    guest.setSMB2Support(True)
    guest.addShare('Media', directory, readOnly='yes')
    threading.Thread(target=guest.start, daemon=True).start()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if self.path.startswith('/3/configuration'):
                data = {'images': {'secure_base_url': 'https://image.tmdb.org/t/p/', 'poster_sizes': ['w500']}, 'change_keys': ['title']}
            elif self.path.startswith('/3/search/movie'):
                data = {'results': [{'id': 11, 'title': '中文 100% # &', 'release_date': '2020-01-01'}]}
            elif self.path.startswith('/3/movie/11'):
                data = {'id': 11, 'title': 'SMB 刮削电影', 'release_date': '2020-01-01', 'overview': '永久 SMB 元数据'}
            else: data = {'results': []}
            body = json.dumps(data).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    http.daemon_threads = True
    print(json.dumps({'root': f'smb://127.0.0.1:{server.getServer().server_address[1]}/Media/',
                      'guestRoot': f'smb://127.0.0.1:{guest.getServer().server_address[1]}/Media/',
                      'base': f'http://127.0.0.1:{http.server_port}', 'directory': directory, 'size': size}), flush=True)
    http.serve_forever()
    """#
    // END GENERATED SMB FIXTURE
    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: directory)
    }
    deinit { stop() }
}

private final class LibraryWebDAVFixture: @unchecked Sendable {
    private let process = Process()
    let base: String
    init(media: URL) throws {
        let python = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", "-c", Self.script, media.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; data.append(byte)
        }
        struct Configuration: Decodable { let base: String }
        base = try JSONDecoder().decode(Configuration.self, from: data).base
    }
    // BEGIN GENERATED WEBDAV FIXTURE
    // Generated from core/tests/fixtures/file_library_webdav.py.
    // Run core/Scripts/sync-webdav-test-fixture.py after editing the shared fixture.
    private static let script = #"""
    #!/usr/bin/env python3
    """Loopback DAV contract fixture; generated bytes are not playable media."""
    import base64
    import json
    import threading
    import sys
    import os
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import quote, unquote, urlsplit, parse_qs
    from xml.sax.saxutils import escape

    AUTH = 'Basic ' + base64.b64encode('user:fixture-password'.encode()).decode()
    SIZE = 8 * 1024 * 1024 + 1025
    FILES = {'/dav/Movies/中文 100% # & (2020).mkv': SIZE,
             '/dav/Shows/Show/Season 0/Show S00E01.mkv': 256,
             '/dav/Shows/Show/Season 1/Show S01E01.mkv': 512}
    MEDIA = sys.argv[1] if len(sys.argv) > 1 else None
    if MEDIA: FILES['/dav/Movies/中文 100% # & (2020).mkv'] = os.path.getsize(MEDIA)
    DIRECTORIES = {'/dav/', '/dav/Movies/', '/dav/Shows/', '/dav/Shows/Show/',
                   '/dav/Shows/Show/Season 0/', '/dav/Shows/Show/Season 1/'}
    state = {'failDirectory': '', 'rangeMode': '', 'unauthorized': False, 'slowDirectory': ''}
    records = []
    lock = threading.Lock()


    def response(href, directory, size=0):
        props = '<d:resourcetype>' + ('<d:collection/>' if directory else '') + '</d:resourcetype>'
        if not directory:
            props += f'<d:getcontentlength>{size}</d:getcontentlength>'
        props += '<d:getlastmodified>Thu, 19 Nov 2026 12:00:00 GMT</d:getlastmodified><d:getetag>"fixture-v1"</d:getetag>'
        return (f'<d:response><d:href>{escape(quote(href, safe="/"))}</d:href>'
                '<d:propstat><d:prop><d:displayname/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>'
                f'<d:propstat><d:prop>{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')


    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def send(self, status, body=b'', headers=None):
            if isinstance(body, str): body = body.encode()
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            for key, value in (headers or {}).items(): self.send_header(key, value)
            self.end_headers()
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
        def record(self):
            with lock:
                records.append({'method': self.command, 'path': self.path,
                                'authorization': self.headers.get('Authorization'), 'range': self.headers.get('Range'),
                                'depth': self.headers.get('Depth')})
        def authorized(self):
            return not state['unauthorized'] and self.headers.get('Authorization') in (AUTH, 'Bearer fixture-token')
        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length)
            if self.path == '/__control':
                state.update(json.loads(body)); self.send(200, '{}')
            else: self.send(404)
        def do_PROPFIND(self):
            self.record()
            self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if not self.authorized(): return self.send(401)
            path = unquote(urlsplit(self.path).path)
            if state['slowDirectory'] == path:
                import time
                time.sleep(0.4)
            if path == state['failDirectory']: return self.send(503)
            if path not in DIRECTORIES or self.headers.get('Depth') != '1': return self.send(404)
            body = response(path, True)
            for directory in sorted(DIRECTORIES):
                if directory != path and directory.startswith(path) and '/' not in directory[len(path):].rstrip('/'):
                    body += response(directory, True)
            for filename, size in sorted(FILES.items()):
                if filename.startswith(path) and '/' not in filename[len(path):]: body += response(filename, False, size)
            self.send(207, '<d:multistatus xmlns:d="DAV:">' + body + '</d:multistatus>', {'Content-Type': 'application/xml'})
        def do_GET(self):
            if self.path == '/__requests': return self.send(200, json.dumps(records))
            self.record()
            if self.path.startswith('/3/configuration'):
                return self.send(200, json.dumps({'images': {'secure_base_url': 'https://image.tmdb.org/t/p/', 'poster_sizes': ['w500']}, 'change_keys': ['title']}))
            if self.path.startswith('/3/search/movie'):
                query = parse_qs(urlsplit(self.path).query).get('query', [''])[0]
                return self.send(200, json.dumps({'results': [{'id': 11, 'title': query, 'release_date': '2020-01-01'}]}))
            if self.path.startswith('/3/movie/11'):
                return self.send(200, json.dumps({'id': 11, 'title': '刮削后的中文电影', 'release_date': '2020-01-01', 'overview': '永久 WebDAV 元数据'}))
            if self.path.startswith('/3/search/'):
                return self.send(200, '{"results":[]}')
            if not self.authorized(): return self.send(401)
            path = unquote(urlsplit(self.path).path)
            if path == '/dav/Movies/alias.mkv': path = '/dav/Movies/中文 100% # & (2020).mkv'
            if path not in FILES: return self.send(404)
            mode = state['rangeMode']
            if mode == 'foreign': return self.send(302, headers={'Location': state.get('redirectURL', 'http://127.0.0.1:9/stolen')})
            if mode == 'same' and unquote(urlsplit(self.path).path) != '/dav/Movies/alias.mkv':
                return self.send(307, headers={'Location': '/dav/Movies/alias.mkv'})
            size = FILES[path]
            if mode == '200': return self.send(200, b'x')
            raw = self.headers.get('Range', 'bytes=0-0').removeprefix('bytes=')
            start, end = map(int, raw.split('-'))
            end = min(end, size-1)
            if start > end: return self.send(416)
            reported = start+1 if mode == 'wrong' else start
            if MEDIA and path == '/dav/Movies/中文 100% # & (2020).mkv':
                with open(MEDIA, 'rb') as video:
                    video.seek(start)
                    body = video.read(end-start+1)
            else: body = bytes(i % 251 for i in range(start, end+1))
            self.send(206, body, {'Content-Range': f'bytes {reported}-{end}/{size}', 'Content-Type': 'video/x-matroska'})


    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    print(json.dumps({'base': 'http://127.0.0.1:' + str(server.server_port), 'size': SIZE}), flush=True)
    server.serve_forever()
    """#
    // END GENERATED WEBDAV FIXTURE

    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }
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
