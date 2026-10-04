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

    /// `internal`（不是 `private`）：TMDb 的读写放在 `MetadataStore+TMDb.swift` 扩展里，
    /// 跨文件访问需要 ≥ internal。对外仍是 `public actor` 封装，不泄露给使用方。
    let database: DatabasePool

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
                      let library = try? JSONDecoder().decode(MediaLibrary.self, from: data)
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
