import Foundation
#if os(macOS)
import AppKit
#endif

/// 启动参数 / 环境变量入口。存在的唯一理由是**自动化验收**：
/// 显示链 + Metal surface 这条路必须真的开着窗口才走得到，没法在单元测试里覆盖，
/// 所以留一条命令行通道，让脚本能「开窗播一段 → 打印 stats → 自己退出」。
///
///     # 推荐：走 LaunchServices 的正常「打开文件」通道（文件进 .onOpenURL）
///     open --env OCPLAYER_SELFTEST_TOKEN=<内部 token> \
///          --env OCPLAYER_SELFTEST_SECONDS=9 --env OCPLAYER_SELFTEST_LOG=/tmp/ocp.log \
///          -a <产物>/OcPlayer.app <视频文件>
///
///     # 或者直接跑二进制，文件用环境变量给
///     OCPLAYER_SELFTEST_TOKEN=<内部 token> OCPLAYER_SELFTEST_SECONDS=9 \
///     OCPLAYER_SELFTEST_FILE=<视频文件> \
///       <产物>/OcPlayer.app/Contents/MacOS/OcPlayer
///
/// ⚠️ 千万别把文件路径当**命令行参数**传给 .app 里的二进制：实测 macOS 26.5 上那样启动，
/// 窗口根本不会被创建（AppKit 把它当一次打不开的「打开文档」请求，进程活着但空转）。
/// 平常双击运行时这些变量都不存在，行为与没有这段代码完全一致。
///
/// 🔒 任意一个 `OCPLAYER_SELFTEST_*` 触发都必须同时设置 `OCPLAYER_SELFTEST_TOKEN` 且与
/// 内置 `expectedToken` 常量相等；不等则静默按「无自检」处理，避免外部环境变量意外启用。
enum LaunchOptions {

    /// 公开源码后仍能跑自检的内部口令。改 token 等同吊销旧脚本的资格。
    /// （Swift 源码内联——不是用来对攻击者保密的，是防止误触发 + 给脚本一个能改的钩子。）
    private static let expectedToken = "ocp-selftest-v1"

    private static var providedTokenMatches: Bool {
        ProcessInfo.processInfo.environment["OCPLAYER_SELFTEST_TOKEN"] == expectedToken
    }

    /// 自检要播的文件，只认环境变量（命令行参数会让窗口建不起来，见类型注释）。
    static var fileFromEnvironment: URL? {
        guard providedTokenMatches else { return nil }
        return ProcessInfo.processInfo.environment["OCPLAYER_SELFTEST_FILE"]
            .map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// 自检时长（秒）。为 nil 表示正常运行，不打印也不退出。
    static var selfTestSeconds: Double? {
        guard providedTokenMatches else { return nil }
        return ProcessInfo.processInfo.environment["OCPLAYER_SELFTEST_SECONDS"].flatMap(Double.init)
    }

    /// `OCPLAYER_SELFTEST_CONTROLS=1` 时，自检期间按脚本连打 pause / seek / 倍速 / 窗口 resize。
    static var exercisesControls: Bool {
        guard providedTokenMatches else { return false }
        return ProcessInfo.processInfo.environment["OCPLAYER_SELFTEST_CONTROLS"] == "1"
    }

    /// 自检日志落盘路径。经 `open -a` 启动时进程的 stdout 不归终端，只能写文件。
    private static var logFile: URL? {
        ProcessInfo.processInfo.environment["OCPLAYER_SELFTEST_LOG"].map { URL(fileURLWithPath: $0) }
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
        guard let logFile else { return }
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: logFile, atomically: false, encoding: .utf8)
        }
    }

    @MainActor
    static func run(
        with controller: PlaybackController,
        presentPlayer: (@MainActor (URL) -> Void)? = nil
    ) async {
        if let file = fileFromEnvironment {
            // 打开交给播放覆盖层（onAppear 会 openIfNeeded），这里只负责把文件递过去
            presentPlayer?(file)
        }
        guard let seconds = selfTestSeconds else { return }

        let controls = exercisesControls ? scriptedControls(controller) : [:]
        let start = Date()
        var tick = 0
        emit("[selftest] start file=\(fileFromEnvironment?.path ?? "由 open 传入")")
        while Date().timeIntervalSince(start) < seconds {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                // 自检循环响应取消（进程退出信号会取消任务），不再继续轮询。
                emit("[selftest] cancelled")
                exit(0)
            }
            tick += 1
            if let step = controls[tick] {
                emit("[selftest] >>> \(step.0)")
                step.1()
            }
            emit("[selftest] \(controller.state.state) pos=\(controller.state.position.microseconds)µs " +
                 "dur=\(controller.state.duration.microseconds)µs surface=\(controller.state.hasSurface) " +
                 "| \(controller.statsLine())")
            if let error = controller.state.lastError { emit("[selftest] error: \(error)") }
        }
        emit("[selftest] done")
        exit(0)
    }

    /// 第 N 个 500ms 刻度上做什么。刻意把 resize 放在最后，验证「resize_surface 后还能继续上屏」。
    @MainActor
    private static func scriptedControls(
        _ controller: PlaybackController
    ) -> [Int: (String, @MainActor () -> Void)] {
        [
            4: ("pause", { controller.togglePlayPause() }),
            6: ("play", { controller.togglePlayPause() }),
            8: ("seek 3.5s", { controller.seek(toFraction: 0.7) }),
            10: ("rate 2.0", { controller.applyRate(2.0) }),
            12: ("resize window", { resizeWindow() }),
            14: ("rate 1.0 + seek 1s", {
                controller.applyRate(1.0)
                controller.seek(toFraction: 0.2)
            }),
        ]
    }

    @MainActor
    private static func resizeWindow() {
        #if os(macOS)
        // 换个非等比尺寸，逼 surface 走一次 resize + 重新算 letterbox。
        guard let window = NSApplication.shared.windows.first else { return }
        window.setContentSize(NSSize(width: 900, height: 700))
        #endif
    }
}
