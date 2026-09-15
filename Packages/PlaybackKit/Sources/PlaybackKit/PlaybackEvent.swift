import Foundation

/// 播放生命周期事件：**固定名字 + 固定字段**，供 grep 与脚本分析。
///
/// 设计约定（与 `PlaybackLog.event` 配套）：
/// - message 固定为 `播放事件 <name>`，字段里必带 `event=<name>`（结构化口径以字段为准）；
/// - 时间戳带毫秒、每条记录带进程级 `session`（见 DiagnosticsKit），所以
///   「一次播放的完整时间线」可以直接按 session 过滤、按时间排序读出来；
/// - 字段名用 snake_case，`*_ms` 一律毫秒整数。
///
/// 这些事件是排障的骨架：issue 里那句「播到一半就停」「频繁闪屏」要能落到
/// `stall` / `buffer.start`·`buffer.end` 上，而不是让人去猜代码路径。
public enum PlaybackEvent: String, Sendable, CaseIterable {
    /// 收到打开请求（宿主侧，真正派发内核之前）。
    case openStart = "open.start"
    /// 打开结束（成功 `ok=true`，失败 `ok=false`）；`elapsed_ms` 是这次 open 的墙钟耗时。
    case openDone = "open.done"
    /// 状态首次进 playing。**宿主近似点**：内核没有独立的「首帧已渲染」事件。
    case firstFrame = "first_frame"
    /// 开始缓冲（饿数据，画面停住等网）。
    case bufferStart = "buffer.start"
    /// 缓冲结束；`duration_ms` 是这一轮缓冲持续了多久。
    case bufferEnd = "buffer.end"
    /// 在播状态位置停住、且内核**没有**报缓冲：demux/解码卡死的信号。
    /// 检测时 `recovered=false`，位置恢复后补一条 `recovered=true`（`frozen_ms` 为总冻结时长）。
    case stall
    /// 一次 seek；`kind` 区分来源：scrub（拖进度条）/ skip（±秒）/ chapter（章节）/
    /// auto（跳过片头片尾）/ resume（续播定位）。
    case seek
    /// 内核报错事件；`code` 是引擎自定义诊断码，`message` 是内核原文。
    case error
    /// 本会话结束（`reason`：user / superseded / failed），带整段汇总。
    case sessionEnd = "session.end"
}
