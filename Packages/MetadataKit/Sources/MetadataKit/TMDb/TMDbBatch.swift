import CoreModel
import Foundation

/// 批量补全的进度快照。
///
/// 四类计数刻意分开：「已是最新」不需要用户做任何事，「拉到」是这次干的活，
/// 「匹配不上」需要用户去手动匹配，「拉取失败」要去看网络/密钥——混成一个
/// 「成功 N 条」的话，用户不知道剩下那些该怎么办。
public struct TMDbBatchProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    /// 已有对应且数据未过期，直接跳过。
    public var skipped: Int
    /// 这次成功拉到数据的条目数。
    public var enriched: Int
    /// 匹配不上（TMDb 上没有 / 认不出来）。**不是故障**，需要人工匹配。
    public var unmatched: Int
    /// 发了请求但失败（网络 / 401 / 429 / 404）。
    public var failed: Int
    /// 这次顺带拉取的季数（剧集才会计入）。
    public var seasons: Int
    /// 正在处理的条目标题（UI 显示「正在补全：XXX」）。
    public var currentTitle: String?

    public var isFinished: Bool { completed >= total && total > 0 }

    /// 进度比例（0…1）。`total == 0` 时返回 1（没有要做的活）。
    public var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }

    public init(completed: Int = 0, total: Int = 0, skipped: Int = 0, enriched: Int = 0,
                unmatched: Int = 0, failed: Int = 0, seasons: Int = 0,
                currentTitle: String? = nil) {
        self.completed = completed
        self.total = total
        self.skipped = skipped
        self.enriched = enriched
        self.unmatched = unmatched
        self.failed = failed
        self.seasons = seasons
        self.currentTitle = currentTitle
    }
}

/// 批量补全的最终结果（= 最后一次进度快照，外加「是否被取消」）。
public struct TMDbBatchResult: Sendable, Equatable {
    public var processed: Int
    public var total: Int
    public var skipped: Int
    public var enriched: Int
    public var unmatched: Int
    public var failed: Int
    public var seasons: Int
    /// 中途被取消（用户点了取消 / 视图消失）。已处理的条目**都已落库**，
    /// 下次再跑会跳过它们（见 `enrichAll` 的可续性说明）。
    public var wasCancelled: Bool

    public var progress: TMDbBatchProgress {
        TMDbBatchProgress(completed: processed, total: total, skipped: skipped,
                          enriched: enriched, unmatched: unmatched, failed: failed,
                          seasons: seasons)
    }
}

// MARK: - 批量补全

extension TMDbEnricher {

    /// 批量补全：把给定的电影/剧逐条匹配 + 拉取；剧集还会把它**各季**一起拉了。
    ///
    /// ## 设计要点
    ///
    /// - **天然可续**：已有对应且数据未过期的条目直接跳过（`performRefresh` 的第一步），
    ///   所以中途取消 / 退出 App 之后再跑一次不会重复打请求，也不会丢进度。
    ///   进度状态就是数据库本身，不需要额外的断点记录。
    /// - **单条失败不影响其它**：每条独立处理，失败只计数。整库补全里有一条网络抖动
    ///   就中断，会让用户以为「补全失败了」而重跑一遍全部。
    /// - **剧集连季一起拉**：季数据决定分集标题 / 剧照 / 切季简介。只拉剧集本身的话，
    ///   那些展示面在**没访问过的**剧集上仍然是空的——而批量补全的意义正是
    ///   「不用一个个点开」。
    /// - **按条汇报进度**，不是按请求：一次库级补全可能有几百个请求，按请求刷 UI
    ///   既无意义又费性能。
    /// - **取消走 `Task.isCancelled`**：调用方取消承载它的 Task 即可（SwiftUI 里就是
    ///   让 `.task` 随视图消失而取消）。不用额外的 cancel 标志，避免两套取消机制打架。
    ///
    /// - Parameter items: 要处理的条目。非电影/剧（合集、音乐、书…）会被跳过并计入
    ///   `processed`——TMDb 的 movie/tv 端点对它们不适用。
    public func enrichAll(
        items: [MediaItem],
        tenant: TenantID,
        onProgress: @Sendable (TMDbBatchProgress) async -> Void = { _ in }
    ) async -> TMDbBatchResult {
        var result = TMDbBatchResult(processed: 0, total: items.count, skipped: 0,
                                     enriched: 0, unmatched: 0, failed: 0, seasons: 0,
                                     wasCancelled: false)
        guard await client.isConfigured, !items.isEmpty else { return result }

        await onProgress(result.progress)

        for item in items {
            if Task.isCancelled {
                result.wasCancelled = true
                break
            }

            // 只有电影与剧有对应的 TMDb 端点；其它类型不适用（也拿不到 id 语义）。
            guard item.kind == .movie || item.kind == .series else {
                result.processed += 1
                continue
            }

            let outcome = await performRefresh(item: item, tenant: tenant)
            switch outcome {
            case .skipped: result.skipped += 1
            case .fetched: result.enriched += 1
            case .noMatch: result.unmatched += 1
            case .failed: result.failed += 1
            }

            // 剧集：把它的各季也拉了（一次请求一季，见 `TMDbClient.season`）。
            if item.kind == .series, outcome == .fetched || outcome == .skipped {
                result.seasons += await enrichSeasons(ofSeries: item, tenant: tenant)
            }

            result.processed += 1
            var snapshot = result.progress
            snapshot.currentTitle = item.name
            await onProgress(snapshot)
        }

        var final = result.progress
        final.currentTitle = nil
        await onProgress(final)
        return result
    }

