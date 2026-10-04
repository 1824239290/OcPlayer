import Foundation
import GRDB

/// 落库的 TMDb 载荷。
///
/// 一个键只可能是这三者之一（`movie/…` → entity、`tv/…` → entity、
/// `tv/…/season/…` → season），所以用带关联值的枚举而不是「两个可空字段」——
/// 后者允许构造出「同时有 entity 和 season」这种不可能状态。
public enum TMDbEntityPayload: Codable, Equatable, Sendable {
    case entity(TMDbEntity)
    case season(TMDbSeason)

    public var kind: TMDbMediaType {
        switch self {
        case .entity(let entity): entity.mediaType
        case .season: .season
        }
    }

    /// 判断这份缓存是否还能支撑某个键的展示（防止 `tv/1` 的载荷被 `tv/2` 复用）。
    func matches(_ key: TMDbEntityKey) -> Bool {
        switch (self, key) {
        case (.entity(let entity), .movie(let id)): entity.id == id && entity.mediaType == .movie
        case (.entity(let entity), .tv(let id)): entity.id == id && entity.mediaType == .tv
        case (.season(let season), .season(_, let number)): season.seasonNumber == number
        default: false
        }
    }
}

/// 从库里读回来的一份 TMDb 数据。
/// `Sendable`：要从 `MetadataStore`（actor）跨边界交给 `TMDbEnricher`（也是 actor）。
public struct CachedTMDbPayload: Sendable {
    public var payload: TMDbEntityPayload
    public var fetchedAt: Date
    public var expiresAt: Date

    /// 是否已过缓存期。过期的数据**仍然可用**（比没有强），只是应触发一次回源。
    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

// MARK: - TMDb 存取

extension MetadataStore {

