import Foundation
import GRDB

/// 建库 + 迁移。只建进度/收藏/章节需要的核心表（subjects / episodes），
/// 不背 Bangumi-iOS 的完整 schema（字符/人物/小组/草稿等本次不移植）。
enum BangumiDatabaseFactory {
    /// 数据库文件：Application Support/OcPlayer/Bangumi.sqlite
    static func makeDatabase(at directory: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Bangumi.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createBangumiSchemaV1") { db in
            try createSubjects(in: db)
            try createEpisodes(in: db)
        }
        // 记录每个条目最后一次拉章节的时间。没有它的话，「本篇数 < 总集数」这个补齐判据
        // 会让「eps 元数据比实际登记集数多」的条目每次刷新都白拉一遍，永远补不齐。
        migrator.registerMigration("addEpisodesSyncedAt") { db in
            try db.execute(
                sql: "ALTER TABLE subjects ADD COLUMN episodes_synced_at INTEGER NOT NULL DEFAULT 0")
        }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    private static func createSubjects(in db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE subjects(
                  subject_id INTEGER PRIMARY KEY,
                  airtime_data BLOB,
                  collection_data BLOB,
                  eps INTEGER,
                  images_data BLOB,
                  infobox_data BLOB,
                  locked INTEGER,
                  meta_tags_data BLOB,
                  tags_data BLOB,
                  name TEXT,
                  name_cn TEXT,
                  nsfw INTEGER,
                  platform_data BLOB,
                  rating_data BLOB,
                  series INTEGER,
                  summary TEXT,
                  type INTEGER,
                  volumes INTEGER,
                  info TEXT,
                  alias TEXT,
                  ctype INTEGER,
                  collected_at INTEGER,
                  interest_data BLOB
                )
                """)
        try db.execute(
            sql: "CREATE INDEX subjects_collection_idx ON subjects(type, ctype, collected_at DESC)")
        try db.execute(sql: "CREATE INDEX subjects_ctype_idx ON subjects(ctype)")
    }

    private static func createEpisodes(in db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE episodes(
                  episode_id INTEGER PRIMARY KEY,
                  subject_id INTEGER,
                  type INTEGER,
                  sort REAL,
                  name TEXT,
                  name_cn TEXT,
                  duration TEXT,
                  airdate TEXT,
                  comment INTEGER,
                  disc INTEGER,
                  desc TEXT,
                  status INTEGER,
                  collected_at INTEGER
                )
                """)
        try db.execute(
            sql: "CREATE INDEX episodes_subject_idx ON episodes(subject_id, type, sort)")
        try db.execute(
            sql: "CREATE INDEX episodes_progress_idx ON episodes(subject_id, type, status, sort)")
    }
}
