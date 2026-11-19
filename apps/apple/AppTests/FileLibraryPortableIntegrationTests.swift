import ErikaKit
import Foundation
import Network
import OcPlayerCore
import PlaybackKit
@testable import OcPlayer
import XCTest

/// Runs in both the macOS dylib host and the ordinary statically linked iOS
/// host. All services run in-process; no Python, ffmpeg or desktop paths.
@MainActor
final class FileLibraryPortableIntegrationTests: XCTestCase {
    private func fixture() throws -> (URL, FileLibraryCoordinator, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "file-library-three-seconds", withExtension: "mp4")))
        return (root, FileLibraryCoordinator(directory: root.appendingPathComponent("catalog")), media)
    }

    func testMoviesSpecialsScrapingAndOfflineProgress() async throws {
        let (root, library, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = try PortableLibraryHTTPFixture(media: media)
        defer { http.stop() }
        let base = try await http.start()
        let videos = root.appendingPathComponent("videos")
        for path in ["Movies/1917 (2019).mp4", "TV/Show (2024)/Season 0/Show S00E01.mp4"] {
            let file = videos.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try media.write(to: file)
        }
        try await library.setup()
        XCTAssertFalse(OcpCoreFeature.isEnabled)
        let revision = FileLibraryCoordinator.credentialRevision(key: "test-valid", apiBase: base + "/3")
        let verified = try await library.validate(key: "test-valid", apiBase: base + "/3", draftID: "movie")
        let movies = try await library.create(draftID: "movie", verificationID: verified.verificationId,
            credentialRevision: revision, apiBase: base + "/3", source: nil, root: videos, subdirectory: "Movies",
            sourceName: "Files", name: "电影", type: .movies)
        let source = try XCTUnwrap(library.sources.first)
        let tvVerified = try await library.validate(key: "test-valid", apiBase: base + "/3", draftID: "tv")
        let tv = try await library.create(draftID: "tv", verificationID: tvVerified.verificationId,
            credentialRevision: revision, apiBase: base + "/3", source: source, root: videos, subdirectory: "TV",
            sourceName: "Files", name: "电视剧", type: .tvshows)
        try await waitForScrape(library, sourceID: source.sourceId, libraryID: movies.library.libraryId)
        try await waitForScrape(library, sourceID: source.sourceId, libraryID: tv.library.libraryId)
        let moviePage = try await library.page(.init(sourceId: source.sourceId, libraryId: movies.library.libraryId))
        let movie = try XCTUnwrap(moviePage.items.first)
        XCTAssertEqual(movie.matchStatus, "matched")
        XCTAssertEqual(movie.title, "1917")
        let showPage = try await library.page(.init(sourceId: source.sourceId, libraryId: tv.library.libraryId))
        let show = try XCTUnwrap(showPage.items.first)
        let seasonPage = try await library.page(.init(sourceId: source.sourceId, parentId: show.itemId))
        let season = try XCTUnwrap(seasonPage.items.first)
        XCTAssertEqual(season.seasonNumber, 0)
        let episodePage = try await library.page(.init(sourceId: source.sourceId, parentId: season.itemId))
        XCTAssertEqual(episodePage.totalCount, 1, "TMDB episodes without a local video must stay out of the catalog")
        XCTAssertEqual(episodePage.items.first?.title, "第一特别篇")
        let detail = try await library.detail(sourceID: source.sourceId, itemID: movie.itemId)
        let asset = try XCTUnwrap(detail.assets.first)
        await library.record(.init(sourceId: source.sourceId, itemId: movie.itemId,
            positionSeconds: 1, durationSeconds: 3, played: false, completed: false, recordedAt: Date().timeIntervalSince1970)).value
        library.credentialsChanged()
        http.stop()
        let reopened = FileLibraryCoordinator(directory: root.appendingPathComponent("catalog"))
        try await reopened.setup()
        let retained = try await reopened.detail(sourceID: source.sourceId, itemID: movie.itemId)
        XCTAssertEqual(retained.item.title, "1917")
        XCTAssertNotNil(retained.item.metadata)
        XCTAssertEqual(retained.progress?.positionSeconds, 1)
        let prepared = try await reopened.preparePlayback(item: retained.item, asset: asset)
        XCTAssertFalse(prepared.uri.isEmpty)
        XCTAssertNil(prepared.leaseId)
        do {
            _ = try await reopened.create(draftID: "offline", verificationID: verified.verificationId,
                credentialRevision: revision, apiBase: base + "/3", source: nil, root: root,
                subdirectory: "", sourceName: "Blocked", name: "Blocked", type: .movies)
            XCTFail("Opening a saved catalog must not restore permission to create with an old TMDB receipt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("TMDB")) }
    }

    func testWebDAVCredentialRecoveryRangeAndNativePlayback() async throws {
        let (root, library, media) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = try PortableLibraryHTTPFixture(media: media)
        defer { http.stop() }
        let base = try await http.start()
        let revision = FileLibraryCoordinator.credentialRevision(key: "test-valid", apiBase: base + "/3")
        let verified = try await library.validate(key: "test-valid", apiBase: base + "/3", draftID: "dav")
        let credential = OcpFileLibrary.WebDAVCredential.basic(username: "user", password: "test-password")
        let access = try await library.prepareWebDAV(rootURL: base + "/dav/", credential: credential, accessRef: "dav")
        let category = try await library.browseWebDAV(accessID: access.accessId, relativePath: "Movies")
        let created = try await library.createWebDAV(draftID: "dav", verificationID: verified.verificationId,
            credentialRevision: revision, apiBase: base + "/3", source: nil, access: access, category: category,
            credential: credential, accessRef: "dav", sourceName: "DAV", name: "电影", type: .movies)
        try await waitForScrape(library, sourceID: created.library.sourceId, libraryID: created.library.libraryId)
        library.credentialsChanged()
        let reopened = FileLibraryCoordinator(directory: root.appendingPathComponent("catalog"))
        try await reopened.setup()
        let source = try XCTUnwrap(reopened.sources.first)
        XCTAssertEqual(reopened.storedWebDAVCredential(for: source), credential)
        let page = try await reopened.page(.init(sourceId: source.sourceId))
        let item = try XCTUnwrap(page.items.first)
        let detail = try await reopened.detail(sourceID: source.sourceId, itemID: item.itemId)
        let prepared = try await reopened.preparePlayback(item: item, asset: XCTUnwrap(detail.assets.first))
        XCTAssertTrue(prepared.uri.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(prepared.headers.isEmpty)
        let lifetime = try XCTUnwrap(reopened.retainPlayback(prepared))
        var request = URLRequest(url: try XCTUnwrap(URL(string: prepared.uri)))
        request.setValue("bytes=2-9", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes, media.subdata(in: 2..<10))
        let duration = try await Task.detached {
            let presenter = try ErikaPresenter()
            try presenter.open(PlaybackSource(uri: prepared.uri, resourceLifetime: lifetime))
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
        XCTAssertEqual(try XCTUnwrap(duration), 3, accuracy: 0.15)
    }

    private func waitForScrape(_ library: FileLibraryCoordinator, sourceID: String, libraryID: String) async throws {
        for _ in 0..<200 {
            if try await library.scrapes(sourceID: sourceID).first(where: { $0.libraryId == libraryID })?.status == "completed" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw OcpCoreError(message: "Portable fixture did not finish scanning and scraping")
    }
}

/// A simulator cannot launch the Python SMB service. The dedicated iOS test
/// script starts the existing protocol fixture on the host and forwards only
/// its loopback addresses. Missing fixture coverage is reported as a skip.
#if os(iOS)
@MainActor
final class FileLibrarySMBHostFixtureTests: XCTestCase {
    func testSMBScanCredentialRecoveryAndNativePlayback() async throws {
        guard let raw = ProcessInfo.processInfo.environment["OCP_IOS_SMB_FIXTURE"] else {
            throw XCTSkip("Run core/Scripts/test-ios-file-library.py to supply the host SMB fixture")
        }
        let config = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        let rootURL = try XCTUnwrap(config["root"])
        let base = try XCTUnwrap(config["base"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-smb-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = FileLibraryCoordinator(directory: directory)
        let revision = FileLibraryCoordinator.credentialRevision(key: "fixture-tmdb", apiBase: base + "/3")
        let verified = try await library.validate(key: "fixture-tmdb", apiBase: base + "/3", draftID: "smb")
        let credential = OcpFileLibrary.SMBCredential.password(username: "user", password: "fixture-password", domain: "WORKGROUP")
        let access = try await library.prepareSMB(rootURL: rootURL, credential: credential, accessRef: "smb")
        let category = try await library.browseSMB(accessID: access.accessId, relativePath: "Movies")
        let created = try await library.createSMB(draftID: "smb", verificationID: verified.verificationId,
            credentialRevision: revision, apiBase: base + "/3", source: nil, access: access, category: category,
            credential: credential, accessRef: "smb", sourceName: "SMB", name: "电影", type: .movies)
        var completed = false
        for _ in 0..<200 {
            if try await library.scrapes(sourceID: created.library.sourceId).first?.status == "completed" { completed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(completed)
        library.credentialsChanged()
        let reopened = FileLibraryCoordinator(directory: directory)
        try await reopened.setup()
        let source = try XCTUnwrap(reopened.sources.first)
        XCTAssertEqual(source.kind, "smb")
        XCTAssertEqual(reopened.storedSMBCredential(for: source), credential)
        let page = try await reopened.page(.init(sourceId: source.sourceId))
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.title, "SMB 刮削电影")
        let detail = try await reopened.detail(sourceID: source.sourceId, itemID: item.itemId)
        let prepared = try await reopened.preparePlayback(item: item, asset: XCTUnwrap(detail.assets.first))
        let lifetime = try XCTUnwrap(reopened.retainPlayback(prepared))
        let duration = try await Task.detached {
            let presenter = try ErikaPresenter()
            try presenter.open(PlaybackSource(uri: prepared.uri, resourceLifetime: lifetime))
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
        XCTAssertEqual(try XCTUnwrap(duration), 3, accuracy: 0.15)
        XCTAssertTrue(prepared.headers.isEmpty)
    }
}
#endif

private final class PortableLibraryHTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "portable-library-http")
    private let listener: NWListener
    private let media: Data
    // Listener and connection callbacks are confined to queue.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waitingForStart = true
    init(media: Data) throws {
        self.media = media
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                guard waitingForStart else { return }
                switch state {
                case .ready:
                    waitingForStart = false
                    continuation.resume(returning: "http://127.0.0.1:\(listener.port!.rawValue)")
                case let .failed(error): waitingForStart = false; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { self?.connections[id] = nil }
                }
                connection.start(queue: self.queue)
                self.receive(connection, bytes: Data())
                self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                if waitingForStart {
                    waitingForStart = false
                    listener.cancel()
                    continuation.resume(throwing: OcpCoreError(message: "HTTP fixture startup timed out"))
                }
            }
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            var bytes = bytes
            if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 262144 else { connection.cancel(); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if bytes.count >= end.upperBound + length {
                    respond(connection, line: lines[0], headers: headers)
                    return
                }
            }
            if complete { connection.cancel() } else { receive(connection, bytes: bytes) }
        }
    }
    private func respond(_ connection: NWConnection, line: String, headers: [String: String]) {
        let words = line.split(separator: " ")
        guard words.count >= 2, let url = URLComponents(string: "http://fixture" + words[1]) else { connection.cancel(); return }
        let path = url.path
        if path.hasPrefix("/3/") {
            guard url.queryItems?.contains(where: { $0.name == "api_key" && $0.value == "test-valid" }) == true else {
                send(connection, status: 401, body: Data("{}".utf8)); return
            }
            let movie: [String: Any] = ["id": 17, "title": "1917", "release_date": "2019-12-01", "overview": "电影简介"]
            let show: [String: Any] = ["id": 24, "name": "Show", "first_air_date": "2024-01-01", "overview": "整剧简介"]
            let payload: [String: Any]
            switch path {
            case "/3/search/movie": payload = ["results": [movie]]
            case "/3/search/tv": payload = ["results": [show]]
            case "/3/movie/17": payload = movie
            case "/3/tv/24": payload = show
            case "/3/tv/24/season/0": payload = ["season_number": 0, "name": "特别篇", "episodes": [
                ["id": 241, "episode_number": 1, "name": "第一特别篇"], ["id": 242, "episode_number": 2, "name": "没有文件"]]]
            default: payload = ["images": ["secure_base_url": "https://image.tmdb.org/t/p/", "poster_sizes": ["w500"]], "change_keys": ["title"]]
            }
            send(connection, status: 200, body: try! JSONSerialization.data(withJSONObject: payload)); return
        }
        let authorization = "Basic " + Data("user:test-password".utf8).base64EncodedString()
        guard headers["authorization"] == authorization else { send(connection, status: 401); return }
        if words[0] == "PROPFIND", headers["depth"] == "1", ["/dav/", "/dav/Movies/"].contains(path) {
            func entry(_ path: String, directory: Bool) -> String {
                let type = directory ? "<d:collection/>" : ""
                let size = directory ? "" : "<d:getcontentlength>\(media.count)</d:getcontentlength>"
                let href = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(type)</d:resourcetype>\(size)<d:getetag>fixture-v1</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }
            let child = path == "/dav/" ? entry("/dav/Movies/", directory: true) : entry("/dav/Movies/1917 (2019).mp4", directory: false)
            send(connection, status: 207, body: Data(("<d:multistatus xmlns:d=\"DAV:\">" + entry(path, directory: true) + child + "</d:multistatus>").utf8))
        } else if path == "/dav/Movies/1917 (2019).mp4", words[0] == "GET" {
            let range = headers["range", default: "bytes=0-\(media.count - 1)"].replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            guard range.count == 2, let start = Int(range[0]), start >= 0, start < media.count else { send(connection, status: 416); return }
            let end = min(Int(range[1]) ?? media.count - 1, media.count - 1)
            guard end >= start else { send(connection, status: 416); return }
            send(connection, status: 206, body: media.subdata(in: start..<(end + 1)), extra: "Content-Range: bytes \(start)-\(end)/\(media.count)\r\nContent-Type: video/mp4\r\n")
        } else { send(connection, status: 404) }
    }
    private func send(_ connection: NWConnection, status: Int, body: Data = Data(), extra: String = "") {
        var response = Data("HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
