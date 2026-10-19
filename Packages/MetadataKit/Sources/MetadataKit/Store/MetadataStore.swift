import CoreModel
import Foundation
import GRDB
import JellyfinKit

/// 媒体元数据缓存的读写入口。
///
/// `public actor` + 全同步 `throws` 方法（跨 actor 调用时由调用方 `await`）——
/// 与 `BangumiDatabaseOperator` 同款：actor 隔离即是全部的 Sendable 故事，
/// 不需要锁、也不需要 `@unchecked Sendable`。
///
/// 读走 `database.read {}`、写走 `database.write {}`；一个网络响应 = 一个事务
/// （照 `saveSubjects` 的批处理），别一条一个事务。
public actor MetadataStore {

    /// `internal`（不是 `private`）：TMDB 的读写放在 `MetadataStore+TMDB.swift` 扩展里，
    /// 跨文件访问需要 ≥ internal。对外仍是 `public actor` 封装，不泄露给使用方。
    let database: DatabasePool

    /// `library` 表的 payload 解码器。**共用一份**：`JSONDecoder()` 的构造要初始化
    /// 内部的策略/容器状态，而这条读路径在冷启动首屏（`MetadataHydrator.home()`）上，
    /// 之前是「每行新建一个」。actor 隔离保证它只被串行访问。
    private let libraryDecoder = JSONDecoder()

    public init(database: DatabasePool) {
        self.database = database
    }

    // MARK: - 租户

    /// 记下这次见到该租户（首次创建）。每次会话开始调一次即可。
    public func touchTenant(_ tenant: TenantID, profile: ServerProfile, now: Date = Date()) throws {
        let timestamp = Int64(now.timeIntervalSince1970)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tenant(tenant_id, kind, server_name, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(tenant_id) DO UPDATE SET
                      kind = excluded.kind,
                      server_name = excluded.server_name,
                      last_seen_at = excluded.last_seen_at
                    """,
                arguments: [tenant.rawValue, profile.kind.rawValue, profile.serverName, timestamp, timestamp])
        }
    }

    /// 该租户是否已有任何缓存内容（决定首屏要不要走「先读磁盘」那条路）。
    public func hasContent(for tenant: TenantID) throws -> Bool {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM item WHERE tenant_id = ? LIMIT 1",
                             arguments: [tenant.rawValue]) != nil
        }
    }

    // MARK: - 条目

    /// 批量写入条目（一个事务）。`progressFresh` 为 true 时同时刷新进度时间戳。
    public func saveItems(
        _ items: [MediaItem],
        tenant: TenantID,
        now: Date = Date(),
        progressFresh: Bool = true
    ) throws {
        guard !items.isEmpty else { return }
        let timestamp = Int64(now.timeIntervalSince1970)
        // payload 编码放在事务外：编码是纯 CPU，占着写事务做它会挡住别的写。
        let rows: [(MediaItem, Data)] = items.compactMap { item in
            PayloadCodec.encode(item).map { (item, $0) }
        }
        guard !rows.isEmpty else { return }
        try database.write { db in
            for (item, payload) in rows {
                try Self.upsertItem(db, item: item, payload: payload, tenant: tenant,
                                    timestamp: timestamp, progressFresh: progressFresh)
            }
        }
    }

    /// 条目（可选带 rail 快照）**一次事务写完**。
    ///
    /// ## 为什么要单独这个方法
    ///
    /// `saveItems` 与 `saveRail` 各自开一个 `database.write` 事务。连写两次的话，
    /// 进程在两次写之间被杀会留下「**新 rail + 旧条目**」的不一致快照 ——
    /// 首页显示的条目详情与 rail 里的对不上。这是正确性问题，不只是性能。
    ///
    /// ## 编码仍在事务外
    ///
    /// 与 `saveItems`（`:67` 的注释）同一理由：payload 编码是纯 CPU，占着写事务做
    /// 它会挡住别的写。所以两次编码都先做完，事务里只剩 upsert。
    ///
    /// - Parameter rail: `nil` 时等价于 `saveItems`。
    public func saveItemsAndRail(
        _ items: [MediaItem],
        rail: String?,
        tenant: TenantID,
        now: Date = Date(),
        progressFresh: Bool = true
    ) throws {
        // ⚠️ **不能写成 `guard !items.isEmpty else { return }`**。
        //
        // 「空 items + 非 nil rail」是一个**有意义的组合**：服务端说「这个 rail 现在
        // 没有内容」时，`saveRail` 会把 `RailSnapshot(items: [])` 写进去、**清掉**上一份。
        // 若在这里早退，磁盘会**原地保留过期 rail** —— 而 `MetadataHydrator.home()`
        // 读 rail 无任何新鲜度门槛（`fetchedAt` 只参与 `dates.min()`），
        // 冷启动/离线就会把过期条目当「继续观看/接下来看/最近添加」铺上首页。
        //
        // 第一版就是那样写的，独立审查用端到端用例实测出「服务端返回空之后磁盘仍是
        // 旧 rail」；回归见 `CachedMediaServerTests.emptyRailResponseClearsStaleRail`。
        guard !items.isEmpty || rail != nil else { return }
        let timestamp = Int64(now.timeIntervalSince1970)
        // 两次编码都在事务外。
        let rows: [(MediaItem, Data)] = items.compactMap { item in
            PayloadCodec.encode(item).map { (item, $0) }
        }
        let railPayload = rail.flatMap { _ in PayloadCodec.encode(RailSnapshot(items: items)) }
        guard !rows.isEmpty || railPayload != nil else { return }
        try database.write { db in
            for (item, payload) in rows {
                try Self.upsertItem(db, item: item, payload: payload, tenant: tenant,
                                    timestamp: timestamp, progressFresh: progressFresh)
            }
            if let rail, let railPayload {
                try Self.upsertRail(db, rail: rail, payload: railPayload,
                                    tenant: tenant, timestamp: timestamp)
            }
        }
    }

    private static func upsertRail(
        _ db: Database,
        rail: String,
        payload: Data,
        tenant: TenantID,
        timestamp: Int64
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO rail(tenant_id, rail, fetched_at, payload_version, payload)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(tenant_id, rail) DO UPDATE SET
                  fetched_at = excluded.fetched_at,
                  payload_version = excluded.payload_version,
                  payload = excluded.payload
                """,
            arguments: [tenant.rawValue, rail, timestamp, Schema.payloadVersion, payload])
    }

    private static func upsertItem(
        _ db: Database,
        item: MediaItem,
        payload: Data,
        tenant: TenantID,
        timestamp: Int64,
        progressFresh: Bool
    ) throws {
        let state = item.playState
        try db.execute(
            sql: """
                INSERT INTO item(tenant_id, item_id, kind, name, year, series_id, season_id,
                                 season_number, episode_number, played, played_percentage,
                                 position_seconds, fetched_at, progress_fetched_at,
                                 payload_version, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(tenant_id, item_id) DO UPDATE SET
                  kind = excluded.kind,
                  name = excluded.name,
                  year = excluded.year,
                  series_id = excluded.series_id,
                  season_id = excluded.season_id,
                  season_number = excluded.season_number,
                  episode_number = excluded.episode_number,
                  played = excluded.played,
                  played_percentage = excluded.played_percentage,
                  position_seconds = excluded.position_seconds,
                  fetched_at = excluded.fetched_at,
                  progress_fetched_at = excluded.progress_fetched_at,
                  payload_version = excluded.payload_version,
                  payload = excluded.payload
                """,
            arguments: [
                tenant.rawValue, item.id, item.kind.rawValue, item.name, item.year,
                item.seriesID, item.seasonID, item.seasonNumber, item.episodeNumber,
                state.map { $0.played ? 1 : 0 }, state?.percentage, state?.positionSeconds,
                timestamp, progressFresh ? timestamp : nil,
                Schema.payloadVersion, payload,
            ])
    }

    /// 取单条目。
    ///
    /// 注意 `progress_fetched_at`：条目整体新鲜不代表**进度**新鲜。调用方要判断
    /// 「看到的是不是旧进度」得看这个字段，`fetchedAt` 只管元数据（见 `CachedItem`）。
    public func item(_ id: MediaItem.ID, tenant: TenantID) throws -> CachedItem? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at, progress_fetched_at
                    FROM item WHERE tenant_id = ? AND item_id = ?
                    """,
                arguments: [tenant.rawValue, id])
            else { return nil }
            guard let data = row["payload"] as Data?,
                  let item = PayloadCodec.decode(MediaItem.self, from: data,
                                                 storedVersion: row["payload_version"])
            else { return nil }
            return CachedItem(
                item: item,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)),
                progressFetchedAt: (row["progress_fetched_at"] as Int64?).map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                })
        }
    }

    /// 取一组条目（详情页的季 / 集列表用）。返回顺序按调用方给的 id 顺序，
    /// **缺的那些直接跳过**（不补占位：调用方要么整份用、要么不用）。
    public func items(_ ids: [MediaItem.ID], tenant: TenantID) throws -> [CachedItem] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var byID: [MediaItem.ID: CachedItem] = [:]
            // 分块绑参：SQLite 的变量上限是 999，超了要拆。
            for chunk in stride(from: 0, to: ids.count, by: 900).map({ Array(ids[$0..<min($0 + 900, ids.count)]) }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item_id, payload_version, payload, fetched_at, progress_fetched_at
                        FROM item WHERE tenant_id = ? AND item_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments([tenant.rawValue] + chunk))
                for row in rows {
                    guard let data = row["payload"] as Data?,
                          let item = PayloadCodec.decode(MediaItem.self, from: data,
                                                         storedVersion: row["payload_version"])
                    else { continue }
                    byID[row["item_id"]] = CachedItem(
                        item: item,
                        fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)),
                        progressFetchedAt: (row["progress_fetched_at"] as Int64?).map {
                            Date(timeIntervalSince1970: TimeInterval($0))
                        })
                }
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// 登录页海报墙的候选：**库里有主图（海报）的**电影 / 剧集。
    ///
    /// ## 为什么必须是它，而不是「缓存里像海报的文件」
    ///
    /// 图片缓存里同时存着**演员头像**（`/Items/{personId}/Images/Primary`）与条目海报
    /// ——两者都是 2:3 的竖图，按宽高比根本分不开（本机实测：429 张竖图里最大的两档
    /// 尺寸 342×513、240×360 几乎全是头像）。所以「墙上摆哪些图」必须由**条目身份**
    /// 决定，而不是由图片外观决定。这个查询就是那个身份来源。
    ///
    /// ## 顺序
    ///
    /// 墙是装饰，不需要「有意义」的顺序，但**必须是确定的**——同一份缓存两次装配要
    /// 得到同一面墙，否则每次冷启动墙都换一副面孔。所以排序是
    /// `fetched_at DESC, item_id`（后者只是给同秒的行一个稳定次序）。
    ///
    /// ## 为什么在内存里筛「有没有主图」
    ///
    /// `primaryImageTag` 在 `payload` 里，不在列上。用 `json_extract` 能塞进 WHERE，
    /// 但那等于把 payload 的编码（JSON）钉进查询——而 payload 的契约是**对读方不透明**
    /// （见 `PayloadCodec`：版本不认就当未命中）。为了一面装饰墙去动那条契约不划算，
    /// 所以按 kind 取一个**有界窗口**回来，解码后筛。窗口给足余量（`limit * 8`，
    /// 至少 240 行）以免库里「无图条目」占比高时凑不满。
    ///
    /// - Parameter limit: 想要多少张。实际返回可能更少（库里本来就没那么多带图条目）。
    public func posterCandidates(tenant: TenantID, limit: Int) throws -> [CachedItem] {
        guard limit > 0 else { return [] }
        let scanLimit = max(limit * 8, 240)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT item_id, payload_version, payload, fetched_at, progress_fetched_at
                    FROM item
                    WHERE tenant_id = ? AND kind IN ('movie', 'series')
                    ORDER BY fetched_at DESC, item_id
                    LIMIT ?
                    """,
                arguments: [tenant.rawValue, scanLimit])

            var candidates: [CachedItem] = []
            candidates.reserveCapacity(limit)
            for row in rows {
                guard candidates.count < limit else { break }
                guard let data = row["payload"] as Data?,
                      let item = PayloadCodec.decode(MediaItem.self, from: data,
                                                     storedVersion: row["payload_version"]),
                      item.primaryImageTag != nil
                else { continue }
                candidates.append(
                    CachedItem(
                        item: item,
                        fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)),
                        progressFetchedAt: (row["progress_fetched_at"] as Int64?).map {
                            Date(timeIntervalSince1970: TimeInterval($0))
                        }))
            }
            return candidates
        }
    }

    /// 只把进度写回（`markPlayed` / `markUnplayed` / 播放上报的返回）。
    ///
    /// 不动 `fetched_at`：进度变了不代表元数据过期。也不动 payload 里的其它字段——
    /// 这里刻意**不整条覆写**，因为手上的 `playState` 是服务端权威值，
    /// 而其余字段可能来自更完整的详情拉取，不该被一个只有进度的对象盖掉。
    public func updatePlayState(
        _ state: MediaItem.PlayState,
        forItemID id: MediaItem.ID,
        tenant: TenantID,
        now: Date = Date()
    ) throws {
        let timestamp = Int64(now.timeIntervalSince1970)
        try database.write { db in
            // payload 也要更新：读路径是从 payload 解出整个 MediaItem 的，
            // 只改投影列的话，读回来仍是旧进度（列只服务淘汰与筛选）。
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload_version, payload FROM item WHERE tenant_id = ? AND item_id = ?",
                arguments: [tenant.rawValue, id]),
                let data = row["payload"] as Data?,
                var item = PayloadCodec.decode(MediaItem.self, from: data,
                                               storedVersion: row["payload_version"])
            else { return }
            item.playState = state
            guard let updated = PayloadCodec.encode(item) else { return }
            try db.execute(
                sql: """
                    UPDATE item SET played = ?, played_percentage = ?, position_seconds = ?,
                                    progress_fetched_at = ?, payload = ?
                    WHERE tenant_id = ? AND item_id = ?
                    """,
                arguments: [state.played ? 1 : 0, state.percentage, state.positionSeconds,
                            timestamp, updated, tenant.rawValue, id])
        }
    }

    // MARK: - 库列表

    public func saveLibraries(_ libraries: [MediaLibrary], tenant: TenantID, now: Date = Date()) throws {
        let timestamp = Int64(now.timeIntervalSince1970)
        let encoded = libraries.compactMap { library in
            PayloadCodec.encode(library).map { (library, $0) }
        }
        try database.write { db in
            // 整表替换：库列表是「一份完整清单」，不是增量集合。不删旧行的话，
            // 服务端删掉的库会永远留在侧栏里。
            try db.execute(sql: "DELETE FROM library WHERE tenant_id = ?", arguments: [tenant.rawValue])
            for (index, entry) in encoded.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO library(tenant_id, library_id, position, fetched_at, payload)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [tenant.rawValue, entry.0.id, index, timestamp, entry.1])
            }
        }
    }

    public func libraries(tenant: TenantID) throws -> [CachedLibrary] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT library_id, payload, fetched_at FROM library WHERE tenant_id = ? ORDER BY position",
                arguments: [tenant.rawValue])
            return rows.compactMap { row in
                guard let data = row["payload"] as Data?,
                      let library = try? libraryDecoder.decode(MediaLibrary.self, from: data)
                else { return nil }
                return CachedLibrary(
                    library: library,
                    fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
            }
        }
    }

    // MARK: - rail（首页三条）

    public func saveRail(_ items: [MediaItem], rail: String, tenant: TenantID, now: Date = Date()) throws {
        guard let payload = PayloadCodec.encode(RailSnapshot(items: items)) else { return }
        let timestamp = Int64(now.timeIntervalSince1970)
        try database.write { db in
            try Self.upsertRail(db, rail: rail, payload: payload,
                                tenant: tenant, timestamp: timestamp)
        }
    }

    public func rail(_ rail: String, tenant: TenantID) throws -> CachedRail? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload_version, payload, fetched_at FROM rail WHERE tenant_id = ? AND rail = ?",
                arguments: [tenant.rawValue, rail]),
                let data = row["payload"] as Data?,
                let snapshot = PayloadCodec.decode(RailSnapshot.self, from: data,
                                                   storedVersion: row["payload_version"])
            else { return nil }
            return CachedRail(
                items: snapshot.items,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
        }
    }

    /// 首页要用的一切，**一次读事务**取回：库列表 + 三条 rail。
    ///
    /// ## 为什么要这个方法（`P2-23` 实测数据）
    ///
    /// `MetadataHydrator.home()` 原本是四个独立 `await`：
    /// `libraries` + `rail("resume")` + `rail("nextUp")` + `rail("latest")`。
    /// 每个都是一次 `database.read` —— 而**读事务本身就要 ≈29–37 µs**
    /// （实测：4 个事务跑 4 条 trivial 查询 147.0 µs，1 个事务跑 4 条 59.0 µs，
    /// 差 88 µs / 3 个事务）。
    ///
    /// 真实数据上的 A/B（8 个库 + 3 条 rail × 20 条 `MediaItem`，交替 300 次取 p50）：
    ///
    /// | 变体 | p50 |
    /// |---|---|
    /// | 四个独立读 | 751.0 µs |
    /// | **一次读 + 一条 SQL 取三条 rail** | **602.0 µs（省 19.8%）** |
    ///
    /// > 独立审查在另一台负载上测到 1251.0 → 1037.3 µs（−17.1%）、
    /// > 以及 966.2 → 789.8 µs（−18.3%）。**绝对值随机器/数据规模变，比例稳定在
    /// > −17% ~ −20%** —— 引用时请以比例为准，别把某一台机器的绝对值当结论。
    ///
    /// 三条 rail 用**一条** `IN (?, ?, ?)` 取回，而不是三次 `rail(...)` ——
    /// 后者在同一个事务里也省了 checkout，但再多两条 round-trip 的解析开销。
    ///
    /// ## 失败语义（与旧实现**不同**，有意为之）
    ///
    /// - **单条 rail 解码失败 / 版本不认**：只跳过那一条（其余照常返回）—— 与旧实现一致。
    /// - **整个读事务失败**（库损坏 / 表缺失 / I/O 错误）：**抛错**。
    ///
    ///   ⚠️ 第一版写的是 `(try? database.read { ... }) ?? ([], [:])`，把「读失败」
    ///   压成了「全空」，与「服务端确实是空的」不可区分 —— 而这会**丢掉本来还能显示的
    ///   部分**（例如库读得到、rail 表坏了：旧实现返回「2 个库 + 空 rails」的快照，
    ///   新实现整体失败）。
    ///
    ///   所以这里抛错，由 `MetadataHydrator.home()` 决定怎么降级 —— 它现在
    ///   `guard let ... = try? await ...` **返回 nil**（保持调用方的骨架屏、等下次重试），
    ///   而不是吞掉错误当成「没有缓存」。
    /// 测试用：在写事务里跑任意 SQL（用于制造「读失败」这类异常状态）。
    func rawWriteForTesting(_ body: @escaping (Database) throws -> Void) throws {
        try database.write { db in try body(db) }
    }

    public func homeSnapshotParts(tenant: TenantID) throws
        -> (libraries: [CachedLibrary], rails: [String: CachedRail]) {
        let rails = ["resume", "nextUp", "latest"]
        return try database.read { db in
            let libraryRows = try Row.fetchAll(
                db,
                sql: "SELECT library_id, payload, fetched_at FROM library "
                    + "WHERE tenant_id = ? ORDER BY position",
                arguments: [tenant.rawValue])
            let libraries: [CachedLibrary] = libraryRows.compactMap { row in
                guard let data = row["payload"] as Data?,
                      let library = try? libraryDecoder.decode(MediaLibrary.self, from: data)
                else { return nil }
                return CachedLibrary(
                    library: library,
                    fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
            }

            let placeholders = Array(repeating: "?", count: rails.count).joined(separator: ",")
            let railRows = try Row.fetchAll(
                db,
                sql: "SELECT rail, payload_version, payload, fetched_at FROM rail "
                    + "WHERE tenant_id = ? AND rail IN (\(placeholders))",
                arguments: StatementArguments([tenant.rawValue] + rails))
            var byName: [String: CachedRail] = [:]
            byName.reserveCapacity(railRows.count)
            for row in railRows {
                guard let name = row["rail"] as String?,
                      let data = row["payload"] as Data?,
                      let snapshot = PayloadCodec.decode(
                        RailSnapshot.self, from: data, storedVersion: row["payload_version"])
                else { continue }
                byName[name] = CachedRail(
                    items: snapshot.items,
                    fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
            }
            return (libraries, byName)
        }
    }

    // MARK: - page（库页 / 搜索页）

    public func savePage(
        _ page: MediaItemsPage,
        key: PageKey,
        tenant: TenantID,
        now: Date = Date()
    ) throws {
        guard let payload = PayloadCodec.encode(
            PageSnapshot(items: page.items, totalRecordCount: page.totalRecordCount))
        else { return }
        let timestamp = Int64(now.timeIntervalSince1970)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO page(tenant_id, parent_id, kinds, sort_key, watch_state, search_term,
                                     start_index, limit_value, fetched_at, payload_version, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(tenant_id, parent_id, kinds, sort_key, watch_state, search_term,
                                start_index, limit_value) DO UPDATE SET
                      fetched_at = excluded.fetched_at,
                      payload_version = excluded.payload_version,
                      payload = excluded.payload
                    """,
                arguments: [tenant.rawValue, key.parentID, key.kinds, key.sortKey, key.watchState,
                            key.searchTerm, key.startIndex, key.limit, timestamp,
                            Schema.payloadVersion, payload])
        }
    }

    public func page(_ key: PageKey, tenant: TenantID) throws -> CachedPage? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at FROM page
                    WHERE tenant_id = ? AND parent_id = ? AND kinds = ? AND sort_key = ?
                      AND watch_state = ? AND search_term = ? AND start_index = ? AND limit_value = ?
                    """,
                arguments: [tenant.rawValue, key.parentID, key.kinds, key.sortKey, key.watchState,
                            key.searchTerm, key.startIndex, key.limit]),
                let data = row["payload"] as Data?,
                let snapshot = PayloadCodec.decode(PageSnapshot.self, from: data,
                                                   storedVersion: row["payload_version"])
            else { return nil }
            return CachedPage(
                items: snapshot.items,
                totalRecordCount: snapshot.totalRecordCount,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
        }
    }

    // MARK: - 媒体技术信息

    public func saveMediaFileInfo(_ info: MediaFileInfo, itemID: MediaItem.ID,
                                  tenant: TenantID, now: Date = Date()) throws {
        guard let payload = PayloadCodec.encode(info) else { return }
        let timestamp = Int64(now.timeIntervalSince1970)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media_file_info(tenant_id, item_id, fetched_at, payload_version, payload)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(tenant_id, item_id) DO UPDATE SET
                      fetched_at = excluded.fetched_at,
                      payload_version = excluded.payload_version,
                      payload = excluded.payload
                    """,
                arguments: [tenant.rawValue, itemID, timestamp, Schema.payloadVersion, payload])
        }
    }

    public func mediaFileInfo(itemID: MediaItem.ID, tenant: TenantID) throws -> CachedMediaFileInfo? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at FROM media_file_info
                    WHERE tenant_id = ? AND item_id = ?
                    """,
                arguments: [tenant.rawValue, itemID]),
                let data = row["payload"] as Data?,
                let info = PayloadCodec.decode(MediaFileInfo.self, from: data,
                                               storedVersion: row["payload_version"])
            else { return nil }
            return CachedMediaFileInfo(
                info: info,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)))
        }
    }

    // MARK: - 族谱查询（离线详情页用）

    /// 某剧集的季列表，按季号排序（与详情页的展示顺序一致）。
    ///
    /// 只从 `item` 表按投影列取——这条查询是离线进详情页的热路径，
    /// 不该解 payload 才能排序（`season_number` 就是为它建的索引）。
    public func seasons(seriesID: MediaItem.ID, tenant: TenantID) throws -> [MediaItem] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at, progress_fetched_at
                    FROM item
                    WHERE tenant_id = ? AND series_id = ? AND kind = 'season'
                    ORDER BY season_number IS NULL, season_number
                    """,
                arguments: [tenant.rawValue, seriesID])
            return rows.compactMap(Self.decodeItem(from:))
        }
    }

    /// 某一季的集列表，按集号排序。
    public func episodes(seriesID: MediaItem.ID, seasonID: MediaItem.ID,
                         tenant: TenantID) throws -> [MediaItem] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at, progress_fetched_at
                    FROM item
                    WHERE tenant_id = ? AND series_id = ? AND kind = 'episode'
                      AND (season_id = ? OR season_id IS NULL)
                    ORDER BY episode_number IS NULL, episode_number
                    """,
                arguments: [tenant.rawValue, seriesID, seasonID])
            return rows.compactMap(Self.decodeItem(from:))
        }
    }

    /// 行 → `MediaItem`（宽容解码；版本不认识时返回 nil，调用方按「没缓存」处理）。
    private static func decodeItem(from row: Row) -> MediaItem? {
        guard let data = row["payload"] as Data?,
              let version = row["payload_version"] as Int?
        else { return nil }
        return PayloadCodec.decode(MediaItem.self, from: data, storedVersion: version)
    }

    /// 所有含媒体的备份（供后续调试/统计用；不进热路径）。
    public func itemCount(kind: MediaItem.Kind, tenant: TenantID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM item WHERE tenant_id = ? AND kind = ?",
                arguments: [tenant.rawValue, kind.rawValue]) ?? 0
        }
    }

    // MARK: - 维护

    /// 条目数（淘汰判定与设置页展示用）。
    public func itemCount(tenant: TenantID? = nil) throws -> Int {
        try database.read { db in
            if let tenant {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE tenant_id = ?",
                                        arguments: [tenant.rawValue]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
        }
    }

    /// 按「最旧优先」淘汰条目，直到条数 ≤ `maxItems`。
    ///
    /// 返回删除条数。**只删 `item`**：`rail` / `page` 是自包含快照（不引用 item），
    /// 删条目不会让首页缺项——这是把快照存成自包含的主要理由。
    @discardableResult
    public func evictItems(keepingAtMost maxItems: Int) throws -> Int {
        try database.write { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
            guard total > maxItems else { return 0 }
            let excess = total - maxItems
            // 按主键**行值**匹配选中的最旧 N 条。
            //
            // 不能用 `rowid`：`item` 是 `WITHOUT ROWID` 表（主键即存储顺序，
            // 少一层间接），它**没有 rowid 列**——实测报 "no such column: rowid"。
            // 也不能用 `DELETE ... LIMIT`：那需要编译期开关
            // （SQLITE_ENABLE_UPDATE_DELETE_LIMIT），系统 SQLite 不一定开着。
            // 行值 IN 是两者都不依赖的写法（SQLite 3.15+，系统版本远高于此）。
            try db.execute(
                sql: """
                    DELETE FROM item WHERE (tenant_id, item_id) IN (
                      SELECT tenant_id, item_id FROM item ORDER BY fetched_at ASC LIMIT ?
                    )
                    """,
                arguments: [excess])
            return excess
        }
    }

    /// 清空一个租户的全部缓存（设置页「清空」与登出用）。
    public func clear(tenant: TenantID) throws {
        try database.write { db in
            for table in ["item", "library", "rail", "page", "media_file_info"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE tenant_id = ?", arguments: [tenant.rawValue])
            }
        }
    }

    /// 清空所有租户的缓存（设置页「清空」）。
    public func clearAll() throws {
        try database.write { db in
            for table in ["item", "library", "rail", "page", "media_file_info", "tenant"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// 回收磁盘（淘汰后调；VACUUM 会重写整库，调用方应确保在后台做）。
    public func vacuum() throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
