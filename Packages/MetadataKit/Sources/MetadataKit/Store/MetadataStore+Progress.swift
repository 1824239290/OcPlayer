import CoreModel
import Foundation
import GRDB

extension MetadataStore {
    /// rail/page 只保存列表投影；item 表是进度事实源。同一读事务内批量合并，
    /// 保留投影的排序、元数据与时间戳，不让旧 JSON 把已写入的进度带回内存。
    static func projectionPlayStates(
        _ db: Database, itemIDs: [MediaItem.ID], tenant: TenantID
    ) throws -> [MediaItem.ID: MediaItem.PlayState] {
        let ids = Array(Set(itemIDs))
        var states: [MediaItem.ID: MediaItem.PlayState] = [:]
        // 留出 tenant 参数的位置，也兼容 SQLite 旧版本的 999 个绑定参数上限。
        for start in stride(from: 0, to: ids.count, by: 900) {
            let batch = Array(ids[start..<min(start + 900, ids.count)])
            let placeholders = Array(repeating: "(?)", count: batch.count).joined(separator: ",")
            let rows = try Row.fetchAll(db,
                sql: """
                    WITH requested(item_id) AS (VALUES \(placeholders)), scope AS (SELECT ? AS tenant_id)
                    SELECT requested.item_id,
                           COALESCE(i.payload_version, p.payload_version) AS payload_version,
                           COALESCE(i.payload, p.payload) AS payload
                    FROM requested CROSS JOIN scope
                    LEFT JOIN item i ON i.tenant_id = scope.tenant_id AND i.item_id = requested.item_id
                    LEFT JOIN local_progress p ON p.tenant_id = scope.tenant_id AND p.item_id = requested.item_id
                    """,
                arguments: StatementArguments(batch + [tenant.rawValue]))
            for row in rows {
                guard let data = row["payload"] as Data?,
                      let item = PayloadCodec.decode(MediaItem.self, from: data,
                                                    storedVersion: row["payload_version"]),
                      let state = item.playState else { continue }
                states[row["item_id"] as String] = state
            }
        }
        return states
    }

    static func mergingProgress(
        _ items: [MediaItem], states: [MediaItem.ID: MediaItem.PlayState]
    ) -> [MediaItem] {
        items.map { item in
            guard let state = states[item.id] else { return item }
            var updated = item
            updated.playState = state
            return updated
        }
    }
}

/// 服务端 API 没有进度版本号：本地末次位置保持到一次后发请求读到相同位置，
/// 或用户显式标记已看/未看。确认之前发出的请求仍受保护，允许主动回退播放位置。
struct LocalPlaybackProgress: Sendable {
    let revision = UUID()
    var item: MediaItem
    var recordedAt: Date
    var confirmedAt: Date?
    var completed = false

    static func isComplete(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position >= max(0, duration - 2)
    }

    var confirmedCompletion: Bool {
        completed && confirmedAt != nil && item.playState?.played == true
            && item.playState?.positionSeconds == 0
    }

    func protects(requestStartedAt: Date) -> Bool {
        confirmedAt.map { requestStartedAt <= $0 } ?? true
    }

    mutating func observe(_ remote: MediaItem, requestStartedAt: Date, now: Date) {
        guard confirmedAt == nil, requestStartedAt >= recordedAt,
              let local = item.playState, let remote = remote.playState else { return }
        let samePosition = local.played == remote.played
            && abs(local.positionSeconds - remote.positionSeconds) < 1
        // 播完后服务端可能标记已看并把续播位置清零，这是有效确认。
        let finished = completed && remote.played
        guard samePosition || finished else { return }
        if finished { item.playState = remote }
        confirmedAt = now
    }

}

