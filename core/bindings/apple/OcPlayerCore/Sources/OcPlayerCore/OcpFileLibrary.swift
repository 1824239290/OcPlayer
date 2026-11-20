import Foundation

/// File-library commands always use the new Core capability, independently of
/// the migration switch used by existing media-server features.
public final class OcpFileLibrary: @unchecked Sendable {
    public enum LibraryType: String, Codable, Sendable, CaseIterable { case movies, tvshows }
    public enum ItemKind: String, Codable, Sendable { case movie, series, season, episode, unidentified }

    public struct Capabilities: Decodable, Sendable {
        public let schemaVersion: Int
        public let sourceKinds: [String]
        public let libraryTypes: [LibraryType]
        public let aggregation: Bool
        public let backgroundScan: Bool
        public let tmdbAccessValidation: Bool
        public let tmdbScraping: Bool
        public let remoteProviders: Bool
    }
    public struct Source: Decodable, Sendable, Identifiable {
        public let sourceId: String
        public let kind: String
        public let displayName: String
        public let accessRef: String?
        public let rootPath: String
        public let createdAt: Double
        public var id: String { sourceId }
    }
    public struct LibraryRoot: Decodable, Sendable, Identifiable, Equatable {
        public let rootId: String
        public let rootPath: String
        public let accessRef: String?
        public var id: String { rootId }
    }
    public struct Library: Decodable, Sendable, Identifiable {
        public let libraryId: String
        public let sourceId: String
        public let name: String
        public let rootPath: String
        public let type: LibraryType
        public let revision: Int64
        public let createdAt: Double
        public let roots: [LibraryRoot]?
        public var id: String { libraryId }
        public var allRoots: [LibraryRoot] {
            if let roots, !roots.isEmpty { return roots }
            return [LibraryRoot(rootId: libraryId, rootPath: rootPath, accessRef: nil)]
        }
    }
    public struct Item: Decodable, Sendable, Identifiable {
        public let sourceId: String
        public let libraryId: String
        public let itemId: String
        public let kind: ItemKind
        public let title: String
        public let year: Int?
        public let parentId: String?
        public let seriesId: String?
        public let seasonNumber: Int?
        public let episodeNumber: Int?
        public let firstSeenAt: Double
        public let metadata: JSONValue?
        public let matchStatus: String
        public let playable: Bool
        public let seriesTitle: String?
        public let seriesBackdropPath: String?
        public let seriesPosterPath: String?
        public let childCount: Int?
        public let progress: Progress?
        public var id: String { "\(sourceId):\(itemId)" }
    }
    public struct Asset: Decodable, Sendable, Identifiable {
        public let sourceId: String
        public let assetId: String
        public let relativePath: String
        public let size: Int64
        public let available: Bool
        public var id: String { "\(sourceId):\(assetId)" }
    }
    public struct Job: Decodable, Sendable, Identifiable {
        public let jobId: String
        public let sourceId: String
        public let libraryId: String
        public let generation: Int64
        public let status: String
        public let filesFound: Int64
        public let directoriesDone: Int64
        public let errorCount: Int64
        public let lastError: String?
        public var id: String { jobId }
    }
    public struct ScrapeRun: Decodable, Sendable, Identifiable {
        public let runId: String
        public let sourceId: String
        public let libraryId: String
        public let status: String
        public let language: String
        public let refresh: Bool
        public let total: Int64
        public let completed: Int64
        public let unmatched: Int64
        public let failed: Int64
        public let lastError: String?
        public let nextRetryAt: Double?
        public var id: String { runId }
    }
    public struct MatchCandidate: Decodable, Sendable, Identifiable {
        public let id: Int64
        public let mediaType: String
        public let title: String?
        public let originalTitle: String?
        public let year: Int?
        public let overview: String?
        public let posterPath: String?
    }
    public struct MatchCandidates: Decodable, Sendable {
        public let inputVersion: String
        public let candidates: [MatchCandidate]
    }
    public struct Progress: Codable, Sendable {
        public var sourceId: String
        public var itemId: String
        public var positionSeconds: Double
        public var durationSeconds: Double?
        public var played: Bool
        public var completed: Bool
        public var recordedAt: Double
        public init(sourceId: String, itemId: String, positionSeconds: Double, durationSeconds: Double?, played: Bool, completed: Bool, recordedAt: Double) {
            self.sourceId = sourceId; self.itemId = itemId; self.positionSeconds = positionSeconds
            self.durationSeconds = durationSeconds; self.played = played; self.completed = completed; self.recordedAt = recordedAt
        }
    }
    public struct Validation: Decodable, Sendable {
        public let status: String
        public let verificationId: String
        public let expiresInSeconds: Int
    }
    public struct Access: Decodable, Sendable {
        public let accessId: String
        public let rootPath: String
    }
    public struct Creation: Decodable, Sendable { public let library: Library; public let job: Job }
    public struct RootAddition: Decodable, Sendable { public let library: Library; public let root: LibraryRoot; public let job: Job }
    public struct Page: Decodable, Sendable { public let items: [Item]; public let totalCount: Int64; public let startIndex: Int64 }
    public struct Detail: Decodable, Sendable { public let item: Item; public let assets: [Asset]; public let progress: Progress? }
    public struct Playback: Decodable, Sendable {
        public let sourceId: String; public let itemId: String; public let assetId: String
        public let uri: String; public let headers: [String: String]; public let progress: Progress?; public let leaseId: String?
    }
    public struct Query: Encodable, Sendable {
        public var sourceId: String
        public var libraryId: String?
        public var type: LibraryType?
        public var parentId: String?
        public var search: String
        public var startIndex: Int64
        public var limit: Int
        public var sortBy: String?
        public var sortAscending: Bool?
        public var watchState: String?
        public init(sourceId: String, libraryId: String? = nil, type: LibraryType? = nil, parentId: String? = nil, search: String = "", startIndex: Int64 = 0, limit: Int = 50, sortBy: String? = nil, sortAscending: Bool? = nil, watchState: String? = nil) {
            self.sourceId = sourceId; self.libraryId = libraryId; self.type = type; self.parentId = parentId
            self.search = search; self.startIndex = startIndex; self.limit = limit
            self.sortBy = sortBy; self.sortAscending = sortAscending; self.watchState = watchState
        }
    }
    public struct Create: Encodable, Sendable {
        public let draftId: String
        public let verificationId: String
        public let credentialRevision: String
        public let apiBase: String
        public let accessId: String
        public let kind: String
        public let sourceId: String?
        public let sourceName: String
        public let rootPath: String
        public let name: String
        public let type: LibraryType
        public init(draftId: String, verificationId: String, credentialRevision: String, apiBase: String, accessId: String, kind: String = "localFolder", sourceId: String? = nil, sourceName: String, rootPath: String, name: String, type: LibraryType) {
            self.draftId = draftId; self.verificationId = verificationId; self.credentialRevision = credentialRevision
            self.apiBase = apiBase; self.accessId = accessId; self.kind = kind; self.sourceId = sourceId; self.sourceName = sourceName
            self.rootPath = rootPath; self.name = name; self.type = type
        }
    }

