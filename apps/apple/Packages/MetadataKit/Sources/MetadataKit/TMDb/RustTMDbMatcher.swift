import CoreModel
import Foundation
import OcPlayerCore

/// Executes Core's decisions while preserving the caller's injected search.
struct RustTMDbMatcher: Sendable {
    let core: OcpCoreClient

    static func make(libraryPath: String? = nil) -> Self? {
        guard libraryPath != nil || OcpCoreFeature.isEnabled,
              let core = try? OcpCoreClient(libraryPath: libraryPath) else { return nil }
        return Self(core: core)
    }

    struct Item: Encodable {
        let name, kind: String
        let year: Int?
        let originalTitle, tmdbID: String?
        let seasonNumber: Int?
        let seriesName: String?
        init(_ item: MediaItem) {
            name = item.name; kind = item.kind.rawValue; year = item.year
            originalTitle = item.originalTitle; tmdbID = item.tmdbID
            seasonNumber = item.seasonNumber; seriesName = item.seriesName
        }
    }
    struct Link: Encodable {
        let entityKey, source: String
        let confidence: Double
        init(_ link: TMDbLink) {
            entityKey = link.entityKey.storageKey; source = link.source.rawValue
            confidence = link.confidence
        }
    }
    struct Request: Encodable {
        let operation: String
        var item: Item?
        var seriesLink: Link?
        var allowSearch: Bool?
        var candidates: [TMDbSearchResult]?
        var titles: [String?]?
    }
    struct Match: Decodable {
        let entityKey, source: String
        let confidence: Double
        let matchedTitle: String?
        let alternatives: [TMDbSearchResult]
        func native() throws -> TMDbMatch {
            guard let key = TMDbEntityKey(storageKey: entityKey),
                  let source = TMDbLinkSource(rawValue: source) else {
                throw NSError(domain: "TMDbMatcher", code: 2)
            }
            return TMDbMatch(entityKey: key, source: source, confidence: confidence,
                             matchedTitle: matchedTitle, alternatives: alternatives)
        }
    }
    struct Search: Decodable {
        let query, mediaType: String
        let year: Int?
    }
    struct Reply: Decodable {
        var match: Match?
        var search: Search?
        var needsOriginalSearch: Bool?
        var scores: [Double]?
        var id: Int?
        var normalized: [String]?
        var years: [Int?]?
    }
    func call(_ request: Request) throws -> Reply {
        let args = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try core.call("tmdb.matcher", argumentsJSON: args)
        guard response.ok, case .object(let object) = response.data,
              case .string(let payload) = object["payloadJSON"] else {
            throw NSError(domain: "TMDbMatcher", code: Int(response.code),
                          userInfo: [NSLocalizedDescriptionKey: response.message])
        }
        // Avoid JSONValue's Double representation for exact native Int IDs.
        return try JSONDecoder().decode(Reply.self, from: Data(payload.utf8))
    }
    func match(item: MediaItem, seriesLink: TMDbLink?, allowSearch: Bool,
               language: String,
               search: @Sendable (String, TMDbMediaType, Int?, String) async throws -> [TMDbSearchResult]) async throws -> TMDbMatch? {
        var request = Request(operation: "initial", item: Item(item),
                              seriesLink: seriesLink.map(Link.init), allowSearch: allowSearch)
        let initial = try call(request)
        if let match = initial.match { return try match.native() }
        guard let query = initial.search else { return nil }
        let type: TMDbMediaType = query.mediaType == "movie" ? .movie : .tv
        var candidates = (try? await search(query.query, type, query.year, language)) ?? []
        request = Request(operation: "rank", item: Item(item), candidates: candidates)
        let primary = try call(request)
        if primary.needsOriginalSearch == true, let original = item.originalTitle {
            candidates += (try? await search(original, type, query.year, language)) ?? []
            request.candidates = candidates
            return try call(request).match?.native()
        }
        return try primary.match?.native()
    }
}
