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
        // ## `P2-23`「合并 4 次读」：**值得做，但本批没做**（见下）
        //
        // 清单建议把这里的四个 `await` 合成一次 `database.read`，理由是
        // 「4 次 actor 跳转 + 4 个读事务」。
        //
        // ## ⚠️ 我第一次的测量结论是**错的**，差约两个数量级
        //
        // 我最初分开量了「跳转」与「读」，看到纯跳转只要 0.29 µs、单次读 89.78 µs，
        // 就写结论说「合并只能省三个跳转 ≈ 0.9 µs，在 363 µs 面前量不出来」。
        // **错在把「读」当成不可拆的整体** —— 合并省掉的主要**不是跳转，是读事务**。
        //
        // 独立审查用真实数据（8 个库 + 3 条 rail × 20 条 MediaItem）交替 A/B 实测：
        //
        // | 变体 | p50 |
        // |---|---|
        // | `home()` 原样（4 个读事务） | 966.2 µs |
        // | 一次 read + 一条 SQL 取三条 rail | **789.8 µs（省 18.3%）** |
        // | 只合并事务、仍 4 条查询 | 省 11.1% |
        //
        // 我复测了「每个读事务」的单独成本：**≈29.3 µs**（4 个事务 147.0 µs vs
        // 1 个事务 4 条查询 59.0 µs，差 88 µs / 3）。审查测到 ≈37 µs，同量级。
        // 所以 4 次读里约 **90–150 µs 是事务 / 连接 checkout 开销**，合并真能省下。
        //
        // **本批不做**的原因不是「不值得」，而是**收益不足以撑起一次跨文件的读取
        // 重构**：它需要给 `MetadataStore` 加一个「一次 read 里取库 + 三条 rail」的
        // 方法，属于数据层 API 变更，和本批的 Bangumi N+1 混在一起会让回滚粒度变粗。
        // 留给下一批（可与 `P2-25` 的翻页 O(P²) 一起做）。
        //
        // 结论：**这条是小而可测的性能项（11–18%，百 µs 级），不是「不是性能问题」。**
        // 别再照着我第一版那句「量不出来」放弃它。
        let libraries = (try? await store.libraries(tenant: tenant))?.map(\.library) ?? []
        let resume = (try? await store.rail("resume", tenant: tenant))
        let nextUp = (try? await store.rail("nextUp", tenant: tenant))
        let latest = (try? await store.rail("latest", tenant: tenant))

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
