import CoreModel
import Foundation

extension EmbyUserDataDTO {
    /// 与 Jellyfin 侧同口径（见 `MediaItem.PlayState.init(played:playedPercentage:…)`）。
    var domainPlayState: MediaItem.PlayState {
        MediaItem.PlayState(
            played: played,
            playedPercentage: playedPercentage,
            playbackPositionTicks: playbackPositionTicks,
            unplayedItemCount: unplayedItemCount
        )
    }
}

extension EmbyItemDTO {
    /// Emby 宽松 DTO → 共享中间表示。脏枚举值在这里落到 `.other` / `.unknown`，
    /// 而不是在解码阶段抛错。
    var serverFields: ServerItemFields {
        var fields = ServerItemFields()
        fields.kindTag = type
        fields.id = id
        fields.name = name
        fields.kind = MediaItem.Kind(serverTypeString: type)
        fields.overview = overview
        fields.productionYear = productionYear
        fields.runtimeTicks = runTimeTicks
        fields.genres = genres ?? []
        fields.communityRating = communityRating
        fields.officialRating = officialRating
        fields.seriesID = seriesId
        fields.seriesName = seriesName
        fields.seasonID = seasonId
        fields.seasonName = seasonName
        fields.parentIndexNumber = parentIndexNumber
        fields.indexNumber = indexNumber
        fields.playState = userData?.domainPlayState
        fields.cast = (people ?? []).compactMap { person in
            guard let id = person.id, let name = person.name else { return nil }
            // Emby 不保证给 Type；缺了按 Actor 处理，与 Jellyfin 侧同口径。
            return MediaItem.Person(id: id, name: name, role: person.role, kind: person.type ?? "Actor")
        }
        fields.childCount = childCount
        fields.imageTags = imageTags ?? [:]
        fields.backdropImageTags = backdropImageTags ?? []
        fields.albumPrimaryImageTag = albumPrimaryImageTag
        fields.seriesPrimaryImageTag = seriesPrimaryImageTag
        fields.parentLogoImageTag = parentLogoImageTag
        fields.parentLogoItemID = parentLogoItemId
        fields.providerIDs = providerIds ?? [:]
        return fields
    }

    var domainItem: MediaItem { serverFields.domainItem }
}

extension EmbyMediaSourceDTO {
    var domainSource: PlaybackMediaSource {
        PlaybackMediaSource(
            id: id ?? "",
            name: name,
            path: path,
            size: size,
            container: container,
            supportsDirectPlay: supportsDirectPlay,
            supportsDirectStream: supportsDirectStream,
            supportsTranscoding: supportsTranscoding,
            bitrate: bitrate,
            runTimeSeconds: seconds(fromTicks: runTimeTicks),
            videoRangeType: mediaStreams?
                .first { $0.type == "Video" }?
                .videoRangeType
        )
    }

    func domainFileInfo(sourceCount: Int) -> MediaFileInfo {
        MediaFileInfo(
            video: mediaStreams?.first { $0.type == "Video" }.map(\.domainVideoTrack),
            audioTracks: (mediaStreams ?? []).filter { $0.type == "Audio" }.map(\.domainAudioTrack),
            subtitleTracks: (mediaStreams ?? []).filter { $0.type == "Subtitle" }.map(\.domainSubtitleTrack),
            container: container,
            sizeBytes: size,
            durationSeconds: seconds(fromTicks: runTimeTicks),
            fileName: MediaFileInfo.fileName(fromPath: path),
            sourceCount: sourceCount
        )
    }
}

extension EmbyMediaStreamDTO {
    var domainVideoTrack: MediaFileInfo.VideoTrack {
        MediaFileInfo.VideoTrack(
            codec: codec,
            width: width,
            height: height,
            bitrate: bitRate,
            // 平均帧率优先，缺失或离谱时回退实时帧率（与 Jellyfin 侧同一套判据）。
            frameRate: MediaFileInfo.VideoTrack.resolveFrameRate(average: averageFrameRate, real: realFrameRate),
            bitDepth: bitDepth,
            colorPrimaries: colorPrimaries,
            colorTransfer: colorTransfer,
            colorSpace: colorSpace,
            colorRange: colorRange,
            videoRangeType: videoRangeType,
            profile: profile,
            isInterlaced: isInterlaced ?? false
        )
    }

    var domainAudioTrack: MediaFileInfo.AudioTrack {
        MediaFileInfo.AudioTrack(
            codec: codec,
            channels: channels,
            channelLayout: channelLayout,
            sampleRate: sampleRate,
            bitrate: bitRate,
            language: language,
            title: title,
            isDefault: isDefault ?? false
        )
    }

    var domainSubtitleTrack: MediaFileInfo.SubtitleTrack {
        MediaFileInfo.SubtitleTrack(
            codec: codec,
            language: language,
            title: title,
            isDefault: isDefault ?? false,
            isForced: isForced ?? false,
            isExternal: isExternal ?? false
        )
    }
}

extension EmbyMediaStreamDTO {
    /// 外挂文本字幕 → 域模型；内封 / 图像字幕（PGS 等内核不吃）返回 nil。
    func domainSubtitle(itemID: String, mediaSourceID: String?) -> ExternalSubtitle? {
        guard type == "Subtitle",
              isExternal == true,
              let index,
              let codec = codec?.lowercased(),
              ExternalSubtitle.fileExtension(forCodec: codec) != nil
        else { return nil }
        return ExternalSubtitle(
            itemID: itemID,
            mediaSourceID: mediaSourceID,
            index: index,
            title: title ?? displayTitle,
            language: language,
            codec: codec
        )
    }
}
