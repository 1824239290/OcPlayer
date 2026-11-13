import Foundation
import OcPlayerCore

/// The adapter retains only effect data. Decisions and continuation state live in Core.
@MainActor
final class RustDanmakuFlow {
    private let core: OcpCoreClient
    private let id = UUID().uuidString
    private(set) var state: [String: Any] = [:]
    init(core: OcpCoreClient, configuration: [String: Any]) throws {
        self.core = core
        state = try call("begin", value: configuration)
    }
    private func call(_ method: String, value: Any? = nil, step: UInt64? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["flowID": id]
        if let value {
            args["payloadJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        if let step { args["step"] = step }
        let response = try core.call("danmakuFlow." + method, arguments: args)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        struct Payload: Decodable { let payloadJSON: String }
        let payload = try response.data.decode(Payload.self)
        return try JSONSerialization.jsonObject(with: Data(payload.payloadJSON.utf8)) as! [String: Any]
    }
    func advance(value: Any = NSNull(), error: [String: Any]? = nil, current: Bool, cancelled: Bool) throws {
        var reply: [String: Any] = ["value": value, "current": current, "cancelled": cancelled]
        if let error { reply["error"] = error }
        let step = (state["step"] as! NSNumber).uint64Value
        state = try call("advance", value: reply, step: step)
    }
    func close() { _ = try? call("close") }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    static func decode<T: Decodable>(_ value: Any?, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed]))
    }
    static func failure(_ error: Error) -> [String: Any] {
        switch error {
        case DandanplayError.notConfigured: ["kind": "notConfigured"]
        case DandanplayError.unauthorized: ["kind": "unauthorized"]
        case DandanplayError.forbidden: ["kind": "forbidden"]
        case DandanplayError.rateLimited: ["kind": "rateLimited"]
        case DandanplayError.businessError(_, let message): ["kind": "businessError", "message": message as Any? ?? NSNull()]
        case DandanplayError.decodingFailed: ["kind": "decodingFailed"]
        case DandanplayError.network: ["kind": "network"]
        case DandanplayError.httpStatus(let status): ["kind": "httpStatus", "status": status]
        case DandanplayError.invalidRequest(let message): ["kind": "invalidRequest", "message": message]
        default: ["kind": "other"]
        }
    }
    var outcome: DanmakuLoadOutcome? {
        guard let result = state["outcome"] as? [String: Any], let kind = result["kind"] as? String else { return nil }
        switch kind {
        case "noMatch": return .noMatch
        case "failed": return .failed(message: result["message"] as! String)
        case "loaded", "empty":
            let id = (result["episodeID"] as! NSNumber).int64Value
            let title = result["title"] as! String
            let hint = try? Self.decode(result["introHint"], as: DanmakuIntroHint?.self)
            if kind == "empty" { return .empty(episodeID: id, title: title, introHint: hint ?? nil) }
            return .loaded(episodeID: id, commentCount: (result["commentCount"] as! NSNumber).intValue, title: title, introHint: hint ?? nil)
        default: preconditionFailure("Unknown Core load outcome")
        }
    }
}

extension RustDanmakuPolicy {
    func render(_ comments: [DanmakuComment], format: DanmakuPayloadFormat, detectingIntro: Bool, match: DanmakuEpisodeMatch) throws -> DanmakuPayload {
        let name = switch format { case .overlay: "overlay"; case .kernelTrack: "kernelTrack"; case .both: "both" }
        let encoded = try JSONEncoder().encode(comments)
        let response = try core.call("danmaku.renderPayload", arguments: ["payloadJSON": String(decoding: encoded, as: UTF8.self), "format": name, "detectingIntro": detectingIntro])
        guard response.ok else { throw OcpCoreError(message: response.message) }
        struct Envelope: Decodable { let payloadJSON: String }
        struct Payload: Decodable {
            struct Entry: Decodable { let time: Double; let mode: String; let color: UInt32; let text: String }
            let entries: [Entry]?; let json: String?; let commentCount: Int; let detectedIntroHint: DanmakuIntroHint?
        }
        let value = try JSONDecoder().decode(Payload.self, from: Data(response.data.decode(Envelope.self).payloadJSON.utf8))
        return DanmakuPayload(match: match, entries: value.entries?.map {
            DanmakuJSONParser.Entry(time: $0.time, mode: $0.mode == "top" ? .top : ($0.mode == "bottom" ? .bottom : .scroll), color: $0.color, text: $0.text)
        }, json: value.json, commentCount: value.commentCount, detectedIntroHint: value.detectedIntroHint)
    }
}
