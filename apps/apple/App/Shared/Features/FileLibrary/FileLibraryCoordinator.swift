import CryptoKit
import Darwin
import DiagnosticsKit
import Foundation
import OcPlayerCore
import Observation
import PlaybackKit

/// Host ownership of the permanent Core catalog and Apple directory permissions.
/// File sources never acquire a MediaServer profile or enter Media.sqlite.
@MainActor
@Observable
final class FileLibraryCoordinator {
    private(set) var sources: [OcpFileLibrary.Source] = []
    private(set) var capabilities: OcpFileLibrary.Capabilities?
    private(set) var availabilityError: String?
    private(set) var permissionErrors: [String: String] = [:]
    private(set) var catalogRevision = 0
    private(set) var metadataRevision = 0
    private(set) var configurationRevision = 0
    private(set) var progressError: String?
    private(set) var scrapingError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var runtime: FileLibraryRuntime?
    @ObservationIgnored private var setupTask: Task<Void, Error>?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var lastCredentialRevision: String?
    @ObservationIgnored private let remoteCredentials: CredentialFileStore
    @ObservationIgnored private var restoredRemoteSources: Set<String> = []

    init(directory: URL = OcPlayerStorage.defaultRoot) {
        self.directory = directory
        remoteCredentials = CredentialFileStore(directory: directory, fileName: "LibraryCredentials.json")
    }

    func setup() async throws {
        if let setupTask { return try await setupTask.value }
        let task = Task { @MainActor in
            do {
                let runtime = try FileLibraryRuntime(directory: directory)
                self.runtime = runtime
                try await runtime.sdk.open(directory: directory)
                let caps = try await runtime.sdk.capabilities()
                guard caps.sourceKinds.contains("localFolder"), caps.tmdbAccessValidation,
                      caps.libraryTypes.contains(.movies), caps.libraryTypes.contains(.tvshows), !caps.aggregation else {
                    throw OcpCoreError(message: "当前 Core 不支持文件媒体库")
                }
                capabilities = caps
                try await refreshSources()
                for source in sources { restoreAccess(for: source) }
                availabilityError = nil
            } catch {
                if let coreError = error as? OcpCoreError,
                   coreError.message.contains("library") || coreError.message.contains("ABI") {
                    availabilityError = "此版本尚未提供可用的文件媒体库，请更新到支持此功能的版本。"
                } else {
                    availabilityError = "文件媒体库未就绪：\(error.localizedDescription)"
                }
                throw error
            }
        }
        setupTask = task
        try await task.value
    }

    private func withSDK<Value: Sendable>(_ operation: @MainActor (OcpFileLibrary) async throws -> Value) async throws -> Value {
        guard let runtime else { throw OcpCoreError(message: "文件媒体库尚未初始化") }
        // An in-flight ABI call may retain the client beyond its owner. Keep
        // the permission owner alive too, until that call has fully returned.
        defer { withExtendedLifetime(runtime) {} }
        return try await operation(runtime.sdk)
    }

    func refreshSources() async throws { sources = try await withSDK { try await $0.sources() } }
    func libraries(sourceID: String) async throws -> [OcpFileLibrary.Library] {
        try await withSDK { try await $0.libraries(sourceId: sourceID) }
    }
    func page(_ query: OcpFileLibrary.Query) async throws -> OcpFileLibrary.Page {
        try await withSDK { try await $0.page(query) }
    }
    func resume(sourceID: String) async throws -> [OcpFileLibrary.Item] {
        try await withSDK { try await $0.resume(sourceId: sourceID) }
    }
    func detail(sourceID: String, itemID: String) async throws -> OcpFileLibrary.Detail {
        try await withSDK { try await $0.detail(sourceId: sourceID, itemId: itemID) }
    }
    func jobs(sourceID: String) async throws -> [OcpFileLibrary.Job] {
        try await withSDK { try await $0.jobs(sourceId: sourceID) }
    }

