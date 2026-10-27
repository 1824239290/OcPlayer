import CErika
import Darwin
import Foundation
import Metal
import QuartzCore
import Testing
import PlaybackKit
@testable import ErikaKit

/// 内核性能探针：同一把尺子量不同内核 tag 的渲染成本（如 liberika 0.3.0 的
/// 字幕超采样默认开启前 vs 后）。env 门控，CI 与普通测试零开销直通。
///
/// 跑法（90 秒本地场景 A：合成视频 + 密集 ASS 外挂字幕）：
///
///     ERIKA_PERF_PROBE=1 swift test --package-path Packages/ErikaKit --filter ErikaPerfProbeTests
///
/// 场景 B（远程真片源，经 env 注入）：
///
///     ERIKA_PERF_PROBE=1 ERIKA_PERF_MODE=remote \
///     ERIKA_PERF_URL='http://nas/Videos/<id>/stream?static=true' \
///     ERIKA_PERF_AUTH='MediaBrowser Token="..."' \
///     ERIKA_PERF_SEEK=600 \
///     swift test --package-path Packages/ErikaKit --filter ErikaPerfProbeTests
///
/// 环境变量：
/// - `ERIKA_PERF_PROBE=1`          总开关（缺省不跑）
/// - `ERIKA_PERF_MODE`             `local`（默认）/ `remote`
/// - `ERIKA_PERF_URL` / `ERIKA_PERF_AUTH`   remote 模式的媒体地址与 Authorization 头
/// - `ERIKA_PERF_SEEK`             remote 模式起播位置秒（默认 600）
/// - `ERIKA_PERF_SECONDS`          采样时长秒（默认 90）
/// - `ERIKA_PERF_CUE_SPACING`      场景 A 的 cue 间隔秒（默认 1.0；调小可复现 atlas 超限崩溃）
/// - `ERIKA_PERF_OUT`              输出文件前缀（默认 /tmp/erika-perf）
///
/// 产物：`<前缀>-samples.jsonl`（500ms 采样）+ `<前缀>-render-micros.txt`
/// （每 tick 内核渲染耗时，算分位数用）+ `<前缀>-stderr.log`（内核 stderr，
/// 超采样 >4ms 自动回退等告警都在里面）。汇总直接打 stdout。
@Suite("Erika 性能探针", .serialized)
struct ErikaPerfProbeTests {

    @Test("内核渲染成本采样（env 门控）")
    func probe() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ERIKA_PERF_PROBE"] == "1" else { return }

        let seconds = Double(env["ERIKA_PERF_SECONDS"] ?? "90") ?? 90
        let outPrefix = env["ERIKA_PERF_OUT"] ?? "/tmp/erika-perf"
        let mode = env["ERIKA_PERF_MODE"] ?? "local"

        // 内核日志走进程 stderr：先把 fd 2 摘到文件里，跑完恢复，报告时再读。
        let stderrPath = outPrefix + "-stderr.log"
        let stderrFile = fopen(stderrPath, "w")
        fflush(nil)
        let savedStderr = dup(2)
        dup2(fileno(stderrFile), 2)

        var cleanupPaths: [String] = []
        var mediaSource: PlaybackSource
        var externalASS: URL?

        if mode == "remote" {
            guard let url = env["ERIKA_PERF_URL"] else {
                fatalError("remote 模式需要 ERIKA_PERF_URL")
            }
            var headers: [String: String] = [:]
            if let auth = env["ERIKA_PERF_AUTH"] { headers["Authorization"] = auth }
            if let ua = env["ERIKA_PERF_UA"] { headers["User-Agent"] = ua }
            mediaSource = PlaybackSource(uri: url, headers: headers)
        } else {
            // 场景 A：100s 1280×720 H.264 + 密集 ASS 外挂字幕（每 250ms 一条新 cue，
            // 常态同屏 8 条、每条两行 CJK + 描边样式，worst-case 覆盖字幕栅格化）。
            let movie = try TestMedia.makeShortMovie(seconds: 100, fps: 30,
                                                     width: 1280, height: 720)
            cleanupPaths.append(movie.path)
            let ass = try Self.makeDenseASS(seconds: 100,
                                            spacing: Double(env["ERIKA_PERF_CUE_SPACING"] ?? "1.0") ?? 1.0)
            cleanupPaths.append(ass.path)
            externalASS = ass
            mediaSource = PlaybackSource(fileURL: movie)
        }

        let presenter = try ErikaPresenter()
        let width = 1280, height = 720
        let layer = CAMetalLayer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("无 Metal 设备")
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.drawableSize = CGSize(width: width, height: height)
        let raw = UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        try presenter.attachMetalLayer(raw, pixelWidth: width, pixelHeight: height, scale: 1)

        try presenter.open(mediaSource)

