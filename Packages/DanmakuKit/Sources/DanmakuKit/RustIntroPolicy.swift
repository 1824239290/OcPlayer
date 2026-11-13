import Foundation
import OcPlayerCore

extension RustDanmakuPolicy {
    func intro<T: Decodable>(_ method: String, arguments: [String: Any], as: T.Type = T.self) -> T {
        do {
            let response = try core.call("danmakuIntro." + method, arguments: arguments)
            guard response.ok else { preconditionFailure("Core intro policy: \(response.message)") }
            let payload = try response.data.decode(IntroPayload.self)
            return try JSONDecoder().decode(T.self, from: Data(payload.payloadJSON.utf8))
        } catch { preconditionFailure("Core intro policy: \(error)") }
    }

    func introPayload<T: Encodable, R: Decodable>(_ method: String, value: T, as: R.Type = R.self) -> R {
        do {
            let data = try JSONEncoder().encode(value)
            return intro(method, arguments: ["payloadJSON": String(decoding: data, as: UTF8.self)])
        } catch { preconditionFailure("Core intro payload: \(error)") }
    }

    func consensus(_ events: [IntroSeekEvent], minimum: Int) -> IntroConsensus? {
        guard let data = try? JSONEncoder().encode(events) else { return nil }
        return intro("consensus", arguments: [
            "payloadJSON": String(decoding: data, as: UTF8.self), "minimumEpisodes": minimum,
        ])
    }
}

private struct IntroPayload: Decodable { let payloadJSON: String }
struct IntroConsensus: Decodable { let end: Double; let episodeCount: Int }
struct SelectedIntroInterval: Decodable {
    let start: Double?
    let end: Double
    let votes: Int
    let source: DanmakuIntroHintSource
}

/// A separate retained Core keeps native per-store memory and file semantics.
struct RustIntroLearningStore: Sendable {
    let core: OcpCoreClient
    init(directory: URL) throws {
        core = try OcpCoreClient()
        let response = try core.call("introLearning.open", arguments: ["directory": directory.path])
        guard response.ok else { throw OcpCoreError(message: response.message) }
    }

    func call<T: Decodable>(_ method: String, animeID: Int64, as: T.Type = T.self) throws -> T {
        try call(method, arguments: ["animeID": animeID])
    }

    private func call<T: Decodable>(_ method: String, arguments: [String: Any]) throws -> T {
        let response = try core.call("introLearning." + method, arguments: arguments)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        let payload = try response.data.decode(IntroPayload.self)
        return try JSONDecoder().decode(T.self, from: Data(payload.payloadJSON.utf8))
    }

    func write<T: Encodable>(_ method: String, animeID: Int64, value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let _: Bool? = try? call(method, arguments: [
            "animeID": animeID, "payloadJSON": String(decoding: data, as: UTF8.self),
        ])
    }
}
