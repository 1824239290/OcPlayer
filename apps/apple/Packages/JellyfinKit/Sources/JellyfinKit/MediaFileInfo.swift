import Foundation
import Get
import JellyfinAPI

/// 一个条目的**文件级**媒体信息（服务端元数据，不是解码后的运行时数据）。
///
/// 与 `PlaybackMediaSource` 的分工：那个服务于开播协商（`POST PlaybackInfo`，
/// 会建播放会话），这里服务于浏览期的「这一集是什么文件」展示。走
/// `GET /Items?ids=&fields=MediaSources` 读取——**不建会话**，在详情页翻看
/// 不该在服务端留下会话记录。
///
/// 展示的是「实际会播的那一份」：多版本条目按开播同款规则选源
/// （`MediaSourceSelection`），版本数由 `sourceCount` 带给 UI。
///
/// 构造刻意分两条：一条收纯值（Emby 的裸 DTO 用），一条收 Jellyfin SDK 的
/// `MediaSourceInfo`。域模型本身不依赖任何一家的 wire 类型。
public struct MediaFileInfo: Hashable, Sendable {

    /// 视频流。多视频流只取第一条（Jellyfin 条目几乎都是单视频流）。
    public struct VideoTrack: Hashable, Sendable {
        public let codec: String?
        public let width: Int?
        public let height: Int?
        public let bitrate: Int?
        /// 平均帧率优先，缺失或离谱时回退实时帧率。
        public let frameRate: Double?
        public let bitDepth: Int?
        public let colorPrimaries: String?
        public let colorTransfer: String?
        public let colorSpace: String?
        public let colorRange: String?
        /// 服务端原始串（SDR / HDR10 / DOVI / DOVIWithHDR10…），nil 表示未知。
        public let videoRangeType: String?
        /// 编码 profile，如 "Main 10"、"High"。
        public let profile: String?
        public let isInterlaced: Bool

        init(codec: String?, width: Int?, height: Int?, bitrate: Int?, frameRate: Double?,
             bitDepth: Int?, colorPrimaries: String?, colorTransfer: String?, colorSpace: String?,
             colorRange: String?, videoRangeType: String?, profile: String?, isInterlaced: Bool) {
            self.codec = codec
            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.frameRate = frameRate
            self.bitDepth = bitDepth
            self.colorPrimaries = colorPrimaries
            self.colorTransfer = colorTransfer
            self.colorSpace = colorSpace
            self.colorRange = colorRange
            self.videoRangeType = videoRangeType
            self.profile = profile
            self.isInterlaced = isInterlaced
        }

        init(_ stream: MediaStream) {
            self.init(
                codec: stream.codec,
                width: stream.width,
                height: stream.height,
                bitrate: stream.bitRate,
                frameRate: Self.resolveFrameRate(
                    average: stream.averageFrameRate.map(Double.init),
                    real: stream.realFrameRate.map(Double.init)
                ),
                bitDepth: stream.bitDepth,
                colorPrimaries: stream.colorPrimaries,
                colorTransfer: stream.colorTransfer,
                colorSpace: stream.colorSpace,
                colorRange: stream.colorRange,
                videoRangeType: stream.videoRangeType?.rawValue,
                profile: stream.profile,
                isInterlaced: stream.isInterlaced == true
            )
        }

        /// 平均帧率优先；缺失或超出合理区间（老服务端偶有脏值）时回退实时帧率。
        /// 两家服务端共用这一套判据。
        static func resolveFrameRate(average: Double?, real: Double?) -> Double? {
            if let average, average > 0, average < 1000 { return average }
            if let real, real > 0, real < 1000 { return real }
            return nil
        }
    }

    public struct AudioTrack: Hashable, Sendable {
        public let codec: String?
        public let channels: Int?
        /// 声道布局，如 "5.1"、"stereo"。
        public let channelLayout: String?
        /// 采样率 Hz。
        public let sampleRate: Int?
        public let bitrate: Int?
        public let language: String?
        public let title: String?
        public let isDefault: Bool

