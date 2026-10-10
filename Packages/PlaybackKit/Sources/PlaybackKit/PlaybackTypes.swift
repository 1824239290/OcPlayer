import Foundation

extension Duration {
    /// 截断到微秒 —— 内核的时间单位基本都是 `*_micros`，上报 / 续播 / 弹幕时钟也按微秒算。
    public var microseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}

/// 播放状态。内核各有自己的状态枚举，一律折叠到这一套。
public enum PlaybackState: Sendable, Hashable {
    case idle, opening, ready, playing, paused, stopped, closed, error
}

public struct VideoParams: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// 色彩原色 / 传输函数的原始编码值（AVCol* 语义），HDR 判定用。
    public let primaries: UInt32
    public let transfer: UInt32

    public init(width: Int, height: Int, primaries: UInt32, transfer: UInt32) {
        self.width = width
        self.height = height
        self.primaries = primaries
        self.transfer = transfer
    }

    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
    }
}

public struct TrackCounts: Sendable, Hashable {
    public let video: Int
    public let audio: Int
    public let subtitle: Int

    public init(video: Int, audio: Int, subtitle: Int) {
        self.video = video
        self.audio = audio
        self.subtitle = subtitle
    }
}

/// 内核事件。已经脱离内核内存，可跨线程传递。
///
/// 适配器负责把自己的事件模型（Erika 是轮询 `poll_event`）折叠成这一套，**并保证事件已经离开内核内存**
/// —— 有些内核的错误文本是线程局部的，必须在出错线程上就地读走。
public enum PlayerEvent: Sendable {
    case stateChanged(PlaybackState)
    case durationChanged(Duration)
    case positionChanged(Duration)
    case tracksChanged(TrackCounts)
    case bufferingChanged(Bool)
    case videoParamsChanged(VideoParams)
    case surfaceAttached
    case surfaceDetached
    case videoDecoderChanged
    case audioOutputChanged
    /// 用户选轨生效（音轨 / 字幕轨）。UI 据此重拉轨道列表拿新的 selected。
    case trackSelectionChanged
    /// 内核报错。`code` 是**引擎自定义的诊断码**，只进日志、不参与任何逻辑判断
    /// （0 表示引擎没给码）；要判断的东西请走 `stateChanged(.error)`。
    case failed(code: Int32, message: String?)
}

/// 打开一个媒体源。`headers` 由适配器落到内核的带头打开接口
/// （Erika `open_with_headers`），
/// Jellyfin 的 token 走这里，**不进 URL**（日志不泄露）。
/// `readAheadBytes` 是 HTTP 源的前向预取窗口（仅当前内核生效；nil = 内核默认（2 MiB）。
/// `backBufferBytes` 是 HTTP 源的回退预算——已播数据保留多少在缓存里，
/// 回退落在这段内就不发网络请求（nil = 内核默认 16 MiB；高码率片源建议按
/// 码率 × 期望回退时长放大）。
public struct PlaybackSource: Sendable, Hashable {
    public let uri: String
    public let headers: [String: String]
    public let readAheadBytes: UInt64?
    public let backBufferBytes: UInt64?

    public init(
        uri: String,
        headers: [String: String] = [:],
        readAheadBytes: UInt64? = nil,
        backBufferBytes: UInt64? = nil
    ) {
        self.uri = uri
        self.headers = headers
        self.readAheadBytes = readAheadBytes
        self.backBufferBytes = backBufferBytes
    }

    public init(fileURL: URL, headers: [String: String] = [:]) {
        self.init(uri: fileURL.isFileURL ? fileURL.path : fileURL.absoluteString, headers: headers)
    }
}

/// 内核当前的输出编码。动态范围标注用它区分「源是 HDR 但屏幕输出已被映射成 SDR」
/// 和「真的在出 HDR」——源侧的 `VideoParams.transfer` 不随输出变化。
public enum PlaybackOutputEncoding: String, Sendable, Hashable {
    case sdr
    case appleEdr
    case hdr10Pq
    case extendedLinear
    /// 内核未报或不适用的场合（无画面、打开中、非 Erika 内核）。
    case unknown

    /// 是否正在输出 HDR（Apple EDR 与 HDR10 PQ 都算；extended linear 亦为 HDR 路线）。
    public var isHDR: Bool {
        switch self {
        case .appleEdr, .hdr10Pq, .extendedLinear: true
        case .sdr, .unknown: false
        }
    }
}

