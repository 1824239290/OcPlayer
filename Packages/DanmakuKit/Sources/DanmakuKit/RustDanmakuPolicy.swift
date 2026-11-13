import Foundation
import OcPlayerCore

/// Shared pure policies use one retained Core and do not issue network requests.
/// A loaded Core is authoritative; command/decode defects never silently replay
/// the native policy. The latter remains available for disabled-Core comparison.
struct RustDanmakuPolicy: Sendable {
    private static let client: OcpCoreClient? = try? OcpCoreClient()
    static var active: Self? {
        guard OcpCoreFeature.isEnabled, let core = client else { return nil }
        return Self(core: core)
    }
    let core: OcpCoreClient

    private func call<T: Decodable>(_ method: String, _ arguments: [String: Any], as: T.Type = T.self) -> T {
        do {
            let response = try core.call(method, arguments: arguments)
            guard response.ok else { preconditionFailure("Core danmaku policy: \(response.message)") }
            return try response.data.decode(T.self)
        } catch { preconditionFailure("Core danmaku policy: \(error)") }
    }
    func parse(_ raw: String) -> ParsedAnimeInfo {
        struct Parsed: Decodable { let raw_name, title: String; let episode_number, season_number: Int?; let is_final: Bool }
        let value: Parsed = call("danmaku.parseFilename", ["fileName": raw])
        return ParsedAnimeInfo(rawName: value.raw_name, title: value.title, episodeNumber: value.episode_number,
            seasonNumber: value.season_number, isFinal: value.is_final)
    }
    func comparable(_ title: String) -> String {
        struct Result: Decodable { let title: String }
        return call("danmaku.comparableTitle", ["title": title], as: Result.self).title
    }
    func episode(_ title: String?) -> DanmakuEpisodeToken? {
        struct Token: Decodable { let tokenType: String; let kind: String? }
        struct Result: Decodable { let episode: Token?; let searchValue: String? }
        let result: Result = call("danmaku.parseEpisode", ["title": title as Any? ?? NSNull()])
        guard let token = result.episode, let search = result.searchValue else { return nil }
        if token.tokenType == "number", let value = Int(search) { return .number(value) }
        let kind: DanmakuSpecialKind
        switch token.kind { case "special": kind = .special; case "extra": kind = .extra; default: kind = .other }
        guard let index = Int(search.dropFirst()) else { preconditionFailure("Core returned invalid episode token") }
        return .special(kind: kind, index: index)
    }
    func canonical(series: String?, season: Int?, episode: DanmakuEpisodeToken?, raw: String) -> String {
        var arguments: [String: Any] = ["rawFileName": raw]
        if let series { arguments["seriesTitle"] = series }
        if let season { arguments["season"] = season }
        switch episode {
        case .number(let n): arguments["episode"] = ["tokenType":"number", "value":n]
        case .special(let kind, let index): arguments["episode"] = ["tokenType":"special", "kind":kindName(kind), "index":index]
        case nil: break
        }
        struct Result: Decodable { let fileName: String }
        return call("danmaku.canonicalMatchName", arguments, as: Result.self).fileName
    }
    func specialKind(_ text: String) -> DanmakuSpecialKind? {
        struct Result: Decodable { let kind: String? }
        switch call("danmaku.specialKind", ["text":text], as: Result.self).kind {
        case "extra": return .extra
        case "special": return .special
        case "other": return .other
        default: return nil
        }
    }
    private func kindName(_ kind: DanmakuSpecialKind) -> String {
        switch kind {case .special: "special"; case .extra: "extra"; case .other: "other"}
    }
    private func target(_ target: DanmakuCandidateScorer.TargetContext) -> [String: Any] {
        var value: [String: Any] = ["isFinal":target.isFinal,"kind":target.kind == .movie ? "movie":"episode"]
        if let title = target.animeTitle { value["animeTitle"] = title }
        if let episode = target.episodeNumber { value["episodeNumber"] = episode }
        if let season = target.seasonNumber { value["seasonNumber"] = season }
        if let special = target.special { value["special"] = ["index":special.index,"kinds":special.kinds.map(kindName)] }
        return value
    }
    func candidate(id: Int64 = 0, anime: String?, episode: String?, description: String?, kind: String?) -> [String: Any] {
        var value: [String: Any] = ["episodeId":id]
        if let anime {value["animeTitle"] = anime}
        if let episode {value["episodeTitle"] = episode}
        if let description {value["typeDescription"] = description}
        if let kind {value["type"] = kind}
        return value
    }
    struct Selection: Decodable { let index, score: Int }
    private struct Scores: Decodable { let scores: [Int]; let selection: Selection? }
    func score(anime: String?, episode: String?, description: String?, kind: String?, target: DanmakuCandidateScorer.TargetContext, rank: Int) -> Int {
        let result: Scores = call("danmaku.scoreCandidates", ["target":self.target(target),
            "candidates":[candidate(anime:anime, episode:episode, description:description, kind:kind)], "rankIndex":rank])
        return result.scores[0]
    }
    func select(_ candidates: [[String: Any]], target: DanmakuCandidateScorer.TargetContext) -> Selection? {
        call("danmaku.scoreCandidates", ["target":self.target(target),"candidates":candidates], as: Scores.self).selection
    }
}
