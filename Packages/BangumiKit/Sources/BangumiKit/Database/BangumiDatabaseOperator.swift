import Foundation
import GRDB

/// 排序模式（进度页）。
public enum BangumiProgressSortMode: Sendable {
    case collectedAt
    case airTime
}

/// 本地数据库操作层：进度/收藏/章节的读写都在这里，通过 read/write 包裹。
public actor BangumiDatabaseOperator {
    private let database: DatabasePool

    public init(database: DatabasePool) {
        self.database = database
    }

    // MARK: - 进度

    /// 进度页分页查询（在看条目 + 近期章节窗口）。
    public func fetchProgressSubjects(
        progressTab: BangumiSubjectType,
        sortMode: BangumiProgressSortMode,
        search: String,
        episodeWindowSize: Int,
        limit: Int,
        offset: Int
    ) throws -> BangumiPagedDTO<BangumiProgressSubject> {
        try database.read { db in
            let subjects: [BangumiSubject]
            let total: Int
            if sortMode == .collectedAt {
                let filter = progressSubjectFilter(progressTab: progressTab, search: search)
                total = try countSubjects(
                    in: db, whereSQL: filter.sql, arguments: filter.arguments)
                subjects = try fetchSubjects(
                    in: db,
                    whereSQL: filter.sql,
                    arguments: filter.arguments,
                    orderSQL: "collected_at DESC",
                    limit: limit,
                    offset: offset
                )
            } else {
                // airTime 排序：全量取 id 再按页切，保持分页稳定。
                let subjectIds = try fetchProgressSubjectIds(
                    in: db, progressTab: progressTab, search: search, sortMode: sortMode)
                let pageIds = Array(subjectIds.dropFirst(offset).prefix(limit))
                let byId = try fetchSubjectsById(in: db, pageIds)
                subjects = pageIds.compactMap { byId[$0] }
                total = subjectIds.count
            }
            let items = try makeProgressSubjects(
                in: db, subjects, episodeWindowSize: episodeWindowSize)
            return BangumiPagedDTO(data: items, total: total)
        }
    }

    /// 单条目进度（详情页章节区块用）。
    public func fetchProgressSubject(
        subjectId: Int, episodeWindowSize: Int
    ) throws -> BangumiProgressSubject? {
        try database.read { db in
            guard let subject = try fetchSubject(in: db, id: subjectId) else { return nil }
            return try makeProgressSubjects(
                in: db, [subject], episodeWindowSize: episodeWindowSize
            ).first
        }
    }

    /// 各进度 tab 的计数（在看条目数）。
    public func fetchProgressCounts() throws -> [BangumiSubjectType: Int] {
        try database.read { db in
            var counts: [BangumiSubjectType: Int] = [:]
            for type in BangumiSubjectType.progressTypes {
                let filter = progressSubjectFilter(progressTab: type, search: "")
                counts[type] = try countSubjects(
                    in: db, whereSQL: filter.sql, arguments: filter.arguments)
            }
            return counts
        }
    }

    // MARK: - 收藏列表

    public func fetchCollectionCounts(
        subjectType: BangumiSubjectType
    ) throws -> [BangumiCollectionType: Int] {
        try database.read { db in
            // 一条 GROUP BY 出全部类型计数，替代逐类型 9 趟 COUNT 扫描。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT ctype, COUNT(*) AS n FROM subjects WHERE type = ? GROUP BY ctype",
                arguments: [subjectType.rawValue]
            )
            var counts: [BangumiCollectionType: Int] = [:]
            for row in rows {
                if let type = BangumiCollectionType(rawValue: row["ctype"]) {
                    counts[type] = row["n"]
                }
            }
            return counts
        }
    }

    public func fetchCollectionSubjects(
        subjectType: BangumiSubjectType,
        collectionType: BangumiCollectionType,
        limit: Int,
        offset: Int
    ) throws -> [BangumiSubjectDTO] {
        try database.read { db in
            try fetchSubjects(
                in: db,
                whereSQL: "ctype = ? AND type = ?",
                arguments: [collectionType.rawValue, subjectType.rawValue],
                orderSQL: "collected_at DESC",
                limit: limit,
                offset: offset
            ).map(\.dto)
        }
    }

    // MARK: - 章节

    public func fetchEpisodes(
        subjectId: Int,
        main: Bool? = nil,
        uncollectedOnly: Bool = false,
        sortDesc: Bool = false,
        limit: Int? = nil
    ) throws -> [BangumiEpisodeDTO] {
        try database.read { db in
            var clauses = ["subject_id = ?"]
            var arguments: StatementArguments = [subjectId]
            if let main {
                if main {
                    clauses.append("type = ?")
                    arguments += [BangumiEpisodeType.main.rawValue]
                } else {
                    clauses.append("type != ?")
                    arguments += [BangumiEpisodeType.main.rawValue]
                }
            }
            if uncollectedOnly {
                clauses.append("status = 0")
            }
            var sql = """
                SELECT * FROM episodes
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY sort \(sortDesc ? "DESC" : "ASC")
                """
            if let limit {
                sql += " LIMIT ?"
                arguments += [limit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                BangumiEpisode(row: $0).dto
            }
        }
    }

    public func fetchEpisodeCounts(subjectId: Int) throws -> (main: Int, other: Int) {
        try database.read { db in
            let main = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM episodes WHERE subject_id = ? AND type = ?",
                arguments: [subjectId, BangumiEpisodeType.main.rawValue]
            ) ?? 0
            let other = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM episodes WHERE subject_id = ? AND type != ?",
                arguments: [subjectId, BangumiEpisodeType.main.rawValue]
            ) ?? 0
            return (main: main, other: other)
        }
    }

    /// 单集状态更新。batch=true 时把该集及之前所有本篇都标记为看过。
    /// 返回所属 subjectId（nil 表示条目不在本地）。
    @discardableResult
    public func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) throws -> Int? {
        try database.write { db in
            let now = Int(Date().timeIntervalSince1970) - 1
            guard let episode = try fetchEpisode(in: db, id: episodeId) else { return nil }
            let subjectId = episode.subjectId
            guard let subject = try fetchSubject(in: db, id: subjectId) else { return nil }

            if batch {
                try db.execute(
                    sql: """
                        UPDATE episodes
                        SET status = ?, collected_at = ?
                        WHERE subject_id = ? AND sort <= ? AND type = ?
                        """,
                    arguments: [
                        BangumiEpisodeCollectionType.collect.rawValue,
                        now,
                        subjectId,
                        episode.sort,
                        BangumiEpisodeType.main.rawValue,
                    ]
                )
                // 已看数要数「全部标为看过的本篇」，不能用 rows.count：
                // 那只是 ≤ 本集的集数，会把用户先前标过的后面几集抹掉。
                subject.interest?.epStatus = try countCollectedMainEpisodes(in: db, subjectId: subjectId)
            } else {
                episode.status = type.rawValue
                episode.collectedAt = now
                try upsertEpisode(episode, in: db)
                if episode.typeEnum == .main {
                    // 同样重新数一遍，而不是在旧值上加减：本地章节要么整份齐（loadEpisodes
                    // 是全量替换）要么没有，数出来的值就是准的，也不会因为漏掉一次事件而漂。
                    subject.interest?.epStatus = try countCollectedMainEpisodes(
                        in: db, subjectId: subjectId)
                }
            }
            subject.interest?.updatedAt = now
            subject.collectedAt = now
            try upsertSubject(subject, in: db)
            return subjectId
        }
    }

    // MARK: - 保存

    /// 只改条目级收藏状态（想看/在看/看过…），不动章节。
    public func updateSubjectCollectionType(
        subjectId: Int, type: BangumiCollectionType
    ) throws {
        try database.write { db in
            guard let subject = try fetchSubject(in: db, id: subjectId) else { return }
            let now = Int(Date().timeIntervalSince1970) - 1
            // 收藏状态挂在 interest 上；行级 type 是作品类型（动画/书籍…），别动。
            if var interest = subject.interest {
                interest.type = type
                interest.updatedAt = now
                subject.interest = interest
            } else {
                subject.interest = BangumiSubjectInterest(
                    comment: "",
                    epStatus: 0,
                    volStatus: 0,
                    private: false,
                    rate: 0,
                    tags: [],
                    type: type,
                    updatedAt: now
                )
            }
            subject.ctype = type.rawValue
            subject.collectedAt = now
            try upsertSubject(subject, in: db)
        }
    }

    /// 只改用户对条目的评分（1-10，0 表示撤销评分）。
    public func updateSubjectRating(
        subjectId: Int, rate: Int
    ) throws {
        try database.write { db in
            guard let subject = try fetchSubject(in: db, id: subjectId) else { return }
            let now = Int(Date().timeIntervalSince1970)
            if var interest = subject.interest {
                interest.rate = rate
                interest.updatedAt = now
                subject.interest = interest
            } else {
                subject.interest = BangumiSubjectInterest(
                    comment: "",
                    epStatus: 0,
                    volStatus: 0,
                    private: false,
                    rate: rate,
                    tags: [],
                    type: .collect,
                    updatedAt: now
                )
                subject.ctype = BangumiCollectionType.collect.rawValue
            }
            subject.collectedAt = now
            try upsertSubject(subject, in: db)
        }
    }

    public func saveEpisodes(subjectId: Int, items: [BangumiEpisodeDTO]) throws {
        try database.write { db in
            var subjectRef = try fetchSubject(in: db, id: subjectId)
            if subjectRef == nil, let slim = items.first?.subject {
                let (ensured, _) = try ensureSubject(slim, in: db)
                try upsertSubject(ensured, in: db)
                subjectRef = ensured
            } else if let subjectRef, let slim = items.first?.subject {
                subjectRef.update(slim)
                try upsertSubject(subjectRef, in: db)
            }

            let existingEpisodes = try fetchEpisodes(in: db, subjectId: subjectId)
            let existingMap = Dictionary(uniqueKeysWithValues: existingEpisodes.map { ($0.episodeId, $0) })

            for item in items {
                let episode: BangumiEpisode
                if let existing = existingMap[item.id] {
                    existing.update(item)
                    episode = existing
                } else {
                    episode = BangumiEpisode(item)
                }
                try upsertEpisode(episode, in: db)
            }
            // 空结果也要盖时间戳：远端确实没登记章节的条目，否则每次刷新都白拉一遍。
            try db.execute(
                sql: "UPDATE subjects SET episodes_synced_at = ? WHERE subject_id = ?",
                arguments: [Int(Date().timeIntervalSince1970), subjectId])
        }
    }

    /// 删除本地不在远端集合里的章节（远端删除后清理）。
    /// NOT IN 的占位符逐批 ≤900（SQLite 变量上限 999）：超长剧集一口气传会撞上限。
    public func deleteEpisodesNotIn(subjectId: Int, episodeIds: Set<Int>) throws {
        try database.write { db in
            if episodeIds.isEmpty {
                try db.execute(
                    sql: "DELETE FROM episodes WHERE subject_id = ?", arguments: [subjectId])
                return
            }
            let ids = Array(episodeIds)
            var start = 0
            while start < ids.count {
                let batch = ids[start..<min(start + 900, ids.count)]
                try db.execute(
                    sql: """
                        DELETE FROM episodes
                        WHERE subject_id = ? AND episode_id NOT IN (\(placeholders(batch.count)))
                        """,
                    arguments: StatementArguments([subjectId] + batch)
                )
                start += 900
            }
        }
    }

    @discardableResult
    public func saveSubject(_ item: BangumiSubjectDTO) throws -> Bool {
        try database.write { db in
            let (subject, created) = try ensureSubject(item, in: db)
            try upsertSubject(subject, in: db)
            return created
        }
    }

    /// 批量落库（收藏同步用）：一个事务写完整页，别一条一个事务。
    public func saveSubjects(_ items: [BangumiSubjectDTO]) throws {
        guard !items.isEmpty else { return }
        try database.write { db in
            for item in items {
                let (subject, _) = try ensureSubject(item, in: db)
                try upsertSubject(subject, in: db)
            }
        }
    }

    @discardableResult
    public func saveSubject(_ item: BangumiSlimSubjectDTO) throws -> Bool {
        try database.write { db in
            let (subject, created) = try ensureSubject(item, in: db)
            try upsertSubject(subject, in: db)
            return created
        }
    }

    /// 单条目读取。
    public func subject(id: Int) throws -> BangumiSubjectDTO? {
        try database.read { db in
            try fetchSubject(in: db, id: id)?.dto
        }
    }

    /// 批量读取（按 id）。日历页「本地收藏标记」一屏几十个条目，逐条 `subject(id:)`
    /// 是几十次 DB 往返；这里一条 `IN (...)` 查询取回来。
    public func subjects(ids: [Int]) throws -> [Int: BangumiSubjectDTO] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            try fetchSubjectsById(in: db, ids).mapValues { $0.dto }
        }
    }

    /// 清空账户相关数据（登出/换号时调用）。
    public func clearAccountLocalState() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM subjects")
            try db.execute(sql: "DELETE FROM episodes")
        }
    }

    // MARK: - 私有查询

    /// 一整页条目 → 进度条目（含章节窗口）。
    ///
    /// 章节**整页一条查询**取回来，窗口在内存里切。原来是每个条目 3 条 SQL
    /// （下一条未看 / 之前 N 条 / 之后 N 条），一页 100 条就是 300 条查询；
    /// 本篇集数量级是几十，取回来在内存切的成本可以忽略，而且取回的行数比原来更少
    /// （原来 windowSize 给 50 时三条查询各自 LIMIT 49，等于整季拉了两遍）。
    private func makeProgressSubjects(
        in db: Database, _ subjects: [BangumiSubject], episodeWindowSize: Int
    ) throws -> [BangumiProgressSubject] {
        // 只有动画 / 三次元要章节窗口，书籍等不铺章节格子。
        let needsEpisodes = subjects.filter {
            switch $0.typeEnum {
            case .anime, .real: return true
            default: return false
            }
        }
        let mainEpisodes = try fetchMainEpisodes(
            in: db, subjectIds: needsEpisodes.map(\.subjectId))
        return subjects.map { subject in
            let episodes = mainEpisodes[subject.subjectId].map {
                Self.progressWindow(in: $0, windowSize: episodeWindowSize).map(\.dto)
            } ?? []
            return BangumiProgressSubject(subject: subject.dto, episodes: episodes)
        }
    }

    /// 按 subjectId 批量取本篇章节，一条查询覆盖整页。返回值按 sort 升序。
    private func fetchMainEpisodes(
        in db: Database, subjectIds: [Int]
    ) throws -> [Int: [BangumiEpisode]] {
        guard !subjectIds.isEmpty else { return [:] }
        var arguments = StatementArguments(subjectIds)
        arguments += [BangumiEpisodeType.main.rawValue]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM episodes
                WHERE subject_id IN (\(placeholders(subjectIds.count))) AND type = ?
                ORDER BY subject_id ASC, sort ASC
                """,
            arguments: arguments
        )
        var grouped: [Int: [BangumiEpisode]] = [:]
        for row in rows {
            let episode = BangumiEpisode(row: row)
            grouped[episode.subjectId, default: []].append(episode)
        }
        return grouped
    }

    /// 以「下一条未看本篇」为中心的滑动窗口。`sorted` 必须按 `sort` 升序。
    ///
    /// 纯函数，不碰数据库——单条目和整页走同一份实现，行为不会分叉。
    /// 前后两侧按 `sort` 值切（而不是按下标），保持和原来 SQL
    /// `sort < ?` / `sort > ?` 完全一致：同 sort 的兄弟集两边都不算。
    static func progressWindow(
        in sorted: [BangumiEpisode], windowSize: Int
    ) -> [BangumiEpisode] {
        let windowSize = max(1, windowSize)
        guard !sorted.isEmpty else { return [] }
        guard let next = sorted.first(where: {
            $0.status == BangumiEpisodeCollectionType.none.rawValue
        }) else {
            // 一集未看的都没有 = 全看完：退回末尾若干集。
            return Array(sorted.suffix(windowSize))
        }

        let halfBefore = (windowSize - 1) / 2
        let halfAfter = windowSize - halfBefore - 1
        let pool = max(windowSize - 1, 0)
        let before = Array(sorted.filter { $0.sort < next.sort }.suffix(pool))
        let after = Array(sorted.filter { $0.sort > next.sort }.prefix(pool))

        let beforeCount: Int
        let afterCount: Int
        if before.count < halfBefore {
            beforeCount = before.count
            afterCount = min(after.count, windowSize - beforeCount - 1)
        } else if after.count < halfAfter {
            afterCount = after.count
            beforeCount = min(before.count, windowSize - afterCount - 1)
        } else {
            beforeCount = halfBefore
            afterCount = halfAfter
        }

        return before.suffix(beforeCount) + [next] + after.prefix(afterCount)
    }

    private func fetchProgressSubjectIds(
        in db: Database, progressTab: BangumiSubjectType, search: String,
        sortMode: BangumiProgressSortMode
    ) throws -> [Int] {
        let filter = progressSubjectFilter(progressTab: progressTab, search: search)
        guard sortMode == .airTime else {
            return try Int.fetchAll(
                db,
                sql: "SELECT subject_id FROM subjects WHERE \(filter.sql) ORDER BY collected_at DESC",
                arguments: filter.arguments
            )
        }
        // 放送时间排序：日期在 JSON BLOB 里，SQL 排不了，取出来在内存排。
        // 「在看」列表规模就是几十到几百条，代价可以忽略。
        // 日期是 yyyy-MM-dd，字符串逆序即时间逆序；无日期的条目排到最后，
        // 同日期按收藏时间（SQL 已排好）保持稳定。
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT subject_id, airtime_data FROM subjects
                WHERE \(filter.sql)
                ORDER BY collected_at DESC
                """,
            arguments: filter.arguments
        )
        let keyed = rows.enumerated().map { index, row -> (id: Int, date: String, order: Int) in
            let subjectID: Int = row["subject_id"]
            let airtime: BangumiSubjectAirtime? = row.jsonOptional("airtime_data")
            return (subjectID, airtime?.date ?? "", index)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.date.isEmpty != rhs.date.isEmpty { return rhs.date.isEmpty }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.order < rhs.order
        }.map(\.id)
    }

    /// 「在看」里本地章节还没补齐的条目（章节表里的本篇数少于条目声明的总集数）。
    /// 收藏同步只落条目，章节要另外拉；用它把要补的条目框出来，避免每次全量重拉。
    ///
    /// 从没拉过的（`episodes_synced_at = 0`）一定入选；拉过但仍然「不满」的，
    /// 隔 `retryInterval` 才再试一次——有些条目的 `eps` 元数据本来就比实际登记的集数大，
    /// 不设这道闸它们会每次刷新都白拉。
    public func fetchSubjectIDsMissingEpisodes(
        limit: Int = 200, retryInterval: TimeInterval = 6 * 3600
    ) throws -> [Int] {
        let staleBefore = Int(Date().timeIntervalSince1970 - retryInterval)
        return try database.read { db in
            try Int.fetchAll(
                db,
                sql: """
                    SELECT s.subject_id FROM subjects AS s
                    WHERE s.ctype = ?
                      AND s.type IN (?, ?)
                      AND (
                        SELECT COUNT(*) FROM episodes AS e
                        WHERE e.subject_id = s.subject_id AND e.type = ?
                      ) < MAX(COALESCE(s.eps, 0), 1)
                      AND (s.episodes_synced_at = 0 OR s.episodes_synced_at <= ?)
                    ORDER BY s.collected_at DESC
                    LIMIT ?
                    """,
                arguments: [
                    BangumiCollectionType.doing.rawValue,
                    BangumiSubjectType.anime.rawValue,
                    BangumiSubjectType.real.rawValue,
                    BangumiEpisodeType.main.rawValue,
                    staleBefore,
                    limit,
                ]
            )
        }
    }

    private func fetchSubjectsById(in db: Database, _ subjectIds: [Int]) throws -> [Int: BangumiSubject] {
        guard !subjectIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM subjects WHERE subject_id IN (\(placeholders(subjectIds.count)))",
            arguments: StatementArguments(subjectIds)
        )
        return Dictionary(
            uniqueKeysWithValues: rows.map { row in
                let subject = BangumiSubject(row: row)
                return (subject.subjectId, subject)
            })
    }

    private func fetchSubjects(
        in db: Database,
        whereSQL: String,
        arguments: StatementArguments,
        orderSQL: String?,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [BangumiSubject] {
        var sql = "SELECT * FROM subjects WHERE \(whereSQL)"
        if let orderSQL {
            sql += " ORDER BY \(orderSQL)"
        }
        var sqlArguments = arguments
        if let limit {
            sql += " LIMIT ?"
            sqlArguments += [limit]
        }
        if let offset {
            sql += " OFFSET ?"
            sqlArguments += [offset]
        }
        return try Row.fetchAll(db, sql: sql, arguments: sqlArguments)
            .map { BangumiSubject(row: $0) }
    }

    private func fetchSubject(in db: Database, id: Int) throws -> BangumiSubject? {
        try Row.fetchOne(db, sql: "SELECT * FROM subjects WHERE subject_id = ?", arguments: [id])
            .map { BangumiSubject(row: $0) }
    }

    private func fetchEpisode(in db: Database, id: Int) throws -> BangumiEpisode? {
        try Row.fetchOne(db, sql: "SELECT * FROM episodes WHERE episode_id = ?", arguments: [id])
            .map { BangumiEpisode(row: $0) }
    }

    private func fetchEpisodes(in db: Database, subjectId: Int) throws -> [BangumiEpisode] {
        try Row.fetchAll(db, sql: "SELECT * FROM episodes WHERE subject_id = ?", arguments: [subjectId])
            .map { BangumiEpisode(row: $0) }
    }

    /// 该条目已标「看过」的本篇集数（`interest.epStatus` 的本地事实源）。
    private func countCollectedMainEpisodes(in db: Database, subjectId: Int) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM episodes
                WHERE subject_id = ? AND type = ? AND status = ?
                """,
            arguments: [
                subjectId,
                BangumiEpisodeType.main.rawValue,
                BangumiEpisodeCollectionType.collect.rawValue,
            ]
        ) ?? 0
    }

    private func countSubjects(
        in db: Database, whereSQL: String, arguments: StatementArguments
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM subjects WHERE \(whereSQL)",
            arguments: arguments
        ) ?? 0
    }

    private func ensureSubject(
        _ item: BangumiSubjectDTO, in db: Database
    ) throws -> (BangumiSubject, Bool) {
        if let subject = try fetchSubject(in: db, id: item.id) {
            subject.update(item)
            return (subject, false)
        }
        return (BangumiSubject(item), true)
    }

    private func ensureSubject(
        _ item: BangumiSlimSubjectDTO, in db: Database
    ) throws -> (BangumiSubject, Bool) {
        if let subject = try fetchSubject(in: db, id: item.id) {
            subject.update(item)
            return (subject, false)
        }
        return (BangumiSubject(item), true)
    }

    // MARK: - upsert

    private func upsertSubject(_ subject: BangumiSubject, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO subjects(
                  subject_id, airtime_data, collection_data, eps, images_data, infobox_data,
                  locked, meta_tags_data, tags_data, name, name_cn, nsfw, platform_data,
                  rating_data, series, summary, type, volumes, info, alias, ctype,
                  collected_at, interest_data
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(subject_id) DO UPDATE SET
                  airtime_data = excluded.airtime_data,
                  collection_data = excluded.collection_data,
                  eps = excluded.eps,
                  images_data = excluded.images_data,
                  infobox_data = excluded.infobox_data,
                  locked = excluded.locked,
                  meta_tags_data = excluded.meta_tags_data,
                  tags_data = excluded.tags_data,
                  name = excluded.name,
                  name_cn = excluded.name_cn,
                  nsfw = excluded.nsfw,
                  platform_data = excluded.platform_data,
                  rating_data = excluded.rating_data,
                  series = excluded.series,
                  summary = excluded.summary,
                  type = excluded.type,
                  volumes = excluded.volumes,
                  info = excluded.info,
                  alias = excluded.alias,
                  ctype = excluded.ctype,
                  collected_at = excluded.collected_at,
                  interest_data = excluded.interest_data
                """,
            arguments: [
                subject.subjectId,
                BangumiRecordCoding.encode(subject.airtime),
                BangumiRecordCoding.encode(subject.collection),
                subject.eps,
                BangumiRecordCoding.encode(subject.images),
                BangumiRecordCoding.encode(subject.infobox),
                BangumiRecordCoding.bool(subject.locked),
                BangumiRecordCoding.encode(subject.metaTags),
                BangumiRecordCoding.encode(subject.tags),
                subject.name,
                subject.nameCN,
                BangumiRecordCoding.bool(subject.nsfw),
                BangumiRecordCoding.encode(subject.platform),
                BangumiRecordCoding.encode(subject.rating),
                BangumiRecordCoding.bool(subject.series),
                subject.summary,
                subject.type,
                subject.volumes,
                subject.info,
                subject.alias,
                subject.ctype,
                subject.collectedAt,
                BangumiRecordCoding.encode(subject.interest),
            ]
        )
    }

    private func upsertEpisode(_ episode: BangumiEpisode, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO episodes(
                  episode_id, subject_id, type, sort, name, name_cn, duration, airdate,
                  comment, disc, desc, status, collected_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(episode_id) DO UPDATE SET
                  subject_id = excluded.subject_id,
                  type = excluded.type,
                  sort = excluded.sort,
                  name = excluded.name,
                  name_cn = excluded.name_cn,
                  duration = excluded.duration,
                  airdate = excluded.airdate,
                  comment = excluded.comment,
                  disc = excluded.disc,
                  desc = excluded.desc,
                  status = excluded.status,
                  collected_at = excluded.collected_at
                """,
            arguments: [
                episode.episodeId,
                episode.subjectId,
                episode.type,
                episode.sort,
                episode.name,
                episode.nameCN,
                episode.duration,
                episode.airdate,
                episode.comment,
                episode.disc,
                episode.desc,
                episode.status,
                episode.collectedAt,
            ]
        )
    }

    private func progressSubjectFilter(
        progressTab: BangumiSubjectType, search: String
    ) -> (sql: String, arguments: StatementArguments) {
        var arguments: StatementArguments = [
            progressTab.rawValue,
            progressTab.rawValue,
            BangumiCollectionType.doing.rawValue,
        ]
        var sql = "(? = 0 OR type = ?) AND ctype = ?"
        if !search.isEmpty {
            // 原名和中文名都要搜；`alias` 列没有写入来源，恒为空串，不参与匹配。
            // ESCAPE '\\' 与 likePattern 的 \% \_ 转义配对：SQLite 默认没有转义符，
            // 不加的话含 %/_ 的关键词会被当通配符，搜索结果错误。
            sql += " AND (name LIKE ? ESCAPE '\\' COLLATE NOCASE OR name_cn LIKE ? ESCAPE '\\' COLLATE NOCASE)"
            let pattern = likePattern(search)
            arguments += [pattern, pattern]
        }
        return (sql, arguments)
    }

    private func likePattern(_ value: String) -> String {
        "%\(value.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

extension BangumiSubject {
    func update(_ item: BangumiSubjectDTO) {
        if airtime != item.airtime { airtime = item.airtime }
        if collection != item.collection { collection = item.collection }
        if eps != item.eps { eps = item.eps }
        if let images = item.images, self.images != images { self.images = images }
        if infobox != item.infobox { infobox = item.infobox }
        if info != item.info { info = item.info }
        if locked != item.locked { locked = item.locked }
        if metaTags != item.metaTags { metaTags = item.metaTags }
        if tags != item.tags { tags = item.tags }
        if name != item.name { name = item.name }
        if nameCN != item.nameCN { nameCN = item.nameCN }
        if nsfw != item.nsfw { nsfw = item.nsfw }
        if platform != item.platform { platform = item.platform }
        if rating != item.rating { rating = item.rating }
        if series != item.series { series = item.series }
        if summary != item.summary { summary = item.summary }
        if type != item.type.rawValue { type = item.type.rawValue }
        if volumes != item.volumes { volumes = item.volumes }
        if let interest = item.interest {
            if ctype != interest.type.rawValue { ctype = interest.type.rawValue }
            if collectedAt != interest.updatedAt { collectedAt = interest.updatedAt }
            if self.interest != interest { self.interest = interest }
        } else {
            if ctype != 0 { ctype = 0 }
            if collectedAt != 0 { collectedAt = 0 }
            if self.interest != nil { self.interest = nil }
        }
    }

    func update(_ item: BangumiSlimSubjectDTO) {
        if let images = item.images, self.images != images { self.images = images }
        if let info = item.info, self.info != info { self.info = info }
        if let rating = item.rating, self.rating != rating { self.rating = rating }
        if locked != item.locked { locked = item.locked }
        if metaTags != item.metaTags { metaTags = item.metaTags }
        if name != item.name { name = item.name }
        if nameCN != item.nameCN { nameCN = item.nameCN }
        if nsfw != item.nsfw { nsfw = item.nsfw }
        if type != item.type.rawValue { type = item.type.rawValue }
        if let interest = item.interest {
            if ctype != interest.type.rawValue { ctype = interest.type.rawValue }
            if collectedAt != interest.updatedAt { collectedAt = interest.updatedAt }
            if self.interest != nil {
                self.interest?.rate = interest.rate
                self.interest?.comment = interest.comment
                self.interest?.tags = interest.tags
                self.interest?.type = interest.type
                self.interest?.updatedAt = interest.updatedAt
            } else {
                self.interest = BangumiSubjectInterest(
                    comment: interest.comment,
                    epStatus: 0,
                    volStatus: 0,
                    private: false,
                    rate: interest.rate,
                    tags: interest.tags,
                    type: interest.type,
                    updatedAt: interest.updatedAt
                )
            }
        }
    }
}

extension BangumiEpisode {
    func update(_ item: BangumiEpisodeDTO) {
        if subjectId != item.subjectID { subjectId = item.subjectID }
        if type != item.type.rawValue { type = item.type.rawValue }
        if sort != item.sort { sort = item.sort }
        if name != item.name { name = item.name }
        if nameCN != item.nameCN { nameCN = item.nameCN }
        if duration != item.duration { duration = item.duration }
        if airdate != item.airdate { airdate = item.airdate }
        if comment != item.comment { comment = item.comment }
        if let desc = item.desc, !desc.isEmpty, self.desc != desc { self.desc = desc }
        if disc != item.disc { disc = item.disc }
        if let collection = item.collection {
            if status != collection.status { status = collection.status }
            if let collectedAt = collection.updatedAt, self.collectedAt != collectedAt {
                self.collectedAt = collectedAt
            }
        }
    }
}