/// 内核协商出的输出细节（`latestOutputEncoding` 只报「编码」，这里补上「为什么」）。
///
/// 回答的是同一个问题链的第二半：动态范围标注说得出「源是 HDR、实际出的是 SDR」，
/// 而**为什么会这样**在 `fallbackReason` 里——显示器不支持 HDR、面格式拿不到
/// 16 位浮点、数据空间校验失败……内核一直都在报这些码（`ErikaOutputStatus`），
/// 此前只读了 `active_encoding` 一个字段，剩下 12 个全被丢掉。
public struct PlaybackOutputSnapshot: Sendable, Hashable {
    /// 实际协商出的呈现面格式（8 位 UNORM / 10 位 UNORM / 16 位浮点）。
    public enum SurfaceFormat: String, Sendable, Hashable {
        case eightBitUnorm
        case tenBitUnorm
        case sixteenBitFloat
        case unknown
    }

    /// 请求的输出模式没能生效时的**稳定**原因码。
    ///
    /// rawValue 与内核的 `ErikaOutputFallbackReason` 一一对应（内核承诺只追加、
    /// 不重编号 0…8），所以日志与诊断包里可以直接按字符串比对。
    public enum FallbackReason: String, Sendable, Hashable, CaseIterable {
        case none
        case displayHdrUnsupported = "display_hdr_unsupported"
        case hybridCompositionRequired = "hybrid_composition_required"
        case wgpuBackendNotVulkan = "wgpu_backend_not_vulkan"
        case rgba16FloatSurfaceFormatUnavailable = "rgba16float_surface_format_unavailable"
        case nativeWindowDataSpaceApiUnavailable = "native_window_dataspace_api_unavailable"
        case scrgbDataSpaceVerificationFailed = "scrgb_dataspace_verification_failed"
        case surfaceConfigureFailed = "surface_configure_failed"
        case legacyAppleEdrUnsupported = "legacy_apple_edr_unsupported"
        /// 内核报了一个本版本不认识的码（内核比 App 新）。**不猜语义**——
        /// 猜错会把「未知」显示成确切原因，比不显示更坏。
        ///
        /// 注意与「什么都没有」的区别：中性快照（`.unknown`）用的是 `.none`，
        /// 表示「没观察到回退」；这个 case 只在**内核确实报了回退、但码不认识**时出现，
        /// UI 会照实说「回退（原因未识别）」而不是装作没事。
        case unknown
    }

    public let surfaceFormat: SurfaceFormat
    public let fallbackReason: FallbackReason
    /// 累积的回退次数（一次播放内单调递增；用于判断「一直在回退」还是「偶尔一次」）。
    public let fallbackCount: UInt64
    /// 当前有效的显示 HDR/SDR 比；`nil` = 内核不知道（macOS Metal 后端目前如此）。
    public let activeHeadroom: Float?
    /// `activeHeadroom` 是否来自权威的平台读数（Android API 34+ 才有）。
    public let activeHeadroomKnown: Bool
    /// 是否走在浮点扩展线性（Apple EDR / Android scRGB）呈现通路上。
    public let extendedLinearActive: Bool

    /// `fallbackReason` 默认 `.none`（不是 `.unknown`）：中性构造代表「没有信息、
    /// 也没观察到回退」，UI 才不会对不支持输出查询的内核显示一行「回退（原因未识别）」。
    public init(
        surfaceFormat: SurfaceFormat = .unknown,
        fallbackReason: FallbackReason = .none,
        fallbackCount: UInt64 = 0,
        activeHeadroom: Float? = nil,
        activeHeadroomKnown: Bool = false,
        extendedLinearActive: Bool = false
    ) {
        self.surfaceFormat = surfaceFormat
        self.fallbackReason = fallbackReason
        self.fallbackCount = fallbackCount
        self.activeHeadroom = activeHeadroom
        self.activeHeadroomKnown = activeHeadroomKnown
        self.extendedLinearActive = extendedLinearActive
    }

    /// 内核未报或此刻不适用（无画面、打开中、非 Erika 内核）时的中性值。
    /// 面格式 `.unknown` + 无回退：UI 据此隐藏「输出」行，而不是显示一行假数据。
    public static let unknown = PlaybackOutputSnapshot()
}

/// 亮度上采样（画质增强）档位。
///
/// 内核用神经网络对**亮度**做 2 倍重建（色度保持原生采样）：低清动画 / 老片在
/// 大屏上的观感提升明显。代价是 GPU 与显存占用，所以默认关闭、由用户显式打开。
public enum PlaybackUpscalerMode: String, Sendable, Hashable, CaseIterable {
    case off
    case artCnnC4F16
    case artCnnC4F32
    case artCnnC4F16Ds

