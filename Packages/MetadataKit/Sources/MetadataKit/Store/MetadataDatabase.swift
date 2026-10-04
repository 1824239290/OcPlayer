import DiagnosticsKit
import Foundation
import GRDB

/// 本包的诊断日志入口（与 `PlaybackLog` 同款：包内自建 logger，
/// 不依赖 App 层的 `AppDiagnostics`）。
enum MetadataLog {
    static let logger = DiagnosticLogger(subsystem: "dev.jumusu.OcPlayer", category: "Metadata")
}

/// 建库 + 迁移 + 损坏自愈。
///
/// 与 `BangumiDatabaseFactory` 同形（`DatabasePool` + 逐连接 pragma + 具名迁移），
/// 不另发明一套：两个库都在同一个目录下、都被同一批人维护，形状一致才好读。
///
/// **损坏 / 迁移失败一律删库重建**：这是可重建的缓存，重建的代价是「下次多拉一遍」，
/// 而留着半坏的库会让每条读路径各自出错——比崩溃更难查。所以这里不向上抛错要求
/// 处理，而是自己恢复。
enum MetadataDatabaseFactory {

    /// 数据库文件名。**改它等于丢掉所有用户的缓存**（无迁移），别动。
    static let fileName = "Media.sqlite"

    /// 打开（必要时重建）数据库。
    ///
    /// - Parameter directory: 数据根目录（`Application Support/OcPlayer`）；
    ///   测试传临时目录。
    static func makeDatabase(at directory: URL) throws -> DatabasePool {
        do {
            return try openAndMigrate(at: directory)
        } catch {
            // 第一道：直接删库重来（WAL / SHM 一并删，否则残留的 WAL 会让新建的库
            // 立刻又不一致）。
            MetadataLog.logger.warning("媒体元数据库打开失败，删除重建", fields: [
                "error": .string("\(error)"),
            ])
            removeDatabaseFiles(at: directory)
            do {
                return try openAndMigrate(at: directory)
            } catch {
                // 第二道也失败：说明不是库本身的问题（磁盘满 / 权限）。
                // 这里**必须抛**——静默降级成「没有缓存」会让调用方以为缓存正常，
                // 而真正的原因（磁盘满）被一直藏着。
                MetadataLog.logger.error("媒体元数据库重建后仍失败", fields: [
                    "error": .string("\(error)"),
                ])
                throw error
            }
        }
    }

    private static func openAndMigrate(at directory: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent(fileName)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // 逐连接生效：Pool 的每条新连接都会跑一次。
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        // 缓存可以随时重建 → 打开后可安全回收磁盘。
        try? pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_size_limit = \(8 * 1024 * 1024)")
        }
        var migrator = DatabaseMigrator()
        // 不用 eraseDatabaseOnSchemaChange：那是开发期工具，会在迁移变更时**静默
        // 清空用户缓存**；这里的自愈路径是上面那条显式的删库重建。
        migrator.registerMigration("createMediaSchemaV1") { db in
            try db.execute(sql: Schema.createTables)
        }
        // v2 只**加表**、不动 v1 的任何列与数据——所以升级是纯增量的，老缓存全部有效。
        // （对比：若当初把 TMDb 字段塞进 `item` 表，这里就得重建表并搬数据。）
        migrator.registerMigration("addTMDbSchemaV2") { db in
            try db.execute(sql: Schema.createTMDbTables)
        }
        try migrator.migrate(pool)
        return pool
    }

    /// 删掉库文件与 WAL / SHM 附属文件（不存在时忽略）。
    static func removeDatabaseFiles(at directory: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(fileName + suffix)
            try? fm.removeItem(at: url)
        }
    }

    /// 数据库占用（含 WAL / SHM），供体积上报与淘汰判定。
    static func totalBytes(at directory: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent(fileName + suffix)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else { continue }
            total += size.int64Value
        }
        return total
    }
}
