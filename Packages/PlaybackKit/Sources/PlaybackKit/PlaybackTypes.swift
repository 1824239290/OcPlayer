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
