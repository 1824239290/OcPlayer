import CoreModel
import Foundation
import JellyfinKit

@testable import MetadataKit

/// 测试夹具：临时目录（真 SQLite 文件，不用内存库——WAL / 迁移 / 损坏自愈
/// 都只有真文件才测得出来）。
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// 造一条测试条目。默认给全必须字段，用例只覆盖自己关心的部分。
func makeItem(
    id: String,
    name: String = "未命名",
    kind: MediaItem.Kind = .movie,
    year: Int? = nil,
    seriesID: String? = nil,
    seasonNumber: Int? = nil,
    episodeNumber: Int? = nil,
    playState: MediaItem.PlayState? = nil,
    tmdbID: String? = nil
) -> MediaItem {
    MediaItem(
        id: id, name: name, kind: kind, year: year,
        seriesID: seriesID, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
        playState: playState, tmdbID: tmdbID)
}

/// 一个最小可用的服务器档案（租户 id 从它派生）。
func makeProfile(
    serverID: String = "srv",
    userID: String = "user",
    kind: ServerKind = .jellyfin
) -> ServerProfile {
    ServerProfile(
        id: "\(serverID):\(userID)",
        serverName: "test",
        baseURL: URL(string: "http://stub.local:8096")!,
        userID: userID,
        kind: kind)
}
