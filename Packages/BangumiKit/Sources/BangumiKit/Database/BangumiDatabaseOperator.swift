import Foundation
import GRDB

/// 排序模式（进度页）。
public enum BangumiProgressSortMode: Sendable {
    case collectedAt
    case airTime
}

/// 本地数据库操作层：进度/收藏/章节的读写都在这里，通过 read/write 包裹。
public actor BangumiDatabaseOperator {
    private let database: DatabaseQueue

    public init(database: DatabaseQueue) {
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
            if sortMode == .collectedAt {
                let filter = progressSubjectFilter(progressTab: progressTab, search: search)
                let total = try countSubjects(
                    in: db, whereSQL: filter.sql, arguments: filter.arguments)
                let subjects = try fetchSubjects(
                    in: db,
                    whereSQL: filter.sql,
                    arguments: filter.arguments,
                    orderSQL: "collected_at DESC",
                    limit: limit,
                    offset: offset
                )
                let items = try subjects.map {
                    try makeProgressSubject(in: db, $0, episodeWindowSize: episodeWindowSize)
                }
                return BangumiPagedDTO(data: items, total: total)
            }

            // airTime 排序：全量取 id 再按页切，保持分页稳定。
            let subjectIds = try fetchProgressSubjectIds(
                in: db, progressTab: progressTab, search: search)
            let pageIds = Array(subjectIds.dropFirst(offset).prefix(limit))
            let byId = try fetchSubjectsById(in: db, pageIds)
            let subjects = pageIds.compactMap { byId[$0] }
            let items = try subjects.map {
                try makeProgressSubject(in: db, $0, episodeWindowSize: episodeWindowSize)
            }
            return BangumiPagedDTO(data: items, total: subjectIds.count)
        }
    }

    /// 单条目进度（详情页章节区块用）。
    public func fetchProgressSubject(
        subjectId: Int, episodeWindowSize: Int
    ) throws -> BangumiProgressSubject? {
        try database.read { db in
            guard let subject = try fetchSubject(in: db, id: subjectId) else { return nil }
            return try makeProgressSubject(in: db, subject, episodeWindowSize: episodeWindowSize)
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
            var counts: [BangumiCollectionType: Int] = [:]
            for type in BangumiCollectionType.allTypes() {
                counts[type] = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM subjects WHERE ctype = ? AND type = ?",
                    arguments: [type.rawValue, subjectType.rawValue]
                ) ?? 0
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
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM episodes WHERE subject_id = ? AND sort <= ? AND type = ?",
                    arguments: [subjectId, episode.sort, BangumiEpisodeType.main.rawValue]
                )
                for row in rows {
                    let item = BangumiEpisode(row: row)
                    item.status = BangumiEpisodeCollectionType.collect.rawValue
                    item.collectedAt = now
                    try upsertEpisode(item, in: db)
                }
                subject.interest?.epStatus = rows.count
            } else {
                let previousType = episode.collectionTypeEnum
                episode.status = type.rawValue
                episode.collectedAt = now
                try upsertEpisode(episode, in: db)
                if episode.typeEnum == .main {
                    let epStatus = subject.interest?.epStatus ?? 0
                    let delta =
                        switch (previousType == .collect, type == .collect) {
                        case (false, true): 1
                        case (true, false): -1
                        default: 0
                        }
                    subject.interest?.epStatus = max(0, epStatus + delta)
                }
            }
            subject.interest?.updatedAt = now
            subject.collectedAt = now
            try upsertSubject(subject, in: db)
            return subjectId
        }
    }

    // MARK: - 保存

    public func saveEpisodes(subjectId: Int, items: [BangumiEpisodeDTO]) throws {
        guard !items.isEmpty else { return }
        try database.write { db in
            var subjectRef = try fetchSubject(in: db, id: subjectId)
            if subjectRef == nil, let slim = items.first?.subject {
                subjectRef = try ensureSubject(slim, in: db).0
            }
            for item in items {
                let episode = try makeEpisodeForSaving(item, in: db, fallbackSubject: subjectRef)
                try upsertEpisode(episode, in: db)
            }
        }
    }

    /// 删除本地不在远端集合里的章节（远端删除后清理）。
    public func deleteEpisodesNotIn(subjectId: Int, episodeIds: Set<Int>) throws {
        try database.write { db in
            if episodeIds.isEmpty {
                try db.execute(
                    sql: "DELETE FROM episodes WHERE subject_id = ?", arguments: [subjectId])
                return
            }
            let ids = Array(episodeIds)
            try db.execute(
                sql: """
                    DELETE FROM episodes
                    WHERE subject_id = ? AND episode_id NOT IN (\(placeholders(ids.count)))
                    """,
                arguments: StatementArguments([subjectId] + ids)
            )
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

    /// 清空账户相关数据（登出/换号时调用）。
    public func clearAccountLocalState() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM subjects")
            try db.execute(sql: "DELETE FROM episodes")
        }
    }

    // MARK: - 私有查询

    private func makeProgressSubject(
        in db: Database, _ subject: BangumiSubject, episodeWindowSize: Int
    ) throws -> BangumiProgressSubject {
        let episodes: [BangumiEpisodeDTO]
        switch subject.typeEnum {
        case .anime, .real:
            episodes = try fetchProgressEpisodes(
                in: db, subjectId: subject.subjectId, windowSize: episodeWindowSize)
        default:
            episodes = []
        }
        return BangumiProgressSubject(subject: subject.dto, episodes: episodes)
    }

    /// 以下一条未看本篇为中心的滑动窗口。
    private func fetchProgressEpisodes(
        in db: Database, subjectId: Int, windowSize: Int
    ) throws -> [BangumiEpisodeDTO] {
        let windowSize = max(1, windowSize)
        let mainType = BangumiEpisodeType.main.rawValue
        guard
            let nextRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM episodes
                    WHERE subject_id = ? AND type = ? AND status = 0
                    ORDER BY sort ASC
                    LIMIT 1
                    """,
                arguments: [subjectId, mainType]
            )
        else {
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM episodes
                    WHERE subject_id = ? AND type = ?
                    ORDER BY sort DESC
                    LIMIT ?
                    """,
                arguments: [subjectId, mainType, windowSize]
            ).reversed().map { BangumiEpisode(row: $0).dto }
        }

        let nextEpisode = BangumiEpisode(row: nextRow)
        let halfBefore = (windowSize - 1) / 2
        let halfAfter = windowSize - halfBefore - 1

        let before = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM episodes
                WHERE subject_id = ? AND type = ? AND sort < ?
                ORDER BY sort DESC
                LIMIT ?
                """,
            arguments: [subjectId, mainType, nextEpisode.sort, max(windowSize - 1, 0)]
        ).reversed().map { BangumiEpisode(row: $0) }

        let after = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM episodes
                WHERE subject_id = ? AND type = ? AND sort > ?
                ORDER BY sort ASC
                LIMIT ?
                """,
            arguments: [subjectId, mainType, nextEpisode.sort, max(windowSize - 1, 0)]
        ).map { BangumiEpisode(row: $0) }

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

        return (before.suffix(beforeCount) + [nextEpisode] + after.prefix(afterCount))
            .map(\.dto)
    }

    private func fetchProgressSubjectIds(
        in db: Database, progressTab: BangumiSubjectType, search: String
    ) throws -> [Int] {
        let filter = progressSubjectFilter(progressTab: progressTab, search: search)
        // 按收藏时间倒序的 id 序列（airTime 排序时全量取出再切页）。
        return try Int.fetchAll(
            db,
            sql: "SELECT subject_id FROM subjects WHERE \(filter.sql) ORDER BY collected_at DESC",
            arguments: filter.arguments
        )
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

    private func makeEpisodeForSaving(
        _ item: BangumiEpisodeDTO, in db: Database, fallbackSubject: BangumiSubject? = nil
    ) throws -> BangumiEpisode {
        let episode = try fetchEpisode(in: db, id: item.id) ?? BangumiEpisode(item)
        episode.update(item)
        if let slim = item.subject {
            let (subject, _) = try ensureSubject(slim, in: db)
            try upsertSubject(subject, in: db)
        } else if let fallbackSubject, try fetchSubject(in: db, id: fallbackSubject.subjectId) == nil {
            // 兜底条目不在本地时补上，保证章节的 subject 关联存在。
            try upsertSubject(fallbackSubject, in: db)
        }
        return episode
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
            sql += " AND (name LIKE ? COLLATE NOCASE OR alias LIKE ? COLLATE NOCASE)"
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
