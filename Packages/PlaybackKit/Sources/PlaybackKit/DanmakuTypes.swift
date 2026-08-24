import Foundation

/// 已装载进内核的一条弹幕轨道。
///
/// ⚠️ 只有**内核内置弹幕渲染器**才会有这个东西。App 层 overlay 路线
/// （`DanmakuRenderKit`，当前默认）不经过内核，`danmakuTracks()` 恒为空。
public struct DanmakuTrackInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let enabled: Bool
    /// 单轨时间轴校正。负值让弹幕更早出现。
    public let offset: Duration
    public let itemCount: Int
    public let name: String?
    public let source: String?

    public init(
        id: UInt64,
        enabled: Bool,
        offset: Duration,
        itemCount: Int,
        name: String?,
        source: String?
    ) {
        self.id = id
        self.enabled = enabled
        self.offset = offset
        self.itemCount = itemCount
        self.name = name
        self.source = source
    }
}

/// 内核内置弹幕渲染器的配置。
///
/// 用法：`danmakuConfig()` 读当前值 → 改要改的字段 → `setDanmakuConfig(_:)` 应用。
/// 读-改-写而不是全量构造，是因为字段是内核定义的，App 层不该假装知道所有默认值。
///
/// 不支持内核弹幕的引擎（`supportsKernelDanmaku == false`）返回全零值并忽略写入，
/// 见 `PlaybackEngine` 的默认实现。
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
    /// 引擎自定义的阴影样式原始值。
    public var shadowStyle: Int32

    public init(
        enabled: Bool = false,
        fontSize: Float = 0,
        opacity: Float = 0,
        displayArea: Float = 0,
        scrollDurationSeconds: Float = 0,
        scrollSpeedFactor: Float = 0,
        trackGapRatio: Float = 0,
        outlineWidth: Float = 0,
        shadowOffsetX: Float = 0,
        shadowOffsetY: Float = 0,
        mergeDuplicates: Bool = false,
        allowStacking: Bool = false,
        allowScrollOverwrite: Bool = false,
        maxQuantity: UInt32 = 0,
        maxLinesPerMode: UInt32 = 0,
        blockTop: Bool = false,
        blockBottom: Bool = false,
        blockScroll: Bool = false,
        shadowStyle: Int32 = 0
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
}
