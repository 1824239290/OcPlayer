import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import MetadataKit

/// 建库 / 迁移 / 损坏自愈。
struct MetadataDatabaseTests {

    @Test func createsDatabaseAndSchema() async throws {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let tables = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["item", "library", "media_file_info", "page", "rail", "tenant"] {
            #expect(tables.contains(expected), "缺表 \(expected)")
        }
        // 外键 pragma 逐连接生效（照 BangumiDatabaseFactory）。
        let foreignKeys = try await pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1
        }
        #expect(foreignKeys == 1)
    }

    /// 同一个目录重复打开必须复用（不能每次建新库、把缓存丢掉）。
    @Test func reopensExistingDatabase() async throws {
        let dir = try TemporaryDirectory()
        let tenant = TenantID(rawValue: "srv:user")
        do {
            let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
            let store = MetadataStore(database: pool)
            try await store.saveItems([makeItem(id: "a", name: "A")], tenant: tenant)
        }
        let pool2 = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store2 = MetadataStore(database: pool2)
        let restored = try await store2.item("a", tenant: tenant)
        #expect(restored?.item.name == "A")
    }

    /// 库文件被写成垃圾时必须**删库重建**而不是抛错（缓存可重建，崩掉不可接受）。
    @Test func corruptDatabaseIsRebuilt() async throws {
        let dir = try TemporaryDirectory()
        let tenant = TenantID(rawValue: "srv:user")
        // 先建一个正常库，再把它替换成垃圾内容。
        _ = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let dbURL = dir.url.appendingPathComponent(MetadataDatabaseFactory.fileName)
        try Data("this is not a sqlite database".utf8).write(to: dbURL)
        // WAL / SHM 也留成垃圾，确认重建会把它们一并清掉。
        try Data("stale wal".utf8).write(to: URL(fileURLWithPath: dbURL.path + "-wal"))

        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store = MetadataStore(database: pool)
        // 重建后的库是可用的（能写能读），旧内容自然没了。
        try await store.saveItems([makeItem(id: "fresh", name: "Fresh")], tenant: tenant)
        let fresh = try await store.item("fresh", tenant: tenant)
        #expect(fresh?.item.name == "Fresh")
    }
}
