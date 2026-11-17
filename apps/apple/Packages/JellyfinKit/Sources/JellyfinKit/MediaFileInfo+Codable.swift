import Foundation

// `MediaFileInfo` 的持久化编解码。
//
// 与 `CoreModel/MediaItem+Codable.swift` 同一条约定：**解码宽容**。
// 这些结构是详情页「媒体信息」区块的数据面，字段也还在长；payload 是缓存，
// 解不出来应该当「没缓存过」重拉，而不是抛错把整块内容打掉。
// 所以每个字段一律 `decodeIfPresent(...) ?? 默认值`。
//
// 放在单独文件而不是塞进 `MediaFileInfo.swift`：那个文件是「服务端 DTO → 值类型」
// 的映射逻辑，这里纯粹是「值类型 → 落盘」的约定，两者变更原因不同。

extension MediaFileInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case video, audioTracks, subtitleTracks, container, sizeBytes, durationSeconds
        case fileName, sourceCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            video: try c.decodeIfPresent(VideoTrack.self, forKey: .video),
            audioTracks: try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? [],
            subtitleTracks: try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitleTracks) ?? [],
            container: try c.decodeIfPresent(String.self, forKey: .container),
            sizeBytes: try c.decodeIfPresent(Int.self, forKey: .sizeBytes),
            durationSeconds: try c.decodeIfPresent(Double.self, forKey: .durationSeconds),
            fileName: try c.decodeIfPresent(String.self, forKey: .fileName),
            sourceCount: try c.decodeIfPresent(Int.self, forKey: .sourceCount) ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(video, forKey: .video)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encode(subtitleTracks, forKey: .subtitleTracks)
        try c.encodeIfPresent(container, forKey: .container)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encode(sourceCount, forKey: .sourceCount)
    }
}

extension MediaFileInfo.VideoTrack: Codable {
    private enum CodingKeys: String, CodingKey {
        case codec, width, height, bitrate, frameRate, bitDepth
        case colorPrimaries, colorTransfer, colorSpace, colorRange
        case videoRangeType, profile, isInterlaced
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codec: try c.decodeIfPresent(String.self, forKey: .codec),
            width: try c.decodeIfPresent(Int.self, forKey: .width),
            height: try c.decodeIfPresent(Int.self, forKey: .height),
            bitrate: try c.decodeIfPresent(Int.self, forKey: .bitrate),
            frameRate: try c.decodeIfPresent(Double.self, forKey: .frameRate),
            bitDepth: try c.decodeIfPresent(Int.self, forKey: .bitDepth),
            colorPrimaries: try c.decodeIfPresent(String.self, forKey: .colorPrimaries),
            colorTransfer: try c.decodeIfPresent(String.self, forKey: .colorTransfer),
            colorSpace: try c.decodeIfPresent(String.self, forKey: .colorSpace),
            colorRange: try c.decodeIfPresent(String.self, forKey: .colorRange),
            videoRangeType: try c.decodeIfPresent(String.self, forKey: .videoRangeType),
            profile: try c.decodeIfPresent(String.self, forKey: .profile),
            isInterlaced: try c.decodeIfPresent(Bool.self, forKey: .isInterlaced) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(bitrate, forKey: .bitrate)
        try c.encodeIfPresent(frameRate, forKey: .frameRate)
        try c.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try c.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try c.encodeIfPresent(colorTransfer, forKey: .colorTransfer)
        try c.encodeIfPresent(colorSpace, forKey: .colorSpace)
        try c.encodeIfPresent(colorRange, forKey: .colorRange)
        try c.encodeIfPresent(videoRangeType, forKey: .videoRangeType)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encode(isInterlaced, forKey: .isInterlaced)
    }
}

extension MediaFileInfo.AudioTrack: Codable {
    private enum CodingKeys: String, CodingKey {
        case codec, channels, channelLayout, sampleRate, bitrate, language, title, isDefault
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codec: try c.decodeIfPresent(String.self, forKey: .codec),
            channels: try c.decodeIfPresent(Int.self, forKey: .channels),
            channelLayout: try c.decodeIfPresent(String.self, forKey: .channelLayout),
            sampleRate: try c.decodeIfPresent(Int.self, forKey: .sampleRate),
            bitrate: try c.decodeIfPresent(Int.self, forKey: .bitrate),
            language: try c.decodeIfPresent(String.self, forKey: .language),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            isDefault: try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encodeIfPresent(channelLayout, forKey: .channelLayout)
        try c.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try c.encodeIfPresent(bitrate, forKey: .bitrate)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(isDefault, forKey: .isDefault)
    }
}

extension MediaFileInfo.SubtitleTrack: Codable {
    private enum CodingKeys: String, CodingKey {
        case codec, language, title, isDefault, isForced, isExternal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codec: try c.decodeIfPresent(String.self, forKey: .codec),
            language: try c.decodeIfPresent(String.self, forKey: .language),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            isDefault: try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
            isForced: try c.decodeIfPresent(Bool.self, forKey: .isForced) ?? false,
            isExternal: try c.decodeIfPresent(Bool.self, forKey: .isExternal) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(isDefault, forKey: .isDefault)
        try c.encode(isForced, forKey: .isForced)
        try c.encode(isExternal, forKey: .isExternal)
    }
}
