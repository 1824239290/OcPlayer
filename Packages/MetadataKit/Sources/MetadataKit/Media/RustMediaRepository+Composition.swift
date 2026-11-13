import CoreModel
import Foundation

extension RustMediaRepository {
    func compose<Input: Encodable, Output: Decodable>(
        _ method: String, _ input: Input, as: Output.Type = Output.self
    ) throws -> Output {
        try decode("compose." + method, [
            "payloadJSON": String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
        ])
    }
    struct NextUp: Encodable { var nextUp: [MediaItem]; var resume: [MediaItem] }
    struct Seasons: Encodable { var seasons: [MediaItem] }
    struct DetailPlan: Encodable {
        var kindHint: MediaItem.Kind?
        var previous: MediaDetailContent?
        var item: MediaItem?
    }
    struct Detail: Encodable {
        var content: MediaDetailContent
        var requestStartedAt: Date
        var mergeProgress: Bool
    }
    struct Home: Encodable { var content: MediaHomeContent; var requestStartedAt: Date }
    struct DiskHome: Encodable {
        var content: MediaHomeContent
        var railDates: [Date]
        var libraryDates: [Date]
        var now: Date
    }
    struct DiskRow: Encodable {
        var items: [MediaItem]
        var totalRecordCount: Int?
        var startIndex: Int
        var limit: Int
        init(_ row: CachedPage) {
            items = row.items; totalRecordCount = row.totalRecordCount
            startIndex = row.startIndex; limit = row.limit
        }
    }
    struct DiskPage: Encodable { var rows: [DiskRow] }
    struct Page: Encodable {
        var items: [MediaItem]
        var totalRecordCount: Int?
        var startIndex: Int
        var limit: Int
        var previous: MediaPageContent?
        var requestStartedAt: Date
    }
}

extension MediaRepository {
    func repositoryDefaultSeason(in seasons: [MediaItem]) throws -> MediaItem.ID? {
        if let rust { return try rust.compose("defaultSeason", RustMediaRepository.Seasons(seasons: seasons)) }
        return Self.defaultSeasonID(in: seasons)
    }
    func repositoryDetail(
        _ content: MediaDetailContent, requestStartedAt: Date, mergeProgress: Bool = true
    ) throws -> MediaDetailContent {
        if let rust {
            return try rust.compose("detail", RustMediaRepository.Detail(
                content: content, requestStartedAt: requestStartedAt, mergeProgress: mergeProgress))
        }
        guard mergeProgress else { return content }
        var result = content
        result.item = mergingLocalProgress([result.item], requestStartedAt: requestStartedAt)[0]
        result.seasons = mergingLocalProgress(result.seasons, requestStartedAt: requestStartedAt)
        result.episodes = mergingLocalProgress(result.episodes, requestStartedAt: requestStartedAt)
        result.collectionMembers = mergingLocalProgress(result.collectionMembers, requestStartedAt: requestStartedAt)
        return result
    }
}
