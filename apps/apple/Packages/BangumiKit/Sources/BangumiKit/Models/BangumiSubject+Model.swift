import Foundation
import GRDB

/// 本地持久化的条目模型（与 Bangumi-iOS 的 `Subject` 同构，只保留进度/收藏需要的字段）。
final class BangumiSubject {
    var subjectId: Int

    var airtime: BangumiSubjectAirtime
    var collection: BangumiSubjectCollection
    var eps: Int
    var images: BangumiSubjectImages?
    var infobox: [BangumiInfoboxItem]
    var locked: Bool
    var metaTags: [String]
    var tags: [BangumiTag]
    var name: String
    var nameCN: String
    var nsfw: Bool
    var platform: BangumiSubjectPlatform
    var rating: BangumiSubjectRating
    var series: Bool
    var summary: String
    var type: Int
    var volumes: Int
    var info: String = ""
    var alias: String = ""

    var ctype: Int = 0
    var collectedAt: Int = 0
    var interest: BangumiSubjectInterest?

    init(_ item: BangumiSubjectDTO) {
        subjectId = item.id
        airtime = item.airtime
        collection = item.collection
        eps = item.eps
        images = item.images
        infobox = item.infobox
        info = item.info
        locked = item.locked
        metaTags = item.metaTags
        tags = item.tags
        name = item.name
        nameCN = item.nameCN
        nsfw = item.nsfw
        platform = item.platform
        rating = item.rating
        series = item.series
        summary = item.summary
        type = item.type.rawValue
        volumes = item.volumes
        interest = item.interest
        if let interest {
            ctype = interest.type.rawValue
            collectedAt = interest.updatedAt
        }
    }

    init(_ item: BangumiSlimSubjectDTO) {
        subjectId = item.id
        airtime = BangumiSubjectAirtime(date: nil)
        collection = [:]
        eps = 0
        images = item.images
        infobox = []
        info = item.info ?? ""
        locked = item.locked
        metaTags = item.metaTags
        tags = []
        name = item.name
        nameCN = item.nameCN
        nsfw = item.nsfw
        platform = BangumiSubjectPlatform(name: "")
        rating = item.rating ?? BangumiSubjectRating()
        series = false
        summary = ""
        type = item.type.rawValue
        volumes = 0
        interest = item.interest.map {
            // slim 收藏信息里没有 epStatus / volStatus / private，缺的按「未知」补 0/false，
            // 别拿别的字段推断（曾经把 private 写成 `type == .doing`，是两回事）。
            BangumiSubjectInterest(
                comment: $0.comment,
                epStatus: 0,
                volStatus: 0,
                private: false,
                rate: $0.rate,
                tags: $0.tags,
                type: $0.type,
                updatedAt: $0.updatedAt
            )
        }
        if let interest {
            ctype = interest.type.rawValue
            collectedAt = interest.updatedAt
        }
    }
}

extension BangumiSubject {
    var typeEnum: BangumiSubjectType {
        BangumiSubjectType(type)
    }

    var ctypeEnum: BangumiCollectionType {
        BangumiCollectionType(ctype)
    }

    var dto: BangumiSubjectDTO {
        BangumiSubjectDTO(
            id: subjectId,
            airtime: airtime,
            collection: collection,
            eps: eps,
            images: images,
            infobox: infobox,
            info: info,
            locked: locked,
            metaTags: metaTags,
            tags: tags,
            name: name,
            nameCN: nameCN,
            nsfw: nsfw,
            platform: platform,
            rating: rating,
            redirect: 0,
            series: series,
            seriesEntry: 0,
            summary: summary,
            type: typeEnum,
            volumes: volumes,
            interest: interest
        )
    }
}

extension BangumiSubject {
    convenience init(row: Row) {
        let typeValue: Int = row["type"]
        let interest: BangumiSubjectInterest? = row.jsonOptional("interest_data")
        self.init(
            BangumiSubjectDTO(
                id: row["subject_id"],
                airtime: row.json("airtime_data", fallback: BangumiSubjectAirtime(date: "")),
                collection: row.json("collection_data", fallback: [:]),
                eps: row["eps"],
                images: row.jsonOptional("images_data"),
                infobox: row.json("infobox_data", fallback: []),
                info: row["info"],
                locked: BangumiRecordCoding.bool(row["locked"] as Int),
                metaTags: row.json("meta_tags_data", fallback: []),
                tags: row.json("tags_data", fallback: []),
                name: row["name"],
                nameCN: row["name_cn"],
                nsfw: BangumiRecordCoding.bool(row["nsfw"] as Int),
                platform: row.json("platform_data", fallback: BangumiSubjectPlatform(name: "")),
                rating: row.json("rating_data", fallback: BangumiSubjectRating()),
                redirect: 0,
                series: BangumiRecordCoding.bool(row["series"] as Int),
                seriesEntry: 0,
                summary: row["summary"],
                type: BangumiSubjectType(typeValue),
                volumes: row["volumes"],
                interest: interest
            )
        )
        ctype = row["ctype"]
        collectedAt = row["collected_at"]
        alias = row["alias"]
    }
}

/// 本地持久化的章节模型。
final class BangumiEpisode {
    var episodeId: Int
    var subjectId: Int
    var type: Int
    var sort: Float
    var name: String
    var nameCN: String
    var duration: String
    var airdate: String
    var comment: Int
    var desc: String
    var disc: Int

    var status: Int = 0
    var collectedAt: Int = 0

    init(_ item: BangumiEpisodeDTO) {
        episodeId = item.id
        subjectId = item.subjectID
        type = item.type.rawValue
        sort = item.sort
        name = item.name
        nameCN = item.nameCN
        duration = item.duration
        airdate = item.airdate
        comment = item.comment
        desc = item.desc ?? ""
        disc = item.disc
        if let collection = item.collection {
            status = collection.status
            collectedAt = collection.updatedAt ?? 0
        }
    }
}

extension BangumiEpisode {
    var typeEnum: BangumiEpisodeType {
        BangumiEpisodeType(type)
    }

    var collectionTypeEnum: BangumiEpisodeCollectionType {
        BangumiEpisodeCollectionType(status)
    }

    var dto: BangumiEpisodeDTO {
        BangumiEpisodeDTO(
            id: episodeId,
            subjectID: subjectId,
            type: typeEnum,
            sort: sort,
            name: name,
            nameCN: nameCN,
            duration: duration,
            airdate: airdate,
            comment: comment,
            disc: disc,
            desc: desc.isEmpty ? nil : desc,
            collection: collectedAt == 0
                ? BangumiEpisodeCollectionStatus(status: status, updatedAt: nil)
                : BangumiEpisodeCollectionStatus(status: status, updatedAt: collectedAt)
        )
    }
}

extension BangumiEpisode {
    convenience init(row: Row) {
        let typeValue: Int = row["type"]
        let sortValue: Double = row["sort"]
        let collectedAt: Int = row["collected_at"]
        self.init(
            BangumiEpisodeDTO(
                id: row["episode_id"],
                subjectID: row["subject_id"],
                type: BangumiEpisodeType(typeValue),
                sort: Float(sortValue),
                name: row["name"],
                nameCN: row["name_cn"],
                duration: row["duration"],
                airdate: row["airdate"],
                comment: row["comment"],
                disc: row["disc"],
                desc: row["desc"],
                collection: BangumiEpisodeCollectionStatus(
                    status: row["status"],
                    updatedAt: collectedAt == 0 ? nil : collectedAt
                )
            )
        )
    }
}