    /// 拉某部剧的各季。返回成功拉取的季数。
    ///
    /// 季号来自**已落库的剧实体**（`entity.seasons`），而不是再问服务端要一遍剧集列表：
    /// 我们刚刚已经把它拉下来了，TMDb 的季列表与 Jellyfin 的季是对应的（季号即
    /// `IndexNumber`，特别篇为 0）。
    private func enrichSeasons(ofSeries item: MediaItem, tenant: TenantID) async -> Int {
        let language = preferences.language
        guard let link = try? await store.tmdbLink(itemID: item.id, tenant: tenant),
              case .tv(let tvID) = link.entityKey,
              let cached = try? await store.tmdbPayload(key: link.entityKey, language: language),
              case .entity(let entity) = cached.payload
        else { return 0 }

        var fetched = 0
        for season in entity.seasons {
            if Task.isCancelled { break }
            // 已有且未过期的季直接跳过（与条目同样靠数据库判断，天然可续）。
            let key = TMDbEntityKey.season(tvID: tvID, number: season.seasonNumber)
            if let seasonCached = try? await store.tmdbPayload(key: key, language: language),
               !seasonCached.isExpired() {
                continue
            }
            if await fetchAndStore(key: key, language: language) { fetched += 1 }
        }
        return fetched
    }
}

// MARK: - 手动匹配

extension TMDbEnricher {

    /// 手动匹配用的候选搜索。**会抛错**（与自动补全不同）：这里是用户主动发起的操作，
    /// 失败必须让他知道（「没搜到」与「搜索失败」是两回事）。
    public func searchCandidates(
        query: String,
        mediaType: TMDbMediaType,
        year: Int? = nil
    ) async throws -> [TMDbSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await client.search(query: trimmed, mediaType: mediaType,
                                       year: year, language: preferences.language)
    }

    /// 手动绑定一个条目到指定实体（`source: .manual`，**不会被自动匹配覆盖**）。
    ///
    /// 绑定后立刻拉数据：用户点了「用这个」之后应当马上看到结果，而不是等下次进详情页。
    /// 拉取失败不回滚绑定——用户的选择是事实，数据可以下次再补。
    @discardableResult
    public func bindManually(
        itemID: String,
        entityKey: TMDbEntityKey,
        tenant: TenantID
    ) async -> Bool {
        try? await store.saveTMDbLink(itemID: itemID, entityKey: entityKey,
                                      source: .manual, confidence: 1.0, tenant: tenant)
        return await fetchAndStore(key: entityKey)
    }

    /// 解除一个条目的对应（用户「取消匹配」）。顺带清掉不再被引用的实体。
    public func unbind(itemID: String, tenant: TenantID) async {
        try? await store.removeTMDbLink(itemID: itemID, tenant: tenant)
    }

    /// 某条目当前的对应（手动面板要显示「已匹配到 XXX」）。
    public func link(for itemID: String, tenant: TenantID) async -> TMDbLink? {
        try? await store.tmdbLink(itemID: itemID, tenant: tenant)
    }
}