    /// 设置页与菜单里的名字。`artCnnC4F16Ds` 的 DS 是 denoise+sharpen：
    /// 面向压缩痕迹重的动画素材。
    public var displayName: String {
        switch self {
        case .off: "关闭"
        case .artCnnC4F16: "ArtCNN F16"
        case .artCnnC4F32: "ArtCNN F32"
        case .artCnnC4F16Ds: "ArtCNN F16 去噪"
        }
    }
}

/// 上采样后端当前的实际状态：请求了什么、真正跑在什么上、回退过几次。
///
/// 存在的意义是**别把「设了」当成「生效了」**：内核在不支持的后端上会保留原生
/// 亮度采样并明确报 `inactive`（而不是悄悄什么都不做，也不是报错）。
public struct PlaybackUpscalerState: Sendable, Hashable {
    public enum Backend: String, Sendable, Hashable {
        case off
        /// 该后端不支持，已回落原生采样（设置页据此给出提示）。
        case inactive
        case building
        case scalar
        case simdgroupMatrix
        case unknown
    }

    public let requested: PlaybackUpscalerMode
    public let backend: Backend
    public let fallbackCount: UInt64
    public let upscaledFrames: UInt64

    public init(
        requested: PlaybackUpscalerMode = .off,
        backend: Backend = .off,
        fallbackCount: UInt64 = 0,
        upscaledFrames: UInt64 = 0
    ) {
        self.requested = requested
        self.backend = backend
        self.fallbackCount = fallbackCount
        self.upscaledFrames = upscaledFrames
    }

    /// 内核没报或此刻不适用时的中性值（请求关闭、后端 off）。
    public static let unknown = PlaybackUpscalerState()

    /// 请求了增强但后端跑不了：UI 要按这个提示「已回落原生采样」，
    /// 否则用户看到开关开着却毫无变化，只会以为是骗人的。
    public var isFallingBackNatively: Bool {
        requested != .off && backend == .inactive
    }
}

/// 字幕外观覆盖（选填能力：内核不做样式覆盖时下面是空操作）。
///
/// **每个字段都是可选的，nil = 不碰这一项。** 这对应内核 `ErikaSubtitleStyle` 的
/// 「回落」语义：不覆盖的字段只用于填充脚本自己没指定的部分（片源自带的 ASS
/// 样式、特效字体全部保留）；只有用户显式要求「覆盖字幕自带样式」时，才会把
/// 改过的那些项变成**替换**（内核的 `override_mask`）。
///
/// 只暴露与日常抱怨对应的字段（字幕贴边 → 位置与边距；亮场看不清 → 颜色与描边）；
/// 字距 / XY 缩放 / 模糊 / 边框样式刻意先不透出——它们要么极少用，要么一改就毁掉
/// 字幕组精心调过的排版。
public struct SubtitleStyle: Sendable, Equatable {
    /// 屏幕位置：九宫格 1…9（小键盘布局，2 = 底部居中）。
    public var alignment: Int?
    /// 垂直边距（对着底/顶边那一侧）。
    public var marginVertical: Int?
    /// 左右边距。
    public var marginLeft: Int?
    public var marginRight: Int?
    /// 正文颜色，`0xRRGGBBAA`。
    public var primaryColorRGBA: UInt32?
    /// 描边颜色，`0xRRGGBBAA`。
    public var outlineColorRGBA: UInt32?
    /// 描边粗细（ASS 脚本单位，内核钳到 0…32）。
    public var outlineWidth: Double?
    public var bold: Bool?

    public init(
        alignment: Int? = nil,
        marginVertical: Int? = nil,
        marginLeft: Int? = nil,
        marginRight: Int? = nil,
        primaryColorRGBA: UInt32? = nil,
        outlineColorRGBA: UInt32? = nil,
        outlineWidth: Double? = nil,
        bold: Bool? = nil
    ) {
        self.alignment = alignment
        self.marginVertical = marginVertical
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.primaryColorRGBA = primaryColorRGBA
        self.outlineColorRGBA = outlineColorRGBA
        self.outlineWidth = outlineWidth
        self.bold = bold
    }

    /// 一个字段都没设：调用方据此跳过下发（不发等于保持内核现状）。
    public var isEmpty: Bool { self == SubtitleStyle() }
}

