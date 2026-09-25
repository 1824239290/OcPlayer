import CryptoKit
import DiagnosticsKit
import Foundation

/// 标题别名的来源。App 层用 BangumiKit 实现（`BangumiSubjectService.search` 拿 `name_cn`），
/// DanmakuKit 不依赖 BangumiKit——端点知识与镜像设置留在 BangumiKit 一处。
///
/// 契约：查不到返回空数组，**不得抛错**；解析失败由实现方自己记日志（弹幕装载不因
/// 别名解析失败而失败）。
public protocol DanmakuTitleAliasProviding: Sendable {
    /// 该标题的候选别名，中文名优先。
    func aliases(for title: String) async -> [String]
}

/// 一条别名解析结果。`aliases` 为空即负缓存。
public struct DanmakuTitleAliasRecord: Codable, Sendable, Equatable {
    public let aliases: [String]
    public let resolvedAt: Date

    public init(aliases: [String], resolvedAt: Date) {
        self.aliases = aliases
        self.resolvedAt = resolvedAt
    }
}

/// 标题 → 别名（中文名优先）解析器。结果永久缓存，负结果 7 天后重试。
///
/// 存在的理由：弹弹play 库里的 `animeTitle` 固定是简体中文，且日文名召回不稳
/// （实测 `負けヒロインが多すぎる` 搜不到、中文名命中第一）。本地标题是日文/罗马音时，
/// 先换成中文名再搜、再打分，召回与标题相似度两条路一起修。
public actor DanmakuTitleAliasResolver {
    private let store: DanmakuTitleAliasStore
    private let provider: DanmakuTitleAliasProviding
    /// 时间注入（测试负缓存过期用）。
    private let now: @Sendable () -> Date

    public init(store: DanmakuTitleAliasStore, provider: DanmakuTitleAliasProviding) {
        self.store = store
        self.provider = provider
        self.now = { Date() }
    }

    /// 测试注入时钟。
    init(
        store: DanmakuTitleAliasStore,
        provider: DanmakuTitleAliasProviding,
        now: @escaping @Sendable () -> Date
    ) {
        self.store = store
        self.provider = provider
        self.now = now
    }

    /// 负缓存有效期：没解析出来的标题 7 天后重试（新番可能后来才被收录）。
    static let negativeCacheLifetime: TimeInterval = 7 * 24 * 3600

    /// 解析别名。空标题或解析失败返回空数组。
    public func aliases(for title: String) async -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let key = Self.cacheKey(for: trimmed)
        if let record = await store.record(for: key) {
            if !record.aliases.isEmpty { return record.aliases }
            if now().timeIntervalSince(record.resolvedAt) < Self.negativeCacheLifetime { return [] }
        }

        let resolved = await provider.aliases(for: trimmed)
        await store.setRecord(
            DanmakuTitleAliasRecord(aliases: resolved, resolvedAt: now()), for: key)
        NetworkLog.report(
            category: "Danmaku",
            level: resolved.isEmpty ? .debug : .info,
            "标题别名解析",
            fields: [
                "aliasCount": .integer(Int64(resolved.count)),
                "resolved": .boolean(!resolved.isEmpty),
            ]
        )
        return resolved
    }

    /// 缓存键：标题的归一形态（全角/大小写/标点无关）。
    static func cacheKey(for title: String) -> String {
        let raw = DanmakuFilenameParser.comparableTitle(title)
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `title-aliases.json`：别名解析结果的永久缓存（actor 隔离，原子写，写穿内存缓存）。
/// 文件可由解析随时重建：损坏视为空并允许覆盖（与 AniSkip 的 ID 缓存同一策略）。
public actor DanmakuTitleAliasStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cached: [String: DanmakuTitleAliasRecord]?
    private var loaded = false

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(for key: String) -> DanmakuTitleAliasRecord? {
        load()[key]
    }

    public func setRecord(_ record: DanmakuTitleAliasRecord, for key: String) {
        var map = load()
        map[key] = record
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: url(), options: .atomic)
        cached = map
        loaded = true
    }

    private func url() -> URL {
        directory.appendingPathComponent("title-aliases.json")
    }

    private func load() -> [String: DanmakuTitleAliasRecord] {
        if loaded, let cached { return cached }
        let fileURL = url()
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let map = try? decoder.decode([String: DanmakuTitleAliasRecord].self, from: data)
        else {
            // 文件缺失 / 损坏也按「空」定下来并置 loaded，避免每次查询都重碰文件系统。
            cached = [:]
            loaded = true
            return [:]
        }
        cached = map
        loaded = true
        return map
    }
}
