import CErika
import Foundation

/// A named danmaku source loaded into the player.
public struct DanmakuTrackInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let enabled: Bool
    /// Per-track timeline adjustment. Negative values move comments earlier.
    public let offset: Duration
    public let itemCount: Int
    public let name: String?
    public let source: String?

    init(_ raw: ErikaDanmakuTrackInfo) {
        id = raw.id
        enabled = raw.enabled
        offset = .microseconds(raw.offset_micros)
        itemCount = Int(raw.item_count)
        name = raw.name.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        source = raw.source.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Rendering and filtering settings owned by Erika's danmaku renderer.
///
/// Read the engine's current value with `ErikaEngine.danmakuConfig()`, mutate
/// the desired fields, then apply it with `setDanmakuConfig(_:)`.
public struct DanmakuConfig: Hashable, Sendable {
    public var enabled: Bool
    public var fontSize: Float
    public var opacity: Float
    public var displayArea: Float
    public var scrollDurationSeconds: Float
    public var scrollSpeedFactor: Float
    public var trackGapRatio: Float
    public var outlineWidth: Float
    public var shadowOffsetX: Float
    public var shadowOffsetY: Float
    public var mergeDuplicates: Bool
    public var allowStacking: Bool
    public var allowScrollOverwrite: Bool
    public var maxQuantity: UInt32
    public var maxLinesPerMode: UInt32
    public var blockTop: Bool
    public var blockBottom: Bool
    public var blockScroll: Bool
    /// Erika-defined raw shadow style value.
    public var shadowStyle: Int32

    public init(
        enabled: Bool,
        fontSize: Float,
        opacity: Float,
        displayArea: Float,
        scrollDurationSeconds: Float,
        scrollSpeedFactor: Float,
        trackGapRatio: Float,
        outlineWidth: Float,
        shadowOffsetX: Float,
        shadowOffsetY: Float,
        mergeDuplicates: Bool,
        allowStacking: Bool,
        allowScrollOverwrite: Bool,
        maxQuantity: UInt32,
        maxLinesPerMode: UInt32,
        blockTop: Bool,
        blockBottom: Bool,
        blockScroll: Bool,
        shadowStyle: Int32
    ) {
        self.enabled = enabled
        self.fontSize = fontSize
        self.opacity = opacity
        self.displayArea = displayArea
        self.scrollDurationSeconds = scrollDurationSeconds
        self.scrollSpeedFactor = scrollSpeedFactor
        self.trackGapRatio = trackGapRatio
        self.outlineWidth = outlineWidth
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.mergeDuplicates = mergeDuplicates
        self.allowStacking = allowStacking
        self.allowScrollOverwrite = allowScrollOverwrite
        self.maxQuantity = maxQuantity
        self.maxLinesPerMode = maxLinesPerMode
        self.blockTop = blockTop
        self.blockBottom = blockBottom
        self.blockScroll = blockScroll
        self.shadowStyle = shadowStyle
    }

    init(_ raw: ErikaDanmakuConfig) {
        self.init(
            enabled: raw.enabled,
            fontSize: raw.font_size,
            opacity: raw.opacity,
            displayArea: raw.display_area,
            scrollDurationSeconds: raw.scroll_duration_seconds,
            scrollSpeedFactor: raw.scroll_speed_factor,
            trackGapRatio: raw.track_gap_ratio,
            outlineWidth: raw.outline_width,
            shadowOffsetX: raw.shadow_offset_x,
            shadowOffsetY: raw.shadow_offset_y,
            mergeDuplicates: raw.merge_duplicates,
            allowStacking: raw.allow_stacking,
            allowScrollOverwrite: raw.allow_scroll_overwrite,
            maxQuantity: raw.max_quantity,
            maxLinesPerMode: raw.max_lines_per_mode,
            blockTop: raw.block_top,
            blockBottom: raw.block_bottom,
            blockScroll: raw.block_scroll,
            shadowStyle: raw.shadow_style
        )
    }

    var rawValue: ErikaDanmakuConfig {
        ErikaDanmakuConfig(
            enabled: enabled,
            font_size: fontSize,
            opacity: opacity,
            display_area: displayArea,
            scroll_duration_seconds: scrollDurationSeconds,
            scroll_speed_factor: scrollSpeedFactor,
            track_gap_ratio: trackGapRatio,
            outline_width: outlineWidth,
            shadow_offset_x: shadowOffsetX,
            shadow_offset_y: shadowOffsetY,
            merge_duplicates: mergeDuplicates,
            allow_stacking: allowStacking,
            allow_scroll_overwrite: allowScrollOverwrite,
            max_quantity: maxQuantity,
            max_lines_per_mode: maxLinesPerMode,
            block_top: blockTop,
            block_bottom: blockBottom,
            block_scroll: blockScroll,
            shadow_style: shadowStyle
        )
    }
}

extension ErikaPresenter {
    /// Replace all current danmaku with one anonymous Bilibili XML source.
    func loadDanmaku(fileURI: String) throws {
        try ErikaError.check(erika_presenter_load_danmaku_file(handle, fileURI))
    }

    /// Replace all current danmaku with one anonymous inline JSON source.
    func loadDanmaku(json: String) throws {
        try ErikaError.check(erika_presenter_load_danmaku_json(handle, json))
    }

    /// Add a named Bilibili XML source and return its track identifier.
    @discardableResult
    func addDanmakuTrack(
        fileURI: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        var trackID: UInt64 = 0
        try ErikaError.check(
            erika_presenter_add_danmaku_track_file(
                handle,
                fileURI,
                name,
                offset.microseconds,
                &trackID
            )
        )
        return trackID
    }

    /// Add a named inline JSON source and return its track identifier.
    @discardableResult
    func addDanmakuTrack(
        json: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        var trackID: UInt64 = 0
        try ErikaError.check(
            erika_presenter_add_danmaku_track_json(
                handle,
                json,
                name,
                offset.microseconds,
                &trackID
            )
        )
        return trackID
    }

    func removeDanmakuTrack(_ id: UInt64) throws {
        try ErikaError.check(erika_presenter_remove_danmaku_track(handle, id))
    }

    func setDanmakuTrack(_ id: UInt64, enabled: Bool) throws {
        try ErikaError.check(erika_presenter_set_danmaku_track_enabled(handle, id, enabled))
    }

    func setDanmakuTrack(_ id: UInt64, offset: Duration) throws {
        try ErikaError.check(
            erika_presenter_set_danmaku_track_offset(handle, id, offset.microseconds)
        )
    }

    func setDanmakuGlobalOffset(_ offset: Duration) throws {
        try ErikaError.check(
            erika_presenter_set_danmaku_global_offset(handle, offset.microseconds)
        )
    }

    /// Enumerate every named and anonymous danmaku source.
    func danmakuTracks() throws -> [DanmakuTrackInfo] {
        var needed = 0
        try ErikaError.check(erika_presenter_danmaku_tracks(handle, nil, 0, &needed))
        guard needed > 0 else { return [] }

        var raw = [ErikaDanmakuTrackInfo](repeating: ErikaDanmakuTrackInfo(), count: needed)
        var filled = 0
        let status = erika_presenter_danmaku_tracks(handle, &raw, UInt(needed), &filled)
        let count = min(filled, raw.count)
        defer {
            for index in 0..<count {
                erika_danmaku_track_info_free(&raw[index])
            }
        }
        try ErikaError.check(status)
        return raw.prefix(count).map(DanmakuTrackInfo.init)
    }

    func clearDanmaku() throws {
        try ErikaError.check(erika_presenter_clear_danmaku(handle))
    }

    func setDanmakuEnabled(_ enabled: Bool) throws {
        try ErikaError.check(erika_presenter_set_danmaku_enabled(handle, enabled))
    }

    func danmakuConfig() throws -> DanmakuConfig {
        var raw = ErikaDanmakuConfig()
        try ErikaError.check(erika_presenter_get_danmaku_config(handle, &raw))
        return DanmakuConfig(raw)
    }

    func setDanmakuConfig(_ config: DanmakuConfig) throws {
        try ErikaError.check(erika_presenter_set_danmaku_config(handle, config.rawValue))
    }

    /// Select the preferred danmaku font. Passing nil clears that half of the selection.
    func setDanmakuFont(family: String?, filePath: String?) throws {
        try withOptionalCString(family) { familyPointer in
            try withOptionalCString(filePath) { filePointer in
                try ErikaError.check(
                    erika_presenter_set_danmaku_font(handle, familyPointer, filePointer)
                )
            }
        }
    }

    /// Apply Erika's block-word JSON format without exposing CErika to callers.
    func setDanmakuBlockWords(json: String) throws {
        try ErikaError.check(erika_presenter_set_danmaku_block_words_json(handle, json))
    }
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let value else { return try body(nil) }
    return try value.withCString(body)
}
