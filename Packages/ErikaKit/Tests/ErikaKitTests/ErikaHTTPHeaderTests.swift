import CErika
import Foundation
import Testing
import PlaybackKit
@testable import ErikaKit

/// M0 第 6 步：验证 Jellyfin 直连路径 —— token 只走 HTTP 头（`open_with_headers`），不进 URL。
/// 用一个本地小服务器代替真 Jellyfin：带对 token 才给数据，否则 401。
@Suite("Erika HTTP 直连（带 token 头）", .serialized)
struct ErikaHTTPHeaderTests {

    private static let token = "test-token-not-a-secret"

    /// 仓库根目录：从本文件路径往上数 5 层（…/Packages/ErikaKit/Tests/ErikaKitTests/x.swift）。
    private static var repoRoot: URL {
        (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    }

    /// 起服务器，返回（进程, 端口）。端口自己挑：读子进程 stdout 在测试的协作线程上容易卡住，
    /// 所以改成「指定端口 + 轮询到服务器真的应答 401」这种不依赖管道的探活方式。
    private static func startServer(serving file: URL) async throws -> (Process, Int) {
        for _ in 0..<5 {
            let port = Int.random(in: 49152...65500)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3",
                                 repoRoot.appendingPathComponent("Scripts/http-token-server.py").path,
                                 file.path, token, String(port)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            if await waitUntilServing(port: port, process: process) { return (process, port) }
            process.terminate()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// 没带 token 时服务器必须回 401 —— 拿它当探活信号，顺便证明鉴权真的生效。
    private static func waitUntilServing(port: Int, process: Process) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/probe")!
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, process.isRunning {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 401 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 轮询到「拿到时长 + 视频轨」或超时；返回观察到的状态。
    private static func drain(_ presenter: ErikaPresenter, seconds: Double)
        throws -> (duration: Duration?, tracks: TrackCounts, failure: String?) {
        var duration: Duration?
        var tracks = TrackCounts(video: 0, audio: 0, subtitle: 0)
        var failure: String?
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = try? presenter.audioOnlyTick()
            while let event = try presenter.pollEvent() {
                switch event {
                case .durationChanged(let value): duration = value
                case .tracksChanged(let value): tracks = value
                case .failed(_, let message): failure = message ?? "unknown"
                default: break
                }
            }
            if failure != nil || (duration != nil && tracks.video > 0) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (duration, tracks, failure)
    }

    @Test("带 Authorization 头能打开 HTTP 源")
    func opensWithHeader() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: movie) }
        let (server, port) = try await Self.startServer(serving: movie)
        defer { server.terminate() }

        let presenter = try ErikaPresenter()
        try presenter.open(PlaybackSource(
            uri: "http://127.0.0.1:\(port)/Videos/ocplayer/stream?static=true",
            headers: ["Authorization": #"MediaBrowser Client="OcPlayer", Token="\#(Self.token)""#]
        ))

        let result = try Self.drain(presenter, seconds: 10)
        #expect(result.failure == nil, "带 token 应该能打开：\(result.failure ?? "")")
        #expect(result.tracks.video == 1, "应识别出 1 条视频轨，实际 \(result.tracks.video)")
        #expect(result.tracks.audio == 1, "应识别出 1 条音轨，实际 \(result.tracks.audio)")
        let seconds = (result.duration?.microseconds ?? 0) / 1_000_000
        #expect(seconds >= 1 && seconds <= 3, "时长应在 1–3 秒，实际 \(seconds)s")

        try presenter.close()
    }

    @Test("不带 Authorization 头会被服务器拒绝：open 当场抛 401，而不是崩")
    func failsWithoutHeader() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: movie) }
        let (server, port) = try await Self.startServer(serving: movie)
        defer { server.terminate() }

        let presenter = try ErikaPresenter()
        // 注意：HTTP 打不开时内核是**同步**抛错（不是走事件），所以 UI 层必须 catch open 的错误。
        var thrown: ErikaError?
        do {
            try presenter.open(PlaybackSource(uri: "http://127.0.0.1:\(port)/Videos/ocplayer/stream"))
        } catch let error as ErikaError {
            thrown = error
        }

        #expect(thrown != nil, "没带 token 时 open 应该抛错")
        #expect(thrown?.message?.contains("401") == true,
                "错误信息里应带上 401，实际 \(thrown?.message ?? "nil")")

        let result = try Self.drain(presenter, seconds: 1)
        #expect(result.tracks.video == 0, "401 时不该识别出视频轨")

        try? presenter.close()
    }
}
