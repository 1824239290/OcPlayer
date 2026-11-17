from pathlib import Path
p=Path('/Users/jumusu/Documents/project/OcPlayer/Packages/JellyfinKit/Sources/JellyfinKit/RustCoreMediaServer.swift');s=p.read_text()
a=s.index('        let payload: RustMediaItemsEnvelope',s.index('public func externalSubtitles(itemID: String, mediaSourceID:'))
b=s.index('    public func downloadSubtitle',a)
s=s[:a]+'''        let payload: RustSubtitlePayload = try await dataAsync("media.subtitles", args)
        return payload.subtitles.map { subtitle in
            ExternalSubtitle(itemID: itemID, mediaSourceID: subtitle.mediaSourceID,
                namespace: ExternalSubtitle.namespace(profile: profile), index: subtitle.index,
                title: subtitle.title, language: subtitle.language, codec: subtitle.codec)
        }
    }
'''+s[b:]
a=s.index('        let payload: RustMediaItemsEnvelope',s.index('public func mediaFileInfo'))
b=s.index('    public func playbackInfo',a)
s=s[:a]+'''        let payload: RustFileInfoPayload = try await dataAsync("media.fileInfo", ["itemId": itemID])
        return payload.fileInfo
    }
'''+s[b:]
a=s.index('private struct RustMediaItemsEnvelope:')
b=s.index('private struct RustOptionalURLPayload:',a)
s=s[:a]+'''private struct RustSubtitlePayload: Decodable {
    let subtitles: [RustExternalSubtitle]
}
private struct RustExternalSubtitle: Decodable {
    let mediaSourceID: String?
    let index: Int
    let codec: String
    let title: String?
    let language: String?
    private enum CodingKeys: String, CodingKey {
        case mediaSourceID = "mediaSourceId"
        case index, codec, title, language
    }
}
private struct RustFileInfoPayload: Decodable {
    let fileInfo: MediaFileInfo?
}

'''+s[b:]
a=s.index('    func decodeFirstPresent<T:')
b=s.index('    func decodeFirst<T:',a)
s=s[:a]+s[b:]
a=s.index('    func decodeLossyDouble(')
b=s.index('\n    }',a)+6
s=s[:a]+s[b:]
p.write_text(s)
