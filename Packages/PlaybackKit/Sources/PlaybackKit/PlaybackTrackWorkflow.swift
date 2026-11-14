import Foundation
import Observation
import OcPlayerCore

/// Owns automatic/manual selection, sidecar batches and imported track names.
/// Decoder calls stay synchronous on the host; only successful receipts commit policy.
@MainActor
@Observable
public final class PlaybackTrackWorkflow {
    @ObservationIgnored private let core: OcpPlaybackTracks?
    private var fallbackNames: [Int64: String] = [:]
    private var fallbackManual = false
    private var fallbackBatch: String?
    @ObservationIgnored private var isPerforming = false
    private var revision: UInt64 = 0
    public var usesCore: Bool { core != nil }
    public var manualChoice: Bool { _ = revision; return core?.snapshot.manualChoice ?? fallbackManual }
    public var isLoadingBatch: Bool { _ = revision; return (core?.snapshot.batchId ?? fallbackBatch) != nil }
    public var batchID: String? { _ = revision; return core?.snapshot.batchId ?? fallbackBatch }
    public var externalNames: [Int64: String] {
        _ = revision
        guard let core else { return fallbackNames }
        return Dictionary(uniqueKeysWithValues: core.snapshot.externalNames.compactMap { key, value in
            Int64(key).map { ($0, value) }
        })
    }
    public init() { core = OcpPlaybackTracks() }
    public func reset() throws {
        defer { revision &+= 1 }
        if let core { try core.reset() }
        else { fallbackNames = [:]; fallbackManual = false; fallbackBatch = nil }
    }
    public func registerName(id: Int64, name: String) throws {
        defer { revision &+= 1 }
        if let core { try core.registerName(id: id, name: name) }
        else if !name.isEmpty { fallbackNames[id] = name }
    }
    public func beginBatch(id: String) throws {
        defer { revision &+= 1 }
        if let core { try core.beginBatch(id: id) } else { fallbackBatch = id }
    }
    public func endBatch(id: String) throws -> Bool {
        guard batchID == id else { return false }
        if let core { try core.endBatch(id: id) } else { fallbackBatch = nil }
        revision &+= 1
        return true
    }
    public enum Operation {
        case automatic(tracks: [TrackInfo], preference: SubtitleLanguagePreference, current: Int64?)
        case selectSubtitle(Int64?)
        case selectAudio(Int64)
        case importSubtitle(path: String, name: String)
        case attachSubtitle(path: String, name: String?)
        case removeSubtitle(TrackInfo)
    }
    /// Returns false when policy retains the current selection or a nested refresh is busy.
    @discardableResult
    public func perform(_ operation: Operation, engine: any PlaybackEngine,
                        didSelectSubtitle: (Int64?) -> Void = { _ in },
                        didSelectAudio: (Int64) -> Void = { _ in }) throws -> Bool {
        guard !isPerforming else { return false }
        isPerforming = true
        defer { isPerforming = false; revision &+= 1 }
        if let core {
            var step = try core.begin(request(operation))
            let performed = step.effect != nil
            while let effect = step.effect, let id = step.operationId {
                let added: Int64?
                do {
                    switch effect.action {
                    case "selectSubtitle":
                        try engine.selectSubtitleTrack(effect.id); didSelectSubtitle(effect.id); added = nil
                    case "selectAudio":
                        guard let trackID = effect.id else { throw TrackWorkflowError.invalidEffect("Missing audio track") }
                        try engine.selectAudioTrack(trackID); didSelectAudio(trackID); added = nil
                    case "addSubtitle":
                        guard let path = effect.path else { throw TrackWorkflowError.invalidEffect("Missing subtitle path") }
                        added = try engine.addExternalSubtitle(path)
                    case "removeSubtitle":
                        guard let trackID = effect.id else { throw TrackWorkflowError.invalidEffect("Missing subtitle track") }
                        try engine.removeSubtitleTrack(trackID); added = nil
                    default: throw TrackWorkflowError.invalidEffect("Unknown track effect: \(effect.action)")
                    }
                } catch {
                    _ = try core.complete(operationID: id, success: false)
                    throw error
                }
                step = try core.complete(operationID: id, success: true, trackID: added)
            }
            return performed
        }
        switch operation {
        case let .automatic(tracks, preference, current):
            guard !fallbackManual, fallbackBatch == nil else { return false }
            let selection = SubtitleTrackSelector.nativeSelection(in: tracks, preference: preference, current: current, displayNames: fallbackNames)
            switch selection {
            case .keep: return false
            case .disable: try engine.selectSubtitleTrack(nil); didSelectSubtitle(nil)
            case let .select(id): try engine.selectSubtitleTrack(id); didSelectSubtitle(id)
            }
        case let .selectSubtitle(id):
            try engine.selectSubtitleTrack(id); didSelectSubtitle(id); fallbackManual = true
        case let .selectAudio(id):
            try engine.selectAudioTrack(id); didSelectAudio(id)
        case let .importSubtitle(path, name):
            let id = try engine.addExternalSubtitle(path)
            if !name.isEmpty { fallbackNames[id] = name }
            try engine.selectSubtitleTrack(id); didSelectSubtitle(id); fallbackManual = true
        case let .attachSubtitle(path, name):
            let id = try engine.addExternalSubtitle(path)
            if let name, !name.isEmpty { fallbackNames[id] = name }
        case let .removeSubtitle(track):
            guard track.kind == .subtitle, track.canRemove else { return false }
            try engine.removeSubtitleTrack(track.id)
            fallbackNames.removeValue(forKey: track.id)
            if track.selected { fallbackManual = false }
        }
        return true
    }
    private func request(_ operation: Operation) -> [String: Any] {
        switch operation {
        case let .automatic(tracks, preference, current):
            return ["operation": "automatic", "tracks": tracks.map { Self.wire($0) }, "preference": preference.rawValue, "current": current as Any]
        case let .selectSubtitle(id): return ["operation": "selectSubtitle", "id": id as Any]
        case let .selectAudio(id): return ["operation": "selectAudio", "id": id]
        case let .importSubtitle(path, name): return ["operation": "importSubtitle", "path": path, "name": name]
        case let .attachSubtitle(path, name): return ["operation": "attachSubtitle", "path": path, "name": name as Any]
        case let .removeSubtitle(track): return ["operation": "removeSubtitle", "track": Self.wire(track)]
        }
    }
    nonisolated static func wire(_ track: TrackInfo, displayName: String? = nil) -> [String: Any] {
        ["id": track.id, "kind": track.kind.rawValue, "source": track.source.rawValue,
         "selected": track.selected, "title": track.title as Any, "language": track.language as Any,
         "displayName": displayName as Any, "canRemove": track.canRemove]
    }
}

private enum TrackWorkflowError: Error { case invalidEffect(String) }
