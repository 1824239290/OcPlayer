import Foundation
import OcPlayerCore

/// Converts the shared domain model to the native metadata/cache model.
struct RustTMDbClient: Sendable {
    let core: OcpCoreClient

    func call(_ method: String, key: String, endpoint: URL, language: String,
              arguments: [String: any Sendable]) async throws -> JSONValue {
        var args = arguments
        args["apiKey"] = key
        args["apiBase"] = endpoint.absoluteString
        args["language"] = language
        let response = try await core.callAsync(method, argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: args.mapValues { $0 as Any }), as: UTF8.self))
        guard response.ok else {
            switch response.code {
            case 2001: throw TMDbError.unauthorized
            case 2004: throw TMDbError.notFound
            case 2029: throw TMDbError.rateLimited(retryAfter: nil)
            case 1800...2199: throw TMDbError.http(status: Int(response.code) - 1600)
            case 1514: throw TMDbError.decoding(response.message)
            default: throw TMDbError.transport(response.message)
            }
        }
        return response.data
    }

    func entity(id: Int, type: TMDbMediaType, key: String, endpoint: URL, language: String) async throws -> TMDbEntity {
        let raw = try await call("tmdb.entity", key: key, endpoint: endpoint, language: language,
                                 arguments: ["id": id, "mediaType": type.rawValue]).decode(Entity.self)
        return TMDbEntity(id: raw.id, mediaType: type,
                          title: type == .movie ? raw.title : raw.name,
                          originalTitle: type == .movie ? raw.original_title : raw.original_name,
                          overview: raw.overview, posterPath: raw.poster_path, backdropPath: raw.backdrop_path,
                          voteAverage: raw.vote_average, genres: raw.genres,
                          cast: raw.cast.map { CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path) },
                          seasons: raw.seasons.map { SeasonSummary(seasonNumber: $0.season_number, name: $0.name, overview: $0.overview, posterPath: $0.poster_path, episodeCount: $0.episode_count) },
                          originalLanguage: raw.original_language, imdbID: raw.imdb_id,
                          contentRating: raw.content_rating, collectionID: raw.collection_id)
    }

    func search(query: String, type: TMDbMediaType, year: Int?, key: String, endpoint: URL, language: String) async throws -> [TMDbSearchResult] {
        var args: [String: any Sendable] = ["query": query, "mediaType": type.searchResultKind]
        if let year { args["year"] = year }
        let results = try await call("tmdb.search", key: key, endpoint: endpoint, language: language, arguments: args).decode([SearchResult].self)
        return results.map { raw in
            let date = type == .movie ? raw.release_date : raw.first_air_date
            return TMDbSearchResult(id: raw.id, mediaType: type, title: type == .movie ? raw.title : raw.name,
                                    originalTitle: type == .movie ? raw.original_title : raw.original_name,
                                    overview: raw.overview, posterPath: raw.poster_path,
                                    year: date.flatMap { Int($0.prefix(4)) }, popularity: raw.popularity)
        }
    }

    func season(id: Int, number: Int, key: String, endpoint: URL, language: String) async throws -> TMDbSeason {
        let raw = try await call("tmdb.season", key: key, endpoint: endpoint, language: language,
                                 arguments: ["id": id, "seasonNumber": number]).decode(Season.self)
        return TMDbSeason(seasonNumber: raw.season_number, name: raw.name, overview: raw.overview, posterPath: raw.poster_path,
                          episodes: raw.episodes.map { EpisodeEntry(episodeNumber: $0.episode_number, name: $0.name, overview: $0.overview, stillPath: $0.still_path, airDate: $0.air_date, runtime: $0.runtime, voteAverage: $0.vote_average) })
    }

    private struct SearchResult: Decodable {
        let id: Int
        let title, original_title, name, original_name, overview, poster_path, release_date, first_air_date: String?
        let popularity: Double?
    }
    private struct Entity: Decodable {
        let id: Int
        let title, original_title, name, original_name, overview, poster_path, backdrop_path, original_language, imdb_id, content_rating: String?
        let vote_average: Double?
        let collection_id: Int?
        let genres: [String]
        let cast: [Cast]
        let seasons: [SeasonSummaryRaw]
    }
    private struct Cast: Decodable {
        let id: Int
        let name: String
        let character, profile_path: String?
    }
    private struct SeasonSummaryRaw: Decodable {
        let season_number: Int
        let name, overview, poster_path: String?
        let episode_count: Int?
    }
    private struct Season: Decodable {
        let season_number: Int
        let name, overview, poster_path: String?
        let episodes: [Episode]
    }
    private struct Episode: Decodable {
        let episode_number: Int
        let name, overview, still_path, air_date: String?
        let runtime: Int?
        let vote_average: Double?
    }
}
