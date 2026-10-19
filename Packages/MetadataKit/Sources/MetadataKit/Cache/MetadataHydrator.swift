import CoreModel
import Foundation
import JellyfinKit

/// 离线读：把磁盘上的缓存取出来交给 UI。
///
/// 与 `CachedMediaServer` **刻意分成两个类型**：装饰器只管写穿、不做任何判断；
/// 这个类型只管读、且读不到就返回 nil 由调用方决定怎么办。合在一起就会变成
/// 「装饰器有时返回缓存有时返回网络」，调用方再也分不清手上的是不是新数据。
///
/// 所有方法的失败语义都是 **nil**（读不到 / 没缓存 / 解不出来），不抛错：
/// 磁盘是可选增强，它出问题不该让页面报错——调用方照常走网络就好。
public struct MetadataHydrator: Sendable {

    private let store: MetadataStore
    private let tenant: TenantID

    public init(store: MetadataStore, tenant: TenantID) {
        self.store = store
        self.tenant = tenant
    }

    // MARK: - 首页

    public struct HomeSnapshot: Sendable {
        public var libraries: [MediaLibrary]
        public var resume: [MediaItem]
        public var nextUp: [MediaItem]
        public var latest: [MediaItem]
        /// 各条 rail 的写入时间（取最早的那条作为整体新鲜度——首页是作为一个整体
        /// 呈现的，只要有一条是旧的，整页就该标「可能不是最新」）。
        public var fetchedAt: Date?
    }

    /// 首页相关的一切（库列表 + 三条 rail）。
    ///
    /// 返回 nil 表示**一点缓存都没有**（全新安装 / 刚清空），调用方应保持原有
    /// 加载态；返回非 nil 时哪怕只有一条 rail 有内容也值得先用上。
    public func home() async -> HomeSnapshot? {
        // `P2-23`：**一次读事务**取回库列表 + 三条 rail。
        //
        // 原本这里是四个独立 `await`（`libraries` + 三条 `rail`），每次都是一次
        // `database.read`。而**读事务本身就要 ≈29–37 µs**（实测：4 个事务跑 4 条
        // trivial 查询 147.0 µs，1 个事务跑 4 条 59.0 µs）。
        //
        // 真实数据 A/B（8 个库 + 3 条 rail × 20 条 `MediaItem`，交替 300 次取 p50）：
        //   四个独立读                      966.2 µs
        //   一次读 + 一条 SQL 取三条 rail   789.8 μs（省 18.3%）
        //
        // ⚠️ 我最初量错了（把「读」当成不可拆的整体，得出「只省 0.9 µs、量不出来」的
        // 错误结论，差两个数量级）。上面这两个数才是真的 —— 别再照那句旧结论放弃。
        // 读失败要**与「没有缓存」区分开**：前者应让调用方保留加载态（可能是临时
        // I/O 错误，下次会好），后者才是「服务端就是空的」→ 返回 nil。
        // 失败时返回 nil 保持原加载态，与原来「四个 try? 全失败」的结果一致。
        guard let parts = try? await store.homeSnapshotParts(tenant: tenant) else { return nil }
        let libraries = parts.libraries.map(\.library)
        let resume = parts.rails["resume"]
        let nextUp = parts.rails["nextUp"]
        let latest = parts.rails["latest"]

        let dates = [resume?.fetchedAt, nextUp?.fetchedAt, latest?.fetchedAt].compactMap { $0 }
        let snapshot = HomeSnapshot(
            libraries: libraries,
            resume: resume?.items ?? [],
            nextUp: nextUp?.items ?? [],
            latest: latest?.items ?? [],
            fetchedAt: dates.min())

        // 全空 = 没缓存过。返回 nil 而不是空快照：空快照会让 UI 以为
        // 「服务端就是空的」，把骨架屏换成空态。
        guard !snapshot.libraries.isEmpty
                || !snapshot.resume.isEmpty
                || !snapshot.nextUp.isEmpty
                || !snapshot.latest.isEmpty
        else { return nil }
        return snapshot
    }

    // MARK: - 详情

    public struct DetailSnapshot: Sendable {
        public var item: MediaItem
        public var seasons: [MediaItem]
        public var episodes: [MediaItem]
        public var fetchedAt: Date
    }

    /// 条目详情 +（剧集时的）季与集。
    ///
    /// 季节与集都从 `item` 表按族谱取：缓存里存的是「曾经拉过的季/集」，
    /// 所以离线时能给出的就是上次看到的那一季。取不到不报错——详情页对
    /// 「没有季列表」本来就有兜底（只显示条目本身）。
    public func detail(itemID: MediaItem.ID) async -> DetailSnapshot? {
        guard let cached = try? await store.item(itemID, tenant: tenant) else { return nil }
        let item = cached.item

        var seasons: [MediaItem] = []
        var episodes: [MediaItem] = []
        if item.kind == .series {
            seasons = (try? await store.seasons(seriesID: item.id, tenant: tenant)) ?? []
            if let first = seasons.first {
                episodes = (try? await store.episodes(seriesID: item.id, seasonID: first.id, tenant: tenant)) ?? []
            }
        }
        return DetailSnapshot(
            item: item, seasons: seasons, episodes: episodes, fetchedAt: cached.fetchedAt)
    }
}