    public let client: OcpCoreClient
    public init(client: OcpCoreClient) { self.client = client }

    public func capabilities() async throws -> Capabilities { try await invoke("library.capabilities", [:] as [String: String]) }
    public func open(directory: URL) async throws {
        struct Result: Decodable { let path: String }
        let _: Result = try await invoke("library.open", ["directory": directory.path])
    }
    public func validate(apiKey: String, apiBase: String, credentialRevision: String, draftId: String, language: String = "zh-CN") async throws -> Validation {
        try await invoke("tmdb.access.validate", ["apiKey": apiKey, "apiBase": apiBase, "credentialRevision": credentialRevision, "draftId": draftId, "language": language])
    }
    public func invalidateCredentials() async throws {
        struct Result: Decodable { let invalidated: Bool }
        let _: Result = try await invoke("tmdb.access.invalidate", [:] as [String: String])
    }
    /// The host must hold its security-scoped lease throughout scanning and playback.
    public func prepareAccess(root: URL, accessRef: String? = nil) async throws -> Access {
        var args = ["rootPath": root.path]; if let accessRef { args["accessRef"] = accessRef }
        return try await invoke("library.access.prepare", args)
    }
    public struct WebDAVCredential: Codable, Sendable, Equatable {
        public let type: String
        public let username: String?
        public let password: String?
        public let token: String?
        public static var none: Self { .init(type: "none", username: nil, password: nil, token: nil) }
        public static func basic(username: String, password: String) -> Self { .init(type: "basic", username: username, password: password, token: nil) }
        public static func bearer(token: String) -> Self { .init(type: "bearer", username: nil, password: nil, token: token) }
    }
    public struct RemoteEntry: Decodable, Sendable, Identifiable {
        public let relativePath: String
        public let isDirectory: Bool
        public let size: Int64
        public let modifiedAt: Double
        public let etag: String?
        public var id: String { relativePath }
    }
    public struct RemoteDirectory: Decodable, Sendable {
        public let rootPath: String
        public let relativePath: String
        public let entries: [RemoteEntry]
    }
    public func prepareWebDAV(rootURL: String, credential: WebDAVCredential, accessRef: String? = nil) async throws -> Access {
        struct Input: Encodable { let rootUrl: String; let credential: WebDAVCredential; let accessRef: String? }
        return try await invoke("library.webdav.access.prepare", Input(rootUrl: rootURL, credential: credential, accessRef: accessRef))
    }
    public func browseWebDAV(accessId: String, relativePath: String = "") async throws -> RemoteDirectory {
        try await invoke("library.webdav.browse", ["accessId": accessId, "relativePath": relativePath])
    }
    public func restoreWebDAV(sourceId: String, rootURL: String, credential: WebDAVCredential) async throws {
        struct Input: Encodable { let sourceId: String; let rootUrl: String; let credential: WebDAVCredential }
        struct Result: Decodable { let restored: Bool }
        let _: Result = try await invoke("library.webdav.credentials.restore", Input(sourceId: sourceId, rootUrl: rootURL, credential: credential))
    }
    public func releasePlayback(leaseId: String) async throws {
        struct Result: Decodable { let released: Bool }
        let _: Result = try await invoke("library.playback.release", ["leaseId": leaseId])
    }
    public struct SMBCredential: Codable, Sendable, Equatable {
        public let type: String
        public let username: String?
        public let password: String?
        public let domain: String?
        public let requireSigning: Bool?
        public let requireEncryption: Bool?
        public static var guest: Self { .init(type: "guest", username: nil, password: nil, domain: nil, requireSigning: nil, requireEncryption: nil) }
        public static func password(username: String, password: String, domain: String = "", requireSigning: Bool = true, requireEncryption: Bool = false) -> Self {
            .init(type: "password", username: username, password: password, domain: domain, requireSigning: requireSigning, requireEncryption: requireEncryption)
        }
    }
    public func prepareSMB(rootURL: String, credential: SMBCredential, accessRef: String? = nil) async throws -> Access {
        struct Input: Encodable { let rootUrl: String; let credential: SMBCredential; let accessRef: String? }
        return try await invoke("library.smb.access.prepare", Input(rootUrl: rootURL, credential: credential, accessRef: accessRef))
    }
    public func browseSMB(accessId: String, relativePath: String = "") async throws -> RemoteDirectory {
        try await invoke("library.smb.browse", ["accessId": accessId, "relativePath": relativePath])
    }
    public func restoreSMB(sourceId: String, rootURL: String, credential: SMBCredential) async throws {
        struct Input: Encodable { let sourceId: String; let rootUrl: String; let credential: SMBCredential }
        struct Result: Decodable { let restored: Bool }
        let _: Result = try await invoke("library.smb.credentials.restore", Input(sourceId: sourceId, rootUrl: rootURL, credential: credential))
    }
    public func create(_ input: Create) async throws -> Creation { try await invoke("library.create", input) }
    public func addRoot(sourceId: String, libraryId: String, accessId: String, kind: String = "localFolder", rootPath: String) async throws -> RootAddition {
        struct Input: Encodable {
            let sourceId: String
            let libraryId: String
            let accessId: String
            let kind: String
            let rootPath: String
        }
        return try await invoke("library.root.add", Input(sourceId: sourceId, libraryId: libraryId, accessId: accessId, kind: kind, rootPath: rootPath))
    }
    public func renameLibrary(sourceId: String, libraryId: String, name: String) async throws -> Library {
        struct Result: Decodable { let library: Library }
        let result: Result = try await invoke("library.rename", ["sourceId": sourceId, "libraryId": libraryId, "name": name])
        return result.library
    }
    public func deleteLibrary(sourceId: String, libraryId: String) async throws {
        struct Result: Decodable { let deleted: Bool }
        let _: Result = try await invoke("library.delete", ["sourceId": sourceId, "libraryId": libraryId])
    }
    public func removeRoot(sourceId: String, libraryId: String, rootId: String) async throws -> Library {
        struct Result: Decodable { let library: Library }
        let result: Result = try await invoke("library.root.remove", ["sourceId": sourceId, "libraryId": libraryId, "rootId": rootId])
        return result.library
    }
    public func deleteSource(sourceId: String) async throws {
        struct Result: Decodable { let deleted: Bool }
        let _: Result = try await invoke("library.source.delete", ["sourceId": sourceId])
    }
    public func sources() async throws -> [Source] {
        struct Result: Decodable { let sources: [Source] }
        let result: Result = try await invoke("library.sources.list", [:] as [String: String]); return result.sources
    }
    public func libraries(sourceId: String) async throws -> [Library] {
        struct Result: Decodable { let libraries: [Library] }
        let result: Result = try await invoke("library.libraries.list", ["sourceId": sourceId]); return result.libraries
    }
    public func page(_ query: Query) async throws -> Page { try await invoke("library.query.page", query) }
    public func detail(sourceId: String, itemId: String) async throws -> Detail {
        try await invoke("library.query.detail", ["sourceId": sourceId, "itemId": itemId])
    }
    public func resume(sourceId: String, limit: Int = 20) async throws -> [Item] {
        struct Input: Encodable { let sourceId: String; let limit: Int }
        struct Result: Decodable { let items: [Item] }
        let result: Result = try await invoke("library.query.resume", Input(sourceId: sourceId, limit: limit))
        return result.items
    }
    public func nextUp(sourceId: String, limit: Int = 20) async throws -> [Item] {
        struct Input: Encodable { let sourceId: String; let limit: Int }
        struct Result: Decodable { let items: [Item] }
        let result: Result = try await invoke("library.query.nextUp", Input(sourceId: sourceId, limit: limit))
        return result.items
    }
    public func scan(sourceId: String, libraryId: String) async throws -> Job {
        struct Result: Decodable { let job: Job }
        let result: Result = try await invoke("library.scan.start", ["sourceId": sourceId, "libraryId": libraryId]); return result.job
    }
    public func controlScan(sourceId: String, jobId: String, action: ScanAction) async throws -> Job {
        struct Result: Decodable { let job: Job }
        let result: Result = try await invoke("library.scan.\(action.rawValue)", ["sourceId": sourceId, "jobId": jobId]); return result.job
    }
    public enum ScanAction: String, Sendable { case pause, resume, cancel }
    public func jobs(sourceId: String) async throws -> [Job] {
        struct Result: Decodable { let jobs: [Job] }
        let result: Result = try await invoke("library.jobs.snapshot", ["sourceId": sourceId]); return result.jobs
    }
    public func scrape(sourceId: String, libraryId: String, refresh: Bool = false) async throws -> ScrapeRun {
        struct Input: Encodable { let sourceId: String; let libraryId: String; let refresh: Bool }
        struct Result: Decodable { let run: ScrapeRun }
        let result: Result = try await invoke("library.scrape.start", Input(sourceId: sourceId, libraryId: libraryId, refresh: refresh))
        return result.run
    }
    public enum ScrapeAction: String, Sendable { case pause, resume, cancel, retry }
    public func controlScrape(sourceId: String, runId: String, action: ScrapeAction) async throws -> ScrapeRun {
        struct Result: Decodable { let run: ScrapeRun }
        let result: Result = try await invoke("library.scrape.\(action.rawValue)", ["sourceId": sourceId, "runId": runId])
        return result.run
    }
    public func scrapes(sourceId: String) async throws -> [ScrapeRun] {
        struct Result: Decodable { let runs: [ScrapeRun] }
        let result: Result = try await invoke("library.scrape.snapshot", ["sourceId": sourceId]); return result.runs
    }
    public func candidates(sourceId: String, itemId: String, query: String) async throws -> MatchCandidates {
        try await invoke("library.match.candidates", ["sourceId": sourceId, "itemId": itemId, "query": query])
    }
    public func bind(sourceId: String, itemId: String, inputVersion: String, tmdbId: Int64) async throws -> Item {
        struct Input: Encodable { let sourceId: String; let itemId: String; let inputVersion: String; let tmdbId: Int64 }
        struct Result: Decodable { let bound: Bool; let item: Item }
        let result: Result = try await invoke("library.match.bind", Input(sourceId: sourceId, itemId: itemId, inputVersion: inputVersion, tmdbId: tmdbId)); return result.item
    }
    public func unbind(sourceId: String, itemId: String) async throws {
        struct Result: Decodable { let unbound: Bool }
        let _: Result = try await invoke("library.match.unbind", ["sourceId": sourceId, "itemId": itemId])
    }
    public func preparePlayback(sourceId: String, itemId: String, assetId: String) async throws -> Playback {
        try await invoke("library.playback.prepare", ["sourceId": sourceId, "itemId": itemId, "assetId": assetId])
    }
    public func recordProgress(_ progress: Progress) async throws -> Bool {
        struct Result: Decodable { let accepted: Bool; let progress: Progress? }
        let result: Result = try await invoke("library.progress.record", progress); return result.accepted
    }
    public func markPlayed(sourceId: String, itemId: String, played: Bool, recordedAt: Double = Date().timeIntervalSince1970) async throws -> Progress {
        struct Input: Encodable { let sourceId: String; let itemId: String; let recordedAt: Double }
        struct Result: Decodable { let progress: Progress }
        let method = played ? "library.progress.markPlayed" : "library.progress.markUnplayed"
        let result: Result = try await invoke(method, Input(sourceId: sourceId, itemId: itemId, recordedAt: recordedAt))
        return result.progress
    }

    private func invoke<T: Decodable, Input: Encodable>(_ method: String, _ input: Input) async throws -> T {
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let response = try await client.callAsync(method, argumentsJSON: json)
        if response.code == 1003 { throw CancellationError() }
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.decodeData(T.self)
    }
}