        var tracks = TrackCounts(video: 0, audio: 0, subtitle: 0)
        var failure: String?
        var duration: Duration?
        var subtitleTrackID: Int64 = -1
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            _ = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 120)
            while let event = try presenter.pollEvent() {
                switch event {
                case .tracksChanged(let counts): tracks = counts
                case .durationChanged(let value): duration = value
                case .failed(_, let message): failure = message ?? "unknown"
                default: break
                }
            }
            if duration != nil && tracks.video > 0 { break }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        guard duration != nil, tracks.video > 0 else {
            dup2(savedStderr, 2)
            fatalError("open 未落地：tracks=\(tracks) failure=\(failure ?? "nil")")
        }

        if let ass = externalASS {
            subtitleTrackID = try presenter.addExternalSubtitle(ass.path)
            if subtitleTrackID >= 0 {
                try presenter.selectSubtitleTrack(subtitleTrackID)
            }
        } else {
            // 远程模式：优先选 ASS/SSA 内嵌字幕轨（超采样只作用于 ASS 栅格化；
            // SRT 走的也是 libass，但样式负载更轻），没有字幕轨就裸跑。
            let allTracks = try presenter.tracks()
            let subs = allTracks.filter { $0.kind == .subtitle }
            let chosen = subs.first { ($0.codec ?? "").lowercased().contains("ss") }
                ?? subs.first
            if let chosen {
                try presenter.selectSubtitleTrack(chosen.id)
                subtitleTrackID = chosen.id
                print("· 探针选字幕轨: id=\(chosen.id) codec=\(chosen.codec ?? "?") lang=\(chosen.language ?? "?")")
            }
        }

        try presenter.play()
        if mode == "remote", let seek = Double(env["ERIKA_PERF_SEEK"] ?? "600"), seek > 0 {
            try presenter.seek(to: .seconds(seek))
        }
        // 等出首帧再开始采样（多线程软解 open 后首帧会晚 N 个 packet，不计入稳态）。
        var firstFrame = false
        let firstDeadline = Date().addingTimeInterval(30)
        while Date() < firstDeadline {
            let stats = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 120)
            while let event = try presenter.pollEvent() {
                if case .failed(_, let message) = event { failure = message ?? "unknown" }
            }
            if stats.rendered_video_frames > 0 { firstFrame = true; break }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        guard firstFrame else {
            dup2(savedStderr, 2)
            fatalError("90 秒内没等到首帧：failure=\(failure ?? "nil")")
        }

        // ---- 稳态采样：120Hz tick + 500ms 进程级采样 ----
        let samplesPath = outPrefix + "-samples.jsonl"
        let renderPath = outPrefix + "-render-micros.txt"
        let samplesFile = fopen(samplesPath, "w")
        let renderFile = fopen(renderPath, "w")

        var lastCPU = Self.cpuSeconds()
        var lastWall = CACurrentMediaTime()
        let lastStats = try presenter.stats()
        var renderedAtLastSample = lastStats.rendered_video_frames
        var maxFootprint: UInt64 = 0
        var failures = 0
        let totalTicks = Int(seconds * 120)
        let nextSampleAt = 60  // 每 60 tick 采一个进程样本（500ms）

        for tick in 0..<totalTicks {
            let now = CACurrentMediaTime()
            let stats = try presenter.renderTick(at: now + 1.0 / 120,
                                                 presentationDelay: 1.0 / 120)
            let renderLine = "\(stats.last_render_micros) \(stats.last_render_current_micros)\n"
            fwrite(renderLine, 1, renderLine.utf8.count, renderFile)
            while let event = try presenter.pollEvent() {
                if case .failed = event { failures += 1 }
            }
            if (tick + 1) % nextSampleAt == 0 {
                let wall = CACurrentMediaTime()
                let cpu = Self.cpuSeconds()
                let footprint = ProcessFootprint.current()
                maxFootprint = max(maxFootprint, footprint.physFootprintBytes)
                let wallDelta = wall - lastWall
                let cores = (cpu - lastCPU) / wallDelta
                let rendered = stats.rendered_video_frames - renderedAtLastSample
                renderedAtLastSample = stats.rendered_video_frames
                let line = """
                {"t":\(String(format: "%.3f", wall)), "cpu_cores":\(String(format: "%.3f", cores)), \
                "phys_footprint_mb":\(String(format: "%.1f", Double(footprint.physFootprintBytes) / 1048576)), \
                "rendered_fps":\(String(format: "%.1f", Double(rendered) / wallDelta)), \
                "overlay_frames":\(stats.overlay_frames), "decoded":\(stats.decoded_video_frames), \
                "sw_frames":\(stats.software_video_frames), "hw_frames":\(stats.hardware_video_frames)}\n
                """
                fwrite(line, 1, line.utf8.count, samplesFile)
                lastCPU = cpu
                lastWall = wall
            }
            // 按墙钟节流到 ~120Hz（renderTick 本身耗时，不额外 sleep 精确对齐）。
            let target = now + 1.0 / 120
            let rest = target - CACurrentMediaTime()
            if rest > 0 { Thread.sleep(forTimeInterval: rest) }
        }

        let finalStats = try presenter.stats()
        fflush(samplesFile); fflush(renderFile); fflush(stderrFile)
        dup2(savedStderr, 2)
        close(savedStderr)
        fclose(samplesFile); fclose(renderFile); fclose(stderrFile)

        // ---- 汇总 ----
        // 内核 stderr 可能混入非 UTF-8 字节，一律 lossy 解码，别让汇总自己炸掉。
        let samples = Self.readLossy(samplesPath).split(separator: "\n")
        let cores = samples.compactMap { line -> Double? in
            guard let r = line.range(of: "\"cpu_cores\":"), let v = Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." }) else { return nil }
            return v
        }.sorted()
        let p: (Double) -> Double = { q in
            guard !cores.isEmpty else { return 0 }
            return cores[min(cores.count - 1, Int(q * Double(cores.count)))]
        }
        let renderPairs = Self.readLossy(renderPath).split(separator: "\n")
            .compactMap { line -> (UInt64, UInt64)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2, let a = UInt64(parts[0]), let b = UInt64(parts[1]) else { return nil }
                return (a, b)
            }
        let renderMicros = renderPairs.map(\.0).sorted()
        let currentMicros = renderPairs.map(\.1).sorted()
        let rp: (Double) -> UInt64 = { q in
            guard !renderMicros.isEmpty else { return 0 }
            return renderMicros[min(renderMicros.count - 1, Int(q * Double(renderMicros.count)))]
        }
        let rc: (Double) -> UInt64 = { q in
            guard !currentMicros.isEmpty else { return 0 }
            return currentMicros[min(currentMicros.count - 1, Int(q * Double(currentMicros.count)))]
        }
        let stderrLines = Self.readLossy(stderrPath).split(separator: "\n")
        let alerts = stderrLines.filter {
            $0.localizedCaseInsensitiveContains("supersampl") ||
            $0.localizedCaseInsensitiveContains("fallback") ||
            $0.localizedCaseInsensitiveContains("warn") ||
            $0.localizedCaseInsensitiveContains("error")
        }

        print("""
        ===== 探针汇总（mode=\(mode), \(Int(seconds))s, 字幕轨 id=\(subtitleTrackID), tracks=\(tracks)）=====
        进程 CPU 核数: p50=\(String(format: "%.3f", p(0.5))) p95=\(String(format: "%.3f", p(0.95))) max=\(String(format: "%.3f", cores.last ?? 0))
        内核 render_tick 总耗时 µs（含等呈现）: p50=\(rp(0.5)) p95=\(rp(0.95)) p99=\(rp(0.99)) max=\(renderMicros.last ?? 0)
        内核自报 current µs（0.3.0 与总耗时同值，不是纯净工作时间，仅供跨版本对比）: p50=\(rc(0.5)) p95=\(rc(0.95)) p99=\(rc(0.99)) max=\(currentMicros.last ?? 0)
        物理内存峰值: \(String(format: "%.1f", Double(maxFootprint) / 1048576)) MB
        终态计数: decoded=\(finalStats.decoded_video_frames) rendered=\(finalStats.rendered_video_frames) \
        overlay=\(finalStats.overlay_frames) sw=\(finalStats.software_video_frames) hw=\(finalStats.hardware_video_frames)
        .failed 事件: \(failures)
        stderr 告警行（supersampl/fallback/warn/error）: \(alerts.count)
        """)
        for line in alerts.prefix(20) { print("  [stderr] \(line.prefix(300))") }

        for path in cleanupPaths { try? FileManager.default.removeItem(atPath: path) }
    }

    /// getrusage 累计 CPU 秒（user + system），差分即区间内核数。
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
             + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func readLossy(_ path: String) -> String {
        String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data(),
               as: UTF8.self)
    }

    /// 密集 ASS：每 spacing 秒一条新 cue、同屏最多 2 条（每条 2 行 CJK + 描边样式）。
    private static func makeDenseASS(seconds: Int, spacing: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-perf-\(UUID().uuidString).ass")
        var text = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1280
        PlayResY: 720

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Dial,PingFang SC,44,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2.5,1,2,60,60,40,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        // cue 间隔：默认 1s（cue 时长 2s → 同屏最多 2 条，贴近真实弹幕/字幕密度）。
        // 调小可复现崩溃：内核超采样 glyph atlas 是横向单行，宽度 ∝ 同屏字形总量 × 2，
        // 同屏字形一多（如 0.25s 间隔 × 8 并发）宽过 Metal 16384 上限即 MTL 断言 abort。
        let totalCues = Int(Double(seconds) / spacing)
        let lines = [
            "这是个用于性能采样的字幕行，包含若干常用汉字与标点。",
            "第二行同样渲染：混排 Latin123 与全角字符「测试」。",
        ]
        for index in 0..<totalCues {
            let start = Double(index) * spacing
            let end = start + 2.0
            let slot = index % 2
            // 用 MarginV 轮转 2 条「轨道」，不用 \pos——\pos 会禁掉边距换行。
            let marginV = 40 + slot * 56
            let body = lines[index % lines.count]
            text += "\nDialogue: 0,\(Self.assTime(start)),\(Self.assTime(end)),Dial,,0,0,\(marginV),,\(body)"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func assTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds - Double(Int(seconds))) * 100)
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }
}