    static func credentialRevision(key: String, apiBase: String) -> String {
        SHA256.hash(data: Data((key.trimmingCharacters(in: .whitespacesAndNewlines) + "\0" + apiBase).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Called synchronously on a settings change: an in-flight old validation
    /// cannot authorize creation while an async invalidation is still queued.
    func credentialsChanged(notifyUI: Bool = true) {
        lastCredentialRevision = nil
        scrapingError = nil
        if notifyUI { configurationRevision &+= 1 }
        if let runtime { _ = try? runtime.sdk.client.call("tmdb.access.invalidate") }
    }

    func validate(key: String, apiBase: String, draftID: String, language: String = "zh-CN") async throws -> OcpFileLibrary.Validation {
        try await setup()
        let revision = Self.credentialRevision(key: key, apiBase: apiBase)
        if lastCredentialRevision != revision { credentialsChanged(notifyUI: false) }
        lastCredentialRevision = revision
        return try await withSDK { try await $0.validate(apiKey: key, apiBase: apiBase, credentialRevision: revision, draftId: draftID, language: language) }
    }

    func scrapes(sourceID: String) async throws -> [OcpFileLibrary.ScrapeRun] {
        guard capabilities?.tmdbScraping == true else { return [] }
        return try await withSDK { try await $0.scrapes(sourceId: sourceID) }
    }

    /// Opening the existing catalog is independent of this online step. User
    /// pauses/failures stay visible until explicitly resumed or retried.
    func resumeOnlineWork(sourceID: String, key: String?, apiBase: String, language: String) async {
        guard capabilities?.tmdbScraping == true else { return }
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try await validate(key: key, apiBase: apiBase, draftID: "file-library-online", language: language)
            let runs = try await scrapes(sourceID: sourceID)
            let categories = try await libraries(sourceID: sourceID)
            for category in categories {
                if let run = runs.first(where: { $0.libraryId == category.libraryId }) {
                    if ["queued", "interrupted", "waitingCredentials"].contains(run.status) {
                        try await controlScrape(run, action: .resume)
                    }
                } else {
                    _ = try await withSDK { try await $0.scrape(sourceId: sourceID, libraryId: category.libraryId) }
                }
            }
            scrapingError = nil
        } catch is CancellationError { return }
        catch { scrapingError = "在线刮削暂未就绪：\(error.localizedDescription)" }
    }

    func scrape(sourceID: String, libraryID: String, key: String, apiBase: String, language: String, refresh: Bool = false) async throws {
        _ = try await validate(key: key, apiBase: apiBase, draftID: "file-library-online", language: language)
        let run = try await withSDK { try await $0.scrape(sourceId: sourceID, libraryId: libraryID, refresh: refresh) }
        if ["paused", "interrupted", "waitingCredentials"].contains(run.status) {
            try await controlScrape(run, action: .resume)
        }
        scrapingError = nil
    }

    func controlScrape(_ run: OcpFileLibrary.ScrapeRun, action: OcpFileLibrary.ScrapeAction) async throws {
        for attempt in 0..<12 {
            do {
                _ = try await withSDK { try await $0.controlScrape(sourceId: run.sourceId, runId: run.runId, action: action) }
                return
            } catch {
                guard [.resume, .retry].contains(action), attempt < 11,
                      error.localizedDescription.contains("wait for the running scrape") else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func candidates(item: OcpFileLibrary.Item, query: String, key: String, apiBase: String, language: String) async throws -> OcpFileLibrary.MatchCandidates {
        _ = try await validate(key: key, apiBase: apiBase, draftID: "file-library-online", language: language)
        return try await withSDK { try await $0.candidates(sourceId: item.sourceId, itemId: item.itemId, query: query) }
    }
    func bind(item: OcpFileLibrary.Item, inputVersion: String, tmdbID: Int64) async throws {
        _ = try await withSDK { try await $0.bind(sourceId: item.sourceId, itemId: item.itemId, inputVersion: inputVersion, tmdbId: tmdbID) }
        // Download only seasons already present in this category.
        _ = try await withSDK { try await $0.scrape(sourceId: item.sourceId, libraryId: item.libraryId) }
        metadataDidChange()
    }
    func unbind(item: OcpFileLibrary.Item) async throws {
        try await withSDK { try await $0.unbind(sourceId: item.sourceId, itemId: item.itemId) }
        metadataDidChange()
    }

    func metadataDidChange() { metadataRevision &+= 1; catalogRevision &+= 1 }
    func taskObservationFailed(_ error: Error) { scrapingError = "媒体库任务更新失败：\(error.localizedDescription)" }

    func create(draftID: String, verificationID: String, credentialRevision: String, apiBase: String,
                source: OcpFileLibrary.Source?, root: URL, subdirectory: String,
                sourceName: String, name: String, type: OcpFileLibrary.LibraryType) async throws -> OcpFileLibrary.Creation {
        try await setup()
        guard lastCredentialRevision == credentialRevision else {
            throw OcpCoreError(message: "TMDB 配置已变更，请重新验证")
        }
        guard let runtime else { throw OcpCoreError(message: "文件媒体库未就绪") }
        defer { withExtendedLifetime(runtime) {} }
        let accessRef = source?.accessRef ?? UUID().uuidString
        let authorized = try runtime.authorize(root, ref: accessRef, expectedRoot: source?.rootPath)
        let components = subdirectory.split(separator: "/", omittingEmptySubsequences: true)
        guard !subdirectory.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
            throw OcpCoreError(message: "分类目录应填写根目录下的相对路径，例如 Movies 或 TV")
        }
        let category = components.reduce(authorized) { $0.appendingPathComponent(String($1)) }
        let access = try await runtime.sdk.prepareAccess(root: authorized, accessRef: accessRef)
        let result = try await runtime.sdk.create(.init(
            draftId: draftID, verificationId: verificationID, credentialRevision: credentialRevision,
            apiBase: apiBase, accessId: access.accessId, sourceId: source?.sourceId,
            sourceName: sourceName, rootPath: category.path, name: name, type: type))
        try await refreshSources()
        permissionErrors[result.library.sourceId] = nil
        catalogRevision &+= 1
        return result
    }

    func authorize(source: OcpFileLibrary.Source, root: URL) throws {
        guard let runtime else { throw OcpCoreError(message: "文件媒体库未就绪") }
        _ = try runtime.authorize(root, ref: source.accessRef ?? source.sourceId, expectedRoot: source.rootPath)
        permissionErrors[source.sourceId] = nil
    }

    private func restoreAccess(for source: OcpFileLibrary.Source) {
        if source.kind != "localFolder" { return }
        do {
            guard let runtime else { return }
            let restored = try runtime.restore(ref: source.accessRef ?? source.sourceId)
            guard restored.path == source.rootPath else {
                throw OcpCoreError(message: "目录位置已变更，请重新选择原目录")
            }
        } catch { permissionErrors[source.sourceId] = "需要重新授权目录：\(error.localizedDescription)" }
    }

    private func requireAccess(_ sourceID: String) throws {
        if let message = permissionErrors[sourceID] { throw OcpCoreError(message: message) }
        guard sources.contains(where: { $0.sourceId == sourceID }) else { throw OcpCoreError(message: "来源不存在") }
    }

    func scan(sourceID: String, libraryID: String) async throws {
        try await ensureRemoteAccess(sourceID)
        try requireAccess(sourceID)
        _ = try await withSDK { try await $0.scan(sourceId: sourceID, libraryId: libraryID) }
    }
    func control(_ job: OcpFileLibrary.Job, action: OcpFileLibrary.ScanAction) async throws {
        if action == .resume { try await ensureRemoteAccess(job.sourceId); try requireAccess(job.sourceId) }
        for attempt in 0..<12 {
            do {
                _ = try await withSDK { try await $0.controlScan(sourceId: job.sourceId, jobId: job.jobId, action: action) }
                return
            } catch {
                guard action == .resume, attempt < 11, error.localizedDescription.contains("wait for the running scan") else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func preparePlayback(item: OcpFileLibrary.Item, asset: OcpFileLibrary.Asset) async throws -> OcpFileLibrary.Playback {
        try await ensureRemoteAccess(item.sourceId)
        try requireAccess(item.sourceId)
        return try await withSDK { try await $0.preparePlayback(sourceId: item.sourceId, itemId: item.itemId, assetId: asset.assetId) }
    }

    func storedWebDAVCredential(for source: OcpFileLibrary.Source) -> OcpFileLibrary.WebDAVCredential? {
        guard let data = remoteCredentials.data(forKey: source.accessRef ?? source.sourceId) else { return nil }
        return try? JSONDecoder().decode(OcpFileLibrary.WebDAVCredential.self, from: data)
    }
    private func saveRemoteCredential(_ data: Data, ref: String) throws {
        remoteCredentials.setData(data, forKey: ref)
        let freshStore = CredentialFileStore(directory: directory, fileName: "LibraryCredentials.json")
        guard freshStore.data(forKey: ref) == data else {
            throw OcpCoreError(message: "连接凭据未能保存，请检查媒体库存储位置后重试")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: freshStore.url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw OcpCoreError(message: "连接凭据文件权限未能设置，请检查存储位置后重试")
        }
    }

    func prepareWebDAV(rootURL: String, credential: OcpFileLibrary.WebDAVCredential, accessRef: String) async throws -> OcpFileLibrary.Access {
        try await setup()
        return try await withSDK { try await $0.prepareWebDAV(rootURL: rootURL, credential: credential, accessRef: accessRef) }
    }
    func browseWebDAV(accessID: String, relativePath: String) async throws -> OcpFileLibrary.RemoteDirectory {
        try await withSDK { try await $0.browseWebDAV(accessId: accessID, relativePath: relativePath) }
    }
    func createWebDAV(draftID: String, verificationID: String, credentialRevision: String, apiBase: String,
                      source: OcpFileLibrary.Source?, access: OcpFileLibrary.Access, category: OcpFileLibrary.RemoteDirectory,
                      credential: OcpFileLibrary.WebDAVCredential, accessRef: String, sourceName: String,
                      name: String, type: OcpFileLibrary.LibraryType) async throws -> OcpFileLibrary.Creation {
        guard lastCredentialRevision == credentialRevision else { throw OcpCoreError(message: "TMDB 配置已变更，请重新验证") }
        // A crash after catalog creation must not discard the only saved credential.
        try saveRemoteCredential(JSONEncoder().encode(credential), ref: accessRef)
        let result = try await withSDK { try await $0.create(.init(
            draftId: draftID, verificationId: verificationID, credentialRevision: credentialRevision, apiBase: apiBase,
            accessId: access.accessId, kind: "webdav", sourceId: source?.sourceId, sourceName: sourceName,
            rootPath: category.rootPath, name: name, type: type)) }
        try await refreshSources()
        restoredRemoteSources.insert(result.library.sourceId)
        permissionErrors[result.library.sourceId] = nil
        catalogRevision &+= 1
        return result
    }
    func restoreWebDAV(source: OcpFileLibrary.Source, credential: OcpFileLibrary.WebDAVCredential) async throws {
        restoredRemoteSources.remove(source.sourceId)
        do {
            try await withSDK { try await $0.restoreWebDAV(sourceId: source.sourceId, rootURL: source.rootPath, credential: credential) }
        } catch {
            permissionErrors[source.sourceId] = "WebDAV 连接未就绪：\(error.localizedDescription)"
            throw error
        }
        try saveRemoteCredential(JSONEncoder().encode(credential), ref: source.accessRef ?? source.sourceId)
        restoredRemoteSources.insert(source.sourceId)
        permissionErrors[source.sourceId] = nil
    }
    private func ensureRemoteAccess(_ sourceID: String) async throws {
        guard let source = sources.first(where: { $0.sourceId == sourceID }), source.kind != "localFolder",
              !restoredRemoteSources.contains(sourceID) else { return }
        do {
            if source.kind == "smb" {
                guard let credential = storedSMBCredential(for: source) else { throw OcpCoreError(message: "请在媒体来源中更新 SMB 凭据") }
                try await restoreSMB(source: source, credential: credential)
            } else {
                guard let credential = storedWebDAVCredential(for: source) else { throw OcpCoreError(message: "请在媒体来源中更新 WebDAV 凭据") }
                try await restoreWebDAV(source: source, credential: credential)
            }
        } catch {
            permissionErrors[sourceID] = "远程连接未就绪：\(error.localizedDescription)"
            throw error
        }
    }
    func storedSMBCredential(for source: OcpFileLibrary.Source) -> OcpFileLibrary.SMBCredential? {
        guard let data = remoteCredentials.data(forKey: source.accessRef ?? source.sourceId) else { return nil }
        return try? JSONDecoder().decode(OcpFileLibrary.SMBCredential.self, from: data)
    }
    func prepareSMB(rootURL: String, credential: OcpFileLibrary.SMBCredential, accessRef: String) async throws -> OcpFileLibrary.Access {
        try await setup()
        return try await withSDK { try await $0.prepareSMB(rootURL: rootURL, credential: credential, accessRef: accessRef) }
    }
    func browseSMB(accessID: String, relativePath: String) async throws -> OcpFileLibrary.RemoteDirectory {
        try await withSDK { try await $0.browseSMB(accessId: accessID, relativePath: relativePath) }
    }
    func createSMB(draftID: String, verificationID: String, credentialRevision: String, apiBase: String,
                   source: OcpFileLibrary.Source?, access: OcpFileLibrary.Access, category: OcpFileLibrary.RemoteDirectory,
                   credential: OcpFileLibrary.SMBCredential, accessRef: String, sourceName: String,
                   name: String, type: OcpFileLibrary.LibraryType) async throws -> OcpFileLibrary.Creation {
        guard lastCredentialRevision == credentialRevision else { throw OcpCoreError(message: "TMDB 配置已变更，请重新验证") }
        try saveRemoteCredential(JSONEncoder().encode(credential), ref: accessRef)
        let result = try await withSDK { try await $0.create(.init(
            draftId: draftID, verificationId: verificationID, credentialRevision: credentialRevision, apiBase: apiBase,
            accessId: access.accessId, kind: "smb", sourceId: source?.sourceId, sourceName: sourceName,
            rootPath: category.rootPath, name: name, type: type)) }
        try await refreshSources()
        restoredRemoteSources.insert(result.library.sourceId)
        permissionErrors[result.library.sourceId] = nil
        catalogRevision &+= 1
        return result
    }
    func restoreSMB(source: OcpFileLibrary.Source, credential: OcpFileLibrary.SMBCredential) async throws {
        restoredRemoteSources.remove(source.sourceId)
        do { try await withSDK { try await $0.restoreSMB(sourceId: source.sourceId, rootURL: source.rootPath, credential: credential) } }
        catch { permissionErrors[source.sourceId] = "SMB 连接未就绪：\(error.localizedDescription)"; throw error }
        try saveRemoteCredential(JSONEncoder().encode(credential), ref: source.accessRef ?? source.sourceId)
        restoredRemoteSources.insert(source.sourceId)
        permissionErrors[source.sourceId] = nil
    }
    func retainPlayback(_ playback: OcpFileLibrary.Playback) -> PlaybackResourceLifetime? {
        guard let id = playback.leaseId, let runtime else { return nil }
        return PlaybackResourceLifetime {
            Task.detached { try? await runtime.sdk.releasePlayback(leaseId: id); withExtendedLifetime(runtime) {} }
        }
    }

    @discardableResult
    func record(_ value: OcpFileLibrary.Progress) -> Task<Void, Never> {
        let previous = pendingWrite
        let task = Task { @MainActor in
            await previous?.value
            do {
                _ = try await withSDK { try await $0.recordProgress(value) }
                progressError = nil
                catalogRevision &+= 1
            } catch { progressError = "观看进度保存失败：\(error.localizedDescription)" }
        }
        pendingWrite = task
        return task
    }
}

/// Leases outlive all scanning workers. Destroying Core pauses and joins workers
/// before releasing the Apple scopes; the database and bookmarks are permanent.
private final class FileLibraryRuntime: @unchecked Sendable {
    private var core: OcpFileLibrary?
    var sdk: OcpFileLibrary { core! }
    private let bookmarkFile: URL
    private var bookmarks: [String: Data]
    private var bookmarkReadError: String?
    private var leases: [String: (url: URL, scoped: Bool)] = [:]

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bookmarkFile = directory.appendingPathComponent("LibraryBookmarks.json")
        if FileManager.default.fileExists(atPath: bookmarkFile.path) {
            do { bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: bookmarkFile)) }
            catch { bookmarks = [:]; bookmarkReadError = error.localizedDescription }
        } else { bookmarks = [:] }
        core = OcpFileLibrary(client: try OcpCoreClient())
    }

    deinit {
        core = nil
        for lease in leases.values where lease.scoped { lease.url.stopAccessingSecurityScopedResource() }
    }

    func authorize(_ url: URL, ref: String, expectedRoot: String? = nil) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let canonical = try canonicalRoot(url)
            if let expectedRoot, canonical.path != expectedRoot {
                throw OcpCoreError(message: "请选择原目录：\(expectedRoot)")
            }
            if let previous = leases[ref] {
                guard try canonicalRoot(previous.url) == canonical else {
                    throw OcpCoreError(message: "目录授权与已有来源不一致")
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
                return canonical
            }
            var options: URL.BookmarkCreationOptions = []
            #if os(macOS)
            options = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            #endif
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            var updated = bookmarks
            updated[ref] = data
            if bookmarkReadError != nil {
                let backup = bookmarkFile.deletingLastPathComponent().appendingPathComponent("LibraryBookmarks.corrupt-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: bookmarkFile, to: backup)
            }
            try JSONEncoder().encode(updated).write(to: bookmarkFile, options: .atomic)
            bookmarkReadError = nil
            bookmarks = updated
            leases[ref] = (url, scoped)
            return canonical
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func restore(ref: String) throws -> URL {
        if let lease = leases[ref] { return try canonicalRoot(lease.url) }
        guard let data = bookmarks[ref] else { throw OcpCoreError(message: bookmarkReadError.map { "目录书签无法读取：\($0)" } ?? "没有保存的目录书签") }
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI]
        #if os(macOS)
        options.insert(.withSecurityScope)
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        // A stale bookmark needs renewed host authorization; do not scan an
        // accidentally resolved replacement directory under the old identity.
        guard !stale else { throw OcpCoreError(message: "目录书签已失效") }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let canonical = try canonicalRoot(url)
            leases[ref] = (url, scoped)
            return canonical
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Match Rust std::fs::canonicalize, including Apple's /var → /private/var
    /// aliases. Foundation URL normalization can retain the logical spelling.
    private func canonicalRoot(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
