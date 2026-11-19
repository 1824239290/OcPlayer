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
    public struct Library: Decodable, Sendable, Identifiable {
        public let libraryId: String
        public let sourceId: String
        public let name: String
        public let rootPath: String
        public let type: LibraryType
        public let revision: Int64
        public let createdAt: Double
        public var id: String { libraryId }
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
    public struct Page: Decodable, Sendable { public let items: [Item]; public let totalCount: Int64; public let startIndex: Int64 }
    public struct Detail: Decodable, Sendable { public let item: Item; public let assets: [Asset]; public let progress: Progress? }
    public struct Playback: Decodable, Sendable {
        public let sourceId: String; public let itemId: String; public let assetId: String
        public let uri: String; public let headers: [String: String]; public let progress: Progress?
    }
    public struct Query: Encodable, Sendable {
        public var sourceId: String
        public var libraryId: String?
        public var type: LibraryType?
        public var parentId: String?
        public var search: String
        public var startIndex: Int64
        public var limit: Int
        public init(sourceId: String, libraryId: String? = nil, type: LibraryType? = nil, parentId: String? = nil, search: String = "", startIndex: Int64 = 0, limit: Int = 50) {
            self.sourceId = sourceId; self.libraryId = libraryId; self.type = type; self.parentId = parentId
            self.search = search; self.startIndex = startIndex; self.limit = limit
        }
    }
    public struct Create: Encodable, Sendable {
        public let draftId: String
        public let verificationId: String
        public let credentialRevision: String
        public let apiBase: String
        public let accessId: String
        public let kind = "localFolder"
        public let sourceId: String?
        public let sourceName: String
        public let rootPath: String
        public let name: String
        public let type: LibraryType
        public init(draftId: String, verificationId: String, credentialRevision: String, apiBase: String, accessId: String, sourceId: String? = nil, sourceName: String, rootPath: String, name: String, type: LibraryType) {
            self.draftId = draftId; self.verificationId = verificationId; self.credentialRevision = credentialRevision
            self.apiBase = apiBase; self.accessId = accessId; self.sourceId = sourceId; self.sourceName = sourceName
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
    public func validate(apiKey: String, apiBase: String, credentialRevision: String, draftId: String) async throws -> Validation {
        try await invoke("tmdb.access.validate", ["apiKey": apiKey, "apiBase": apiBase, "credentialRevision": credentialRevision, "draftId": draftId])
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
    public func create(_ input: Create) async throws -> Creation { try await invoke("library.create", input) }
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
    public func preparePlayback(sourceId: String, itemId: String, assetId: String) async throws -> Playback {
        try await invoke("library.playback.prepare", ["sourceId": sourceId, "itemId": itemId, "assetId": assetId])
    }
    public func recordProgress(_ progress: Progress) async throws -> Bool {
        struct Result: Decodable { let accepted: Bool; let progress: Progress? }
        let result: Result = try await invoke("library.progress.record", progress); return result.accepted
    }

    private func invoke<T: Decodable, Input: Encodable>(_ method: String, _ input: Input) async throws -> T {
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let response = try await client.callAsync(method, argumentsJSON: json)
        if response.code == 1003 { throw CancellationError() }
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.decodeData(T.self)
    }
}
