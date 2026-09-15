import Foundation

/// 内核自带的诊断开关（`ERIKA_*` 环境变量）：设置页「详细日志」打开时一并打开。
///
/// 这些开关是内核里现成的（`strings` 内核产物即可看到）：HTTP 逐请求 trace、
/// 播放/demux trace、HDR 调试、FFmpeg 日志、字幕诊断。issue #1 的根因就是从
/// `ERIKA_HTTP_TRACE` 的逐请求记录里读出来的——此前用户现场根本没门路打开它。
///
/// 约定：
/// - trace 文件落在诊断日志目录（与 `diagnostics.jsonl` 同一个目录），导出诊断包时一并带上；
/// - 内核**在引擎创建时**读这些变量，所以切换开关要**下一次播放**（重建引擎）才生效，
///   文档与设置页文案都按这个口径写；
/// - 关掉时清变量并删掉遗留的 trace 文件（它们可能很大，且只对当次排障有用）。
enum KernelTraceSwitches {
    /// 详细档会写进日志目录的 trace 文件名（导出诊断包时按这份清单收集）。
    static let traceFileNames = ["erika_http_trace.jsonl", "erika_playback_trace.jsonl"]

    /// 启动时清掉上一轮留下的 trace 文件：它们是**按会话**的诊断产物，
    /// 不清就会跨次累积（实测 16 秒本地播放的 playback trace 已经 1.9MB）。
    static func prepareForLaunch(logDirectory: URL) {
        removeTraceFiles(in: logDirectory)
    }

    static func apply(verbose: Bool, into directory: URL) {
        for (key, value) in switches(verbose: verbose, directory: directory) {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        if !verbose {
            removeTraceFiles(in: directory)
        }
    }

    /// 键 → 值（`nil` 表示清除）。单独暴露出来便于测试与文档对账。
    ///
    /// ⚠️ 这份清单刻意只留**体量有界**的开关：
    /// - `ERIKA_FFMPEG_DEBUG`：实测 1500+ 行/秒（逐帧 NAL 日志）；
    /// - `ERIKA_SUBTITLE_DIAG`：逐帧字幕 overlay 几何（`[erika-subtitle-diag]`，
    ///   约 100 行/秒，且没有文件 sink）；
    /// 两个都会把 2MB 的轮转窗口连同 App 自己的记录一起冲掉，所以不进默认集合——
    /// 需要时手动 `ERIKA_SUBTITLE_DIAG=1 …` 启动（见 Docs/LOGGING.md）。
    ///
    /// 保留的三项都是低频或另有文件 sink 的：HTTP 逐请求 trace（文件）、
    /// playback/demux trace（文件，其 stderr 回声会被 pump 丢掉）、HDR 调试（几条）。
    static func switches(verbose: Bool, directory: URL) -> [String: String?] {
        let names = traceFileNames
        guard verbose else {
            return [
                "ERIKA_HTTP_TRACE": nil,
                "ERIKA_HTTP_TRACE_FILE": nil,
                "ERIKA_PLAYBACK_TRACE": nil,
                "ERIKA_PLAYBACK_TRACE_FILE": nil,
                "ERIKA_HDR_DEBUG": nil,
            ]
        }
        return [
            "ERIKA_HTTP_TRACE": "1",
            "ERIKA_HTTP_TRACE_FILE": directory.appendingPathComponent(names[0]).path,
            "ERIKA_PLAYBACK_TRACE": "1",
            "ERIKA_PLAYBACK_TRACE_FILE": directory.appendingPathComponent(names[1]).path,
            "ERIKA_HDR_DEBUG": "1",
        ]
    }

    private static func removeTraceFiles(in directory: URL) {
        for name in traceFileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
