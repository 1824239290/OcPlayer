import CoreModel
import DanmakuKit
import JellyfinKit
import XCTest
@testable import OcPlayer

/// 弹幕匹配上下文：合成文件名、年份/类型/特典的取值。
///
/// 回归背景：Jellyfin 源文件名是裸数字（`01.mkv`）时，旧实现合成
/// `番剧名 第N季 E05 01.mkv`——实测会让弹弹play 的模糊匹配锁到「第1话」。
final class DanmakuPlaybackContextTests: XCTestCase {

    private func makeItem(
        name: String = "第5话",
        kind: MediaItem.Kind = .episode,
        seriesName: String? = "葬送的芙莉莲",
        seasonNumber: Int? = 1,
        episodeNumber: Int? = 5
    ) -> MediaItem {
        MediaItem(
            id: "item-1",
            name: name,
            kind: kind,
            seriesName: seriesName,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }

    private func makeRequest(
        title: String = "第5话",
        mediaSourcePath: String? = "/media/Anime/葬送的芙莉莲/S01/01.mkv",
        mediaSourceName: String? = "01.mkv",
        durationSeconds: Double? = 1440
    ) -> PlaybackRequest {
        PlaybackRequest(
            title: title,
            uri: "http://jellyfin.local/Videos/item-1/stream",
            authHeader: "MediaBrowser Token=x",
            sessionContext: PlaybackSessionContext(
                itemID: "item-1",
                mediaSourceID: "source-1",
                mediaSourceName: mediaSourceName,
                mediaSourcePath: mediaSourcePath,
                mediaSourceSize: 1_234_567,
                durationSeconds: durationSeconds
            )
        )
    }

    /// 裸数字文件名 + Jellyfin 番剧名 → 合成规范名，不拼回原始文件名。
    func testJellyfinSynthesizesCanonicalNameForBareNumericFile() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(), request: makeRequest(), serverProfileID: "server-1")
        XCTAssertEqual(context.fileName, "葬送的芙莉莲 第05话")
        XCTAssertEqual(context.isMovie, false)
        XCTAssertNil(context.special)
    }

    /// 原始文件名自带番剧名时保留（只剥扩展名），不打乱发布组信息。
    func testJellyfinKeepsInformativeFileName() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(),
            request: makeRequest(
                mediaSourcePath: "/media/Anime/葬送的芙莉莲/S01/[NC-Raws] 葬送的芙莉莲 - 05 [1080p].mkv",
                mediaSourceName: "[NC-Raws] 葬送的芙莉莲 - 05 [1080p].mkv"
            ),
            serverProfileID: "server-1"
        )
        XCTAssertEqual(context.fileName, "[NC-Raws] 葬送的芙莉莲 - 05 [1080p]")
    }

    /// 第二季带上季数，避免同名作品串季。
    func testJellyfinAddsSeasonForLaterSeasons() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(seasonNumber: 2, episodeNumber: 3),
            request: makeRequest(
                mediaSourcePath: "/media/Anime/碧蓝之海/S02/03.mkv", mediaSourceName: "03.mkv"),
            serverProfileID: "server-1"
        )
        XCTAssertEqual(context.fileName, "葬送的芙莉莲 第2季 第03话")
        XCTAssertEqual(context.seasonNumber, 2)
    }

    /// Jellyfin season 0 = 特典：给出特典序号与命名空间尝试顺序，文件名带 SP token。
    func testJellyfinSeasonZeroBecomesSpecialTarget() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(seasonNumber: 0, episodeNumber: 2),
            request: makeRequest(
                mediaSourcePath: "/media/Anime/来玩游戏吧/S00/SP02.mkv", mediaSourceName: "SP02.mkv"),
            serverProfileID: "server-1"
        )
        XCTAssertEqual(context.special?.index, 2)
        XCTAssertEqual(context.special?.kinds.first, .special, "SP 关键词 → 首选 S 命名空间")
        XCTAssertEqual(context.fileName, "葬送的芙莉莲 SP2")
    }

    /// 附属影像（NCOP）→ 首选 C 命名空间。
    func testJellyfinSpecialNamespaceFromKeywords() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(seasonNumber: 0, episodeNumber: 1),
            request: makeRequest(
                mediaSourcePath: "/media/Anime/碧蓝之海/S00/NCOP.mkv", mediaSourceName: "NCOP.mkv"),
            serverProfileID: "server-1"
        )
        XCTAssertEqual(context.special?.kinds, [.extra])
        XCTAssertEqual(context.fileName, "葬送的芙莉莲 C1")
    }

    /// 剧场版（kind == .movie）标记为电影目标，且不当作特典。
    func testJellyfinMovieItemIsMarkedAsMovie() {
        let context = DanmakuPlaybackContext.jellyfin(
            item: makeItem(name: "剧场版", kind: .movie, seriesName: nil, seasonNumber: nil, episodeNumber: nil),
            request: makeRequest(
                title: "剧场版", mediaSourcePath: "/media/Anime/某剧场版.mkv", mediaSourceName: "某剧场版.mkv"),
            serverProfileID: "server-1"
        )
        XCTAssertTrue(context.isMovie)
        XCTAssertNil(context.special)
    }

    /// standalone：文件名是裸数字时用父目录推断的番剧名合成规范名（旧实现直接送裸数字）。
    func testStandaloneSynthesizesCanonicalNameFromParentDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DanmakuContext-\(UUID().uuidString)/葬送的芙莉莲", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("01.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 0, count: 32))

        let context = DanmakuPlaybackContext.standalone(
            request: PlaybackRequest(title: "01.mp4", uri: file.path))
        XCTAssertEqual(context.animeTitle, "葬送的芙莉莲")
        XCTAssertEqual(context.fileName, "葬送的芙莉莲 第01话")
        XCTAssertEqual(context.episodeNumber, 1)
    }

    /// standalone：文件名自带番剧名时保留原名。
    func testStandaloneKeepsInformativeFileName() {
        let context = DanmakuPlaybackContext.standalone(
            request: PlaybackRequest(
                title: "Sousou no Frieren - 05.mkv",
                uri: "https://media.example.com/Sousou no Frieren - 05.mkv")
        )
        XCTAssertEqual(context.fileName, "Sousou no Frieren - 05")
    }

    /// standalone：文件名含 NCOP 关键词 → 特典（C 命名空间），序号缺省按第 1 集。
    func testStandaloneDetectsSpecialFromKeywords() {
        let context = DanmakuPlaybackContext.standalone(
            request: PlaybackRequest(
                title: "碧蓝之海 NCOP.mkv",
                uri: "https://media.example.com/碧蓝之海 NCOP.mkv")
        )
        XCTAssertEqual(context.special?.index, 1)
        XCTAssertEqual(context.special?.kinds, [.extra])
    }
}