/// 哪些字段要**替换**字幕自带样式（而不是只填空缺）。
///
/// 默认是空的 OptionSet：一切照旧，片源 ASS 的排版与特效原样保留。
/// 只有用户在设置页显式打开「覆盖字幕自带样式」，才把改过的项对应位置位。
public struct SubtitleStyleOverrides: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let colors = SubtitleStyleOverrides(rawValue: 1 << 0)
    public static let attributes = SubtitleStyleOverrides(rawValue: 1 << 1)
    public static let border = SubtitleStyleOverrides(rawValue: 1 << 2)
    public static let alignment = SubtitleStyleOverrides(rawValue: 1 << 3)
    public static let margins = SubtitleStyleOverrides(rawValue: 1 << 4)

    /// 用户改过的**全部**项都替换（就是「覆盖自带样式」开关的语义）。
    public static let all: SubtitleStyleOverrides = [
        .colors, .attributes, .border, .alignment, .margins,
    ]

    /// 这些覆盖项涉及的字幕字段在本仓库里有对应的可调项。
    /// 留作自检：`SubtitleStyle` 新增字段时忘了加进这里，用例会报出来。
    public static func covering(_ style: SubtitleStyle) -> SubtitleStyleOverrides {
        var mask: SubtitleStyleOverrides = []
        if style.primaryColorRGBA != nil || style.outlineColorRGBA != nil { mask.insert(.colors) }
        if style.bold != nil { mask.insert(.attributes) }
        if style.outlineWidth != nil { mask.insert(.border) }
        if style.alignment != nil { mask.insert(.alignment) }
        if style.marginVertical != nil || style.marginLeft != nil || style.marginRight != nil {
            mask.insert(.margins)
        }
        return mask
    }
}

/// 内核视角的一条轨道（视频 / 音频 / 字幕）。
/// 外挂字幕通过 `addExternalSubtitle` 加入后也会出现在列表里（`source == .external`）。
public struct TrackInfo: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case video, audio, subtitle
    }

    public enum Source: String, Hashable, Sendable {
        case embedded, external
    }

    public let id: Int64
    public let kind: Kind
    public let source: Source
    public let selected: Bool
    public let title: String?
    public let language: String?
    public let codec: String?
    /// 声道数（音轨）。
    public let channels: Int?
    /// 采样率 Hz（音轨）。
    public let sampleRate: Int?

    public init(
        id: Int64,
        kind: Kind,
        source: Source,
        selected: Bool,
        title: String?,
        language: String?,
        codec: String?,
        channels: Int?,
        sampleRate: Int?
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.selected = selected
        self.title = title
        self.language = language
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
    }

    /// 菜单里显示的一行：标题优先，没有就语言 + 编码。
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        var parts: [String] = []
        if let language, !language.isEmpty { parts.append(language) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        if kind == .audio, let channels { parts.append("\(channels)ch") }
        return parts.joined(separator: " · ")
    }
}

/// 播放调试计数器。字段是**所有内核的并集**，拿不到的留 0
/// （`debugStatsLine()` 会照原样打印 0，不做隐藏——0 和「不支持」在排查时是两回事，
/// 但这一行本来就只给开发看，稳定的列比智能省略更好读）。
public struct PlaybackStats: Sendable, Hashable {
    public var decodedVideoFrames: UInt64
    public var renderedVideoFrames: UInt64
    public var hardwareVideoFrames: UInt64
    public var softwareVideoFrames: UInt64
    public var zeroCopyVideoFrames: UInt64
    public var pushedAudioFrames: UInt64
    public var renderFailures: UInt64
    public var audioFailures: UInt64

    public init(
        decodedVideoFrames: UInt64 = 0,
        renderedVideoFrames: UInt64 = 0,
        hardwareVideoFrames: UInt64 = 0,
        softwareVideoFrames: UInt64 = 0,
        zeroCopyVideoFrames: UInt64 = 0,
        pushedAudioFrames: UInt64 = 0,
        renderFailures: UInt64 = 0,
        audioFailures: UInt64 = 0
    ) {
        self.decodedVideoFrames = decodedVideoFrames
        self.renderedVideoFrames = renderedVideoFrames
        self.hardwareVideoFrames = hardwareVideoFrames
        self.softwareVideoFrames = softwareVideoFrames
        self.zeroCopyVideoFrames = zeroCopyVideoFrames
        self.pushedAudioFrames = pushedAudioFrames
        self.renderFailures = renderFailures
        self.audioFailures = audioFailures
    }
}