        init(codec: String?, channels: Int?, channelLayout: String?, sampleRate: Int?,
             bitrate: Int?, language: String?, title: String?, isDefault: Bool) {
            self.codec = codec
            self.channels = channels
            self.channelLayout = channelLayout
            self.sampleRate = sampleRate
            self.bitrate = bitrate
            self.language = language
            self.title = title
            self.isDefault = isDefault
        }

        init(_ stream: MediaStream) {
            self.init(
                codec: stream.codec,
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                sampleRate: stream.sampleRate,
                bitrate: stream.bitRate,
                language: stream.language,
                title: stream.title,
                isDefault: stream.isDefault == true
            )
        }
    }

    public struct SubtitleTrack: Hashable, Sendable {
        public let codec: String?
        public let language: String?
        public let title: String?
        public let isDefault: Bool
        public let isForced: Bool
        /// 侧车文件（不在容器里）；内封字幕为 false。
        public let isExternal: Bool

        init(codec: String?, language: String?, title: String?,
             isDefault: Bool, isForced: Bool, isExternal: Bool) {
            self.codec = codec
            self.language = language
            self.title = title
            self.isDefault = isDefault
            self.isForced = isForced
            self.isExternal = isExternal
        }

        init(_ stream: MediaStream) {
            self.init(
                codec: stream.codec,
                language: stream.language,
                title: stream.title,
                isDefault: stream.isDefault == true,
                isForced: stream.isForced == true,
                isExternal: stream.isExternal == true
            )
        }
    }

    public let video: VideoTrack?
    public let audioTracks: [AudioTrack]
    public let subtitleTracks: [SubtitleTrack]
    /// 容器格式（mkv / mp4 / ts…）。
    public let container: String?
    public let sizeBytes: Int?
    public let durationSeconds: Double?
    /// 文件名（服务端路径的最后一段）。只带文件名不带完整路径：详情页是浏览面，
    /// 没必要把服务器目录结构摊出来。
    public let fileName: String?
    /// 该条目的媒体源数量（同一集挂多个版本时 > 1）。
    public let sourceCount: Int

    init(video: VideoTrack?, audioTracks: [AudioTrack], subtitleTracks: [SubtitleTrack],
         container: String?, sizeBytes: Int?, durationSeconds: Double?, fileName: String?,
         sourceCount: Int) {
        self.video = video
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.container = container
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.fileName = fileName
        self.sourceCount = sourceCount
    }

    init(source: MediaSourceInfo, sourceCount: Int) {
        let streams = source.mediaStreams ?? []
        self.init(
            video: streams.first { $0.type == .video }.map(VideoTrack.init),
            audioTracks: streams.filter { $0.type == .audio }.map(AudioTrack.init),
            subtitleTracks: streams.filter { $0.type == .subtitle }.map(SubtitleTrack.init),
            container: source.container,
            sizeBytes: source.size,
            durationSeconds: seconds(fromTicks: source.runTimeTicks),
            fileName: Self.fileName(fromPath: source.path),
            sourceCount: sourceCount
        )
    }

    /// 服务端路径 → 展示用文件名（只取最后一段）。
    static func fileName(fromPath path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

extension JellyfinServer {

    /// 条目的文件级媒体信息。没有媒体源（目录 / 合集条目、或老服务端不返回
    /// MediaStreams）返回 nil，调用方据此整块不渲染。
    ///
    /// 与 `externalSubtitles` 走同一条 `GET /Items` 路由：显式带 `MediaSources`
    /// field 才拿得到流信息，且**不建播放会话**。
    public func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? {
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                fields: [.mediaSources],
                ids: [itemID]
            ))
        )
        let sources = result.items?.first?.mediaSources ?? []
        guard let index = MediaSourceSelection.preferredIndex(
            count: sources.count,
            supportsDirectPlay: { sources[$0].isSupportsDirectPlay == true },
            supportsDirectStream: { sources[$0].isSupportsDirectStream == true }
        ) else { return nil }
        return MediaFileInfo(source: sources[index], sourceCount: sources.count)
    }
}
