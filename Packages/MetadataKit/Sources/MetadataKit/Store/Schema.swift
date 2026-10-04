import Foundation

/// 媒体元数据缓存的 DDL。
///
/// ## 两个设计点
///
/// **投影列 + JSON payload 双轨**：列只放「要按它查询」的东西（族谱、已看、
/// 淘汰用时间戳），payload 放整个 `MediaItem`。逐个字段建列等于以后每加一个
/// `MediaItem` 字段就要写一次迁移——而那个类型已经 35 个字段且还在长。
///
/// **`rail` / `page` 存自包含快照，不存 item_id 列表**：若存 id 列表再 join
/// `item`，条目一旦被淘汰，「继续观看」这类 rail 就会**静默缺项**（列表里
/// 有个查不到的 id），表现为首页凭空少几张卡。自包含快照不会。代价是同一部
/// 片子有几份 payload（3 条 rail × ≤24 条 ≈ 100–200 KB），可忽略。
enum Schema {

    /// payload 的编码版本。**只在语义不兼容时 bump**：加字段靠宽容解码
    /// （缺字段 → 默认值）自动兼容，不需要动它。读到不认识的版本 = 当未命中，
    /// 重拉覆盖，不迁移、不抛错。
    static let payloadVersion = 1

    static let createTables = """
        CREATE TABLE tenant(
          tenant_id     TEXT PRIMARY KEY,
          kind          TEXT NOT NULL,
          server_name   TEXT,
          first_seen_at INTEGER NOT NULL,
          last_seen_at  INTEGER NOT NULL
        );

        CREATE TABLE item(
          tenant_id           TEXT NOT NULL,
          item_id             TEXT NOT NULL,
          kind                TEXT NOT NULL,
          name                TEXT,
          year                INTEGER,
          series_id           TEXT,
          season_id           TEXT,
          season_number       INTEGER,
          episode_number      INTEGER,
          played              INTEGER,
          played_percentage   REAL,
          position_seconds    REAL,
          fetched_at          INTEGER NOT NULL,
          progress_fetched_at INTEGER,
          payload_version     INTEGER NOT NULL,
          payload             BLOB NOT NULL,
          PRIMARY KEY(tenant_id, item_id)
        ) WITHOUT ROWID;
        CREATE INDEX item_series   ON item(tenant_id, series_id, season_number, episode_number);
        CREATE INDEX item_season   ON item(tenant_id, season_id, episode_number);
        CREATE INDEX item_fetched  ON item(tenant_id, fetched_at);
        CREATE INDEX item_progress ON item(tenant_id, progress_fetched_at);

        CREATE TABLE library(
          tenant_id  TEXT NOT NULL,
          library_id TEXT NOT NULL,
          position   INTEGER NOT NULL,
          fetched_at INTEGER NOT NULL,
          payload    BLOB NOT NULL,
          PRIMARY KEY(tenant_id, library_id)
        );

        CREATE TABLE rail(
          tenant_id        TEXT NOT NULL,
          rail             TEXT NOT NULL,
          fetched_at       INTEGER NOT NULL,
          payload_version  INTEGER NOT NULL,
          payload          BLOB NOT NULL,
          PRIMARY KEY(tenant_id, rail)
        );

        CREATE TABLE page(
          tenant_id        TEXT NOT NULL,
          parent_id        TEXT NOT NULL DEFAULT '',
          kinds            TEXT NOT NULL DEFAULT '',
          sort_key         TEXT NOT NULL DEFAULT '',
          watch_state      TEXT NOT NULL DEFAULT '',
          search_term      TEXT NOT NULL DEFAULT '',
          start_index      INTEGER NOT NULL,
          limit_value      INTEGER NOT NULL,
          fetched_at       INTEGER NOT NULL,
          payload_version  INTEGER NOT NULL,
          payload          BLOB NOT NULL,
          PRIMARY KEY(tenant_id, parent_id, kinds, sort_key, watch_state, search_term,
                      start_index, limit_value)
        );

        CREATE TABLE media_file_info(
          tenant_id        TEXT NOT NULL,
          item_id          TEXT NOT NULL,
          fetched_at       INTEGER NOT NULL,
          payload_version  INTEGER NOT NULL,
          payload          BLOB NOT NULL,
          PRIMARY KEY(tenant_id, item_id)
        );
        """

    /// v2：TMDb 补全。
    ///
    /// ## 两张表为什么要分开
    ///
    /// `tmdb_entity` 存 **TMDb 侧的数据**，`tmdb_link` 存 **「服务端条目 → TMDb 实体」
    /// 的对应关系**。两者生命周期完全不同：
    ///
    /// - 实体数据是**全局的、与服务器无关**（同一部电影对谁都一样），所以它**不带
    ///   `tenant_id`** —— 两个服务器档案、两个 Jellyfin 用户共用一份，省一次请求。
    ///   唯一让它分叉的是**语言**（`zh-CN` 与 `en-US` 的简介不同），所以语言进主键。
    /// - 对应关系是**每台服务器各自的**（条目 id 是服务端生成的），必须带 `tenant_id`。
    ///
    /// 分开的另一个好处：解绑/重匹配只动 link，不必丢掉已经拉下来的实体数据。
    static let createTMDbTables = """
        CREATE TABLE tmdb_entity(
          entity_key      TEXT NOT NULL,
          language        TEXT NOT NULL,
          kind            TEXT NOT NULL,
          tmdb_id         INTEGER NOT NULL,
          season_number   INTEGER,
          fetched_at      INTEGER NOT NULL,
          expires_at      INTEGER NOT NULL,
          payload_version INTEGER NOT NULL,
          payload         BLOB NOT NULL,
          PRIMARY KEY(entity_key, language)
        );
        CREATE INDEX tmdb_entity_expiry ON tmdb_entity(expires_at);

        CREATE TABLE tmdb_link(
          tenant_id   TEXT NOT NULL,
          item_id     TEXT NOT NULL,
          entity_key  TEXT NOT NULL,
          source      TEXT NOT NULL,
          confidence  REAL NOT NULL,
          linked_at   INTEGER NOT NULL,
          PRIMARY KEY(tenant_id, item_id)
        );
        CREATE INDEX tmdb_link_entity ON tmdb_link(tenant_id, entity_key);
        """
}
