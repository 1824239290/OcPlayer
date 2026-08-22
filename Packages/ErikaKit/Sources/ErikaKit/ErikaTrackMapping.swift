import CErika
import Foundation
import PlaybackKit

// Erika 的 C 轨道结构 → PlaybackKit 的 `TrackInfo`，以及 presenter 侧的轨道调用。

extension TrackInfo {
    init(_ raw: ErikaTrackInfo) {
        let kind: Kind
        switch raw.kind {
        case ErikaTrackKind_Audio: kind = .audio
        case ErikaTrackKind_Subtitle: kind = .subtitle
        default: kind = .video
        }
        let source: Source = raw.source == ErikaTrackSource_External ? .external : .embedded
        self.init(
            id: raw.id,
            kind: kind,
            source: source,
            selected: raw.selected,
            title: raw.title.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            language: raw.language.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            codec: raw.codec.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            channels: raw.channels > 0 ? Int(raw.channels) : nil,
            sampleRate: raw.sample_rate > 0 ? Int(raw.sample_rate) : nil
        )
    }

    static func populatedCount(_ filled: Int, capacity: Int) -> Int {
        min(filled, capacity)
    }
}

extension ErikaPresenter {
    /// 全量轨道列表。计数数组两段式：capacity 0 先探总数（返回 Ok），再取数据；
    /// 每条 filled 记录里的 char* 由内核分配，必须逐条 `erika_track_info_free`。
    public func tracks() throws -> [TrackInfo] {
        var needed = 0
        try ErikaError.check(erika_presenter_tracks(handle, nil, 0, &needed))
        guard needed > 0 else { return [] }

        var raw = [ErikaTrackInfo](repeating: ErikaTrackInfo(), count: needed)
        var filled = 0
        let status = erika_presenter_tracks(handle, &raw, UInt(needed), &filled)
        let count = TrackInfo.populatedCount(filled, capacity: raw.count)
        defer {
            for index in 0..<count {
                erika_track_info_free(&raw[index])
            }
        }
        try ErikaError.check(status)
        return raw.prefix(count).map(TrackInfo.init)
    }

    /// 选音轨。
    public func selectAudioTrack(_ id: Int64) throws {
        try ErikaError.check(erika_presenter_select_audio_track(handle, id))
    }

    /// 选字幕轨；`nil` / -1 关闭字幕。
    public func selectSubtitleTrack(_ id: Int64?) throws {
        try ErikaError.check(erika_presenter_select_subtitle_track(handle, id ?? -1))
    }

    /// 外挂字幕（srt / ass 等内核支持的格式，本地路径或 URL），返回新轨道 id。
    @discardableResult
    public func addExternalSubtitle(_ uri: String) throws -> Int64 {
        var trackID: Int64 = -1
        try ErikaError.check(erika_presenter_add_external_subtitle(handle, uri, &trackID))
        return trackID
    }
}
