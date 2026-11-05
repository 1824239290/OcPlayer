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
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try Row.fetchAll(db,
                sql: "SELECT item_id, payload_version, payload FROM item WHERE tenant_id = ? AND item_id IN (\(placeholders))",
                arguments: StatementArguments([tenant.rawValue] + batch))
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