extension MetadataStore {
    /// 可淘汰 item 缺失时，独立进度仍是已看/未看状态的事实源。
    static func localProgressState(
        _ db: Database, itemID: MediaItem.ID, tenant: TenantID
    ) throws -> MediaItem.PlayState? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT payload_version, payload FROM local_progress
            WHERE tenant_id = ? AND item_id = ?
            """, arguments: [tenant.rawValue, itemID]),
              let payload = row["payload"] as Data? else { return nil }
        return PayloadCodec.decode(MediaItem.self, from: payload, storedVersion: row["payload_version"])?.playState
    }

    /// 不同 actor 的写入可能排队换序；捕获时间较旧的末次写入不能盖过新的显式操作。
    static func newerProgressState(
        _ db: Database, itemID: MediaItem.ID, tenant: TenantID, recordedAt: Date
    ) throws -> MediaItem.PlayState? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT recorded_at, payload_version, payload FROM local_progress
            WHERE tenant_id = ? AND item_id = ?
            """, arguments: [tenant.rawValue, itemID]),
              (row["recorded_at"] as Double) > recordedAt.timeIntervalSince1970,
              let payload = row["payload"] as Data? else { return nil }
        return PayloadCodec.decode(MediaItem.self, from: payload, storedVersion: row["payload_version"])?.playState
    }

    static func saveProgressRecord(
        _ db: Database, item: MediaItem, tenant: TenantID,
        recordedAt: Date, confirmedAt: Date?, completed: Bool
    ) throws {
        guard let payload = PayloadCodec.encode(item) else { return }
        try db.execute(sql: """
            INSERT INTO local_progress(tenant_id, item_id, recorded_at, confirmed_at, completed, payload_version, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(tenant_id, item_id) DO UPDATE SET
              recorded_at = excluded.recorded_at, confirmed_at = excluded.confirmed_at,
              completed = excluded.completed, payload_version = excluded.payload_version, payload = excluded.payload
            """, arguments: [tenant.rawValue, item.id, recordedAt.timeIntervalSince1970,
                             confirmedAt?.timeIntervalSince1970, completed, Schema.payloadVersion, payload])
    }

    /// 确认后的条目可正常淘汰，只留下轻量的进度与请求边界；未确认记录保留完整条目。
    static func compactEvictedProgress(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.tenant_id, p.payload_version, p.payload
            FROM local_progress p
            WHERE p.confirmed_at IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM item i WHERE i.tenant_id = p.tenant_id AND i.item_id = p.item_id)
            """)
        for row in rows {
            guard let payload = row["payload"] as Data?,
                  let item = PayloadCodec.decode(MediaItem.self, from: payload, storedVersion: row["payload_version"]),
                  let compact = PayloadCodec.encode(MediaItem(id: item.id, name: item.name, kind: item.kind,
                                                               playState: item.playState)), compact != payload else { continue }
            try db.execute(sql: "UPDATE local_progress SET payload = ? WHERE tenant_id = ? AND item_id = ?",
                           arguments: [compact, row["tenant_id"] as String, item.id])
        }
    }

    static func reconcileIncomingItems(
        _ db: Database, items: [MediaItem], rail: String?, tenant: TenantID,
        requestStartedAt: Date, now: Date
    ) throws -> [MediaItem] {
        // 只查询本地播放过的少量条目，不对每张列表卡片发一次查询。
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.item_id, p.recorded_at, p.confirmed_at, p.completed, p.payload_version, p.payload,
                   i.payload AS canonical_payload, i.payload_version AS canonical_version
            FROM local_progress p LEFT JOIN item i ON p.tenant_id = i.tenant_id AND p.item_id = i.item_id
            WHERE p.tenant_id = ?
            """, arguments: [tenant.rawValue])
        var pending: [MediaItem.ID: LocalPlaybackProgress] = [:]
        for row in rows {
            guard let data = row["payload"] as Data?,
                  let item = PayloadCodec.decode(MediaItem.self, from: data, storedVersion: row["payload_version"])
            else { continue }
            var metadata = (row["canonical_payload"] as Data?).flatMap {
                PayloadCodec.decode(MediaItem.self, from: $0, storedVersion: row["canonical_version"])
            } ?? item
            metadata.playState = item.playState
            pending[item.id] = LocalPlaybackProgress(
                item: metadata, recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double),
                confirmedAt: (row["confirmed_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                completed: row["completed"] as Bool)
        }
        var merged = items
        for index in merged.indices {
            let remote = merged[index]
            guard var progress = pending[remote.id] else { continue }
            progress.observe(remote, requestStartedAt: requestStartedAt, now: now)
            if progress.protects(requestStartedAt: requestStartedAt) {
                merged[index].playState = progress.item.playState
            }
            // 保存最新元数据与最终采用的状态。item 被淘汰后，保护记录仍能独立合并。
            progress.item = merged[index]
            try saveProgressRecord(db, item: progress.item, tenant: tenant, recordedAt: progress.recordedAt,
                                   confirmedAt: progress.confirmedAt, completed: progress.completed)
            pending[remote.id] = progress
        }
        if rail == "resume" {
            merged.removeAll { pending[$0.id]?.confirmedCompletion == true }
            var ids = Set(merged.map(\.id))
            let missing = pending.values.filter {
                $0.protects(requestStartedAt: requestStartedAt) && $0.item.playState?.played == false
                    && ($0.item.playState?.positionSeconds ?? 0) > 0 && !ids.contains($0.item.id)
            }.sorted { $0.recordedAt > $1.recordedAt }
            for progress in missing where ids.insert(progress.item.id).inserted {
                merged.append(progress.item)
            }
        }
        return merged
    }
}
