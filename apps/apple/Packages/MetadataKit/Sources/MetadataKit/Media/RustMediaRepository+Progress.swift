import CoreModel
import Foundation

extension RustMediaRepository {
    func progress<Input: Encodable, Output: Decodable>(
        _ method: String, _ input: Input, as: Output.Type = Output.self
    ) throws -> Output {
        try decode("progress." + method, [
            "payloadJSON": String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
        ])
    }
    var shutdownState: Bool {
        do { return try decode("progress.lifecycle", [:]) }
        catch { Self.report(error); return true }
    }
    func shutdown() {
        do { _ = try command("progress.shutdown", [:]) } catch { Self.report(error) }
    }
    func invalidate(discardLocalProgress: Bool) {
        do { _ = try command("progress.invalidate", ["discardLocalProgress": discardLocalProgress]) }
        catch { Self.report(error) }
    }
    struct Apply: Encodable {
        var itemID: String
        var state: MediaItem.PlayState
        var persistToStore: Bool
        var now: Date
    }
    struct Applied: Decodable {
        var applied: Bool
        var fallbackItem: MediaItem?
    }
    struct Incoming: Encodable {
        var incoming: [MediaItem]
        var merged: [MediaItem]
        var rail: String?
        var requestStartedAt: Date
        var now: Date
    }
    struct Merge: Encodable {
        var items: [MediaItem]
        var requestStartedAt: Date
    }
    struct Filter: Encodable { var items: [MediaItem] }
    struct Playback: Encodable {
        var itemID: String
        var positionSeconds: Double
        var durationSeconds: Double?
        var played: Bool
    }
    struct Final: Encodable {
        var item: MediaItem
        var positionSeconds: Double
        var durationSeconds: Double?
        var recordedAt: Date
    }
    struct Began: Decodable {
        var accepted: Bool
        var revision: UInt64?
        var state: MediaItem.PlayState?
    }
    struct Newer: Encodable {
        var item: MediaItem
        var recordedAt: Date
        var confirmedAt: Date?
        var completed: Bool
        init(_ record: LocalPlaybackProgress) {
            item = record.item; recordedAt = record.recordedAt
            confirmedAt = record.confirmedAt; completed = record.completed
        }
    }
    struct Finish: Encodable {
        var itemID: String
        var revision: UInt64
        var state: MediaItem.PlayState
        var newerRecord: Newer?
        var now: Date
    }
}

extension MediaRepository {
    func recordSharedFinalProgress(
        _ rust: RustMediaRepository, item: MediaItem,
        positionSeconds: Double, durationSeconds: Double?, recordedAt: Date
    ) async {
        do {
            let begin: RustMediaRepository.Began = try rust.progress("beginFinal", RustMediaRepository.Final(
                item: item, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, recordedAt: recordedAt))
            guard begin.accepted, let revision = begin.revision, let fallback = begin.state else { return }
            var state = fallback
            var newer: RustMediaRepository.Newer?
            if let store {
                do {
                    let result = try await store.recordPlaybackProgressUpdate(
                        item: item, positionSeconds: positionSeconds,
                        durationSeconds: durationSeconds, tenant: tenant, now: recordedAt)
                    state = result.state
                    newer = result.newerRecord.map(RustMediaRepository.Newer.init)
                } catch {
                    MetadataLog.logger.warning("播放末次进度写入失败", fields: ["error": .string("\(error)")])
                }
            }
            let _: RustMediaRepository.Applied = try rust.progress("finishFinal", RustMediaRepository.Finish(
                itemID: item.id, revision: revision, state: state, newerRecord: newer, now: now()))
        } catch { RustMediaRepository.report(error) }
    }
    func filteredCompletedResume(_ items: [MediaItem]) -> [MediaItem] {
        if let rust {
            do { return try rust.progress("filterResume", RustMediaRepository.Filter(items: items)) }
            catch { RustMediaRepository.report(error); return items }
        }
        return items.filter { localProgress[$0.id]?.confirmedCompletion != true }
    }
}