    /// 写一份 TMDb 数据。
    ///
    /// - Parameter lifetime: 缓存期。调用方应已按 TMDb 条款夹在 6 个月内
    ///   （见 `TMDbPreferences.maxCacheDays`），这里不重复判断——但也不允许为负。
    public func saveTMDbPayload(
        _ payload: TMDbEntityPayload,
        key: TMDbEntityKey,
        language: String,
        lifetime: TimeInterval,
        now: Date = Date()
    ) throws {
        guard let data = PayloadCodec.encode(payload) else { return }
        let fetched = Int64(now.timeIntervalSince1970)
        let expires = Int64(now.addingTimeInterval(max(0, lifetime)).timeIntervalSince1970)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tmdb_entity(entity_key, language, kind, tmdb_id, season_number,
                                            fetched_at, expires_at, payload_version, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(entity_key, language) DO UPDATE SET
                      kind = excluded.kind,
                      tmdb_id = excluded.tmdb_id,
                      season_number = excluded.season_number,
                      fetched_at = excluded.fetched_at,
                      expires_at = excluded.expires_at,
                      payload_version = excluded.payload_version,
                      payload = excluded.payload
                    """,
                arguments: [
                    key.storageKey, language, payload.kind.rawValue, key.tmdbID,
                    seasonNumber(of: key), fetched, expires, Schema.payloadVersion, data,
                ])
        }
    }

    /// 读一份 TMDb 数据。nil = 没缓存过 / 版本不认识 / 载荷与键不匹配（一律当未命中）。
    public func tmdbPayload(key: TMDbEntityKey, language: String) throws -> CachedTMDbPayload? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload_version, payload, fetched_at, expires_at
                    FROM tmdb_entity WHERE entity_key = ? AND language = ?
                    """,
                arguments: [key.storageKey, language]),
                let data = row["payload"] as Data?,
                let payload = PayloadCodec.decode(TMDbEntityPayload.self, from: data,
                                                  storedVersion: row["payload_version"]),
                payload.matches(key)
            else { return nil }
            return CachedTMDbPayload(
                payload: payload,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int64)),
                expiresAt: Date(timeIntervalSince1970: TimeInterval(row["expires_at"] as Int64)))
        }
    }

    private func seasonNumber(of key: TMDbEntityKey) -> Int? {
        if case .season(_, let number) = key { return number }
        return nil
    }

    // MARK: - 对应关系（link）

    /// 建立/更新「服务端条目 → TMDb 实体」的对应。
    ///
    /// **不会覆盖权威来源**由调用方判断（见 `link(itemID:tenant:)` 的注释）——
    /// 这里只管写，语义判断收在匹配器里，避免两处各判一遍。
    public func saveTMDbLink(
        itemID: String,
        entityKey: TMDbEntityKey,
        source: TMDbLinkSource,
        confidence: Double,
        tenant: TenantID,
        now: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tmdb_link(tenant_id, item_id, entity_key, source, confidence, linked_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(tenant_id, item_id) DO UPDATE SET
                      entity_key = excluded.entity_key,
                      source = excluded.source,
                      confidence = excluded.confidence,
                      linked_at = excluded.linked_at
                    """,
                arguments: [tenant.rawValue, itemID, entityKey.storageKey, source.rawValue,
                            confidence, Int64(now.timeIntervalSince1970)])
        }
    }

    /// 公开版：App 层要拿它做「这条目对应到哪了」的展示与手动匹配（Phase 3）。
    ///
    /// 与包内的实现分开命名（`public` 的那个转发）是因为包内调用点已经用短名字
    /// 写了一片，改名会波及所有测试；而对外暴露一个 `public` 版本是必要的。
    public func linkedTMDbEntity(itemID: String, tenant: TenantID) throws -> TMDbLink? {
        try tmdbLink(itemID: itemID, tenant: tenant)
    }

    func tmdbLink(itemID: String, tenant: TenantID) throws -> TMDbLink? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT entity_key, source, confidence, linked_at FROM tmdb_link
                    WHERE tenant_id = ? AND item_id = ?
                    """,
                arguments: [tenant.rawValue, itemID]),
                let rawKey = row["entity_key"] as String?,
                let key = TMDbEntityKey(storageKey: rawKey),
                let rawSource = row["source"] as String?,
                let source = TMDbLinkSource(rawValue: rawSource)
            else { return nil }
            return TMDbLink(
                itemID: itemID,
                entityKey: key,
                source: source,
                confidence: row["confidence"] as Double? ?? 0,
                linkedAt: Date(timeIntervalSince1970: TimeInterval(row["linked_at"] as Int64)))
        }
    }

    /// 删掉某条目的对应（重新匹配前先清）。
    public func removeTMDbLink(itemID: String, tenant: TenantID) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM tmdb_link WHERE tenant_id = ? AND item_id = ?",
                arguments: [tenant.rawValue, itemID])
        }
    }

    /// 某租户下已建立多少条对应（设置页显示「已补全 N 部」用）。
    public func tmdbLinkCount(tenant: TenantID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tmdb_link WHERE tenant_id = ?",
                arguments: [tenant.rawValue]) ?? 0
        }
    }

    /// 清掉过期的实体数据。**不是必须的**：读路径本来就按 `expires_at` 判断回源，
    /// 这里只是把没人再用的死数据还给用户（挂在每日存储维护上）。
    ///
    /// 边界用 `<=` 与 `CachedTMDbPayload.isExpired(now:)` 的 `now >= expiresAt` 对齐：
    /// 两处若一个新一个严格，恰好在到期那一刻会出现「读过期数据却不肯删」的
    /// 自相矛盾（本用例第一版就是这么失败的）。
    @discardableResult
    public func evictExpiredTMDbEntities(now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM tmdb_entity WHERE expires_at <= ?",
                arguments: [Int64(now.timeIntervalSince1970)])
            return db.changesCount
        }
    }

    /// 清掉某租户的全部对应关系与孤儿实体（设置页「清除 TMDb 补全数据」）。
    ///
    /// 顺序有讲究：先删 link 再删实体。反过来的话，`tmdb_entity` 会因为
    /// 还有 link 指着而被 `NOT EXISTS` 保住——用户以为清了，实际数据还在。
    public func clearTMDbData(tenant: TenantID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM tmdb_link WHERE tenant_id = ?",
                           arguments: [tenant.rawValue])
            try db.execute(sql: """
                DELETE FROM tmdb_entity WHERE NOT EXISTS (
                  SELECT 1 FROM tmdb_link WHERE tmdb_link.entity_key = tmdb_entity.entity_key
                )
                """)
        }
    }
}
