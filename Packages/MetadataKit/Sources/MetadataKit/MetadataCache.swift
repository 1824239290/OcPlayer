import Foundation
import GRDB

/// `MetadataKit` 对 App 层的公开入口。
///
/// App 层只需要三件事：**开库、量体积、删库**。建库细节（迁移、损坏自愈、
/// WAL 配置）与存储实现（`MetadataStore` 的 SQL）都不该漏出去——漏了就等于
/// 让两个模块共同维护同一份内部约定。
public enum MetadataCache {

    /// 在给定数据根目录开库（必要时迁移 / 损坏重建）。
    ///
    /// - Parameter directory: 数据根目录（`Application Support/OcPlayer`）。
    /// - Throws: 删库重建**之后**仍失败时抛（磁盘满 / 权限），此时调用方应降级为
    ///   「没有缓存」而不是崩掉。
    public static func open(at directory: URL) throws -> MetadataStore {
        MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: directory))
    }

    /// 数据库占用（含 WAL / SHM）。
    ///
    /// WAL 会随写入增长：不算它的话设置页显示的体积会长期少报一大截。
    public static func sizeInBytes(at directory: URL) -> Int64 {
        MetadataDatabaseFactory.totalBytes(at: directory)
    }

    /// 删库（含 WAL / SHM）。设置页「清空」的最后一档，也是排障手段。
    public static func removeDatabase(at directory: URL) {
        MetadataDatabaseFactory.removeDatabaseFiles(at: directory)
    }
}
