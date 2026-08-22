import Foundation
import SwiftUI

/// 一个播放内核的统一接口。App 层只认这个协议，不认具体内核。
///
/// ## 边界画在哪
///
/// **画面承载的边界是「整个视图」（`makeSurfaceView()`），不是「layer + 每帧 tick」。**
/// 这是唯一能同时容纳几种内核的粒度：
///
/// | 内核 | 谁建 layer | 谁驱动渲染 |
/// |---|---|---|
/// | Erika | 宿主（`CAMetalLayer`） | 宿主（`CADisplayLink` → `render_tick`） |
/// | libmpv + render API | 宿主（GL layer） | 宿主（→ `mpv_render_context_render`） |
/// | libmpv + `--wid` | **内核自己** | **内核自己** |
///
/// 所以 attach / resize / detach / 帧驱动 / 呈现时间语义全部是**适配器内部实现**，
/// 一个都不出现在这个协议里。连续 resize 合并、DPI 变化处理同理。
///
/// ## 刻意不放进协议的东西
///
/// - `close()`：Erika 的 close 是终态（close 后不能 reopen），mpv 没这个概念。
///   把它抽象出来只会把一个内核的地雷变成所有内核的地雷。要用就 downcast。
/// - `audioOnlyTick()`：只有宿主驱动帧的内核需要，且 App 层从未调用过。
/// - HDR output mode / EDR headroom / ArtCNN upscaler / 字幕样式覆盖 / 内存字体：
///   Erika 有，App 从未使用。**抽象取交集，不取并集**——否则新适配器要写一堆空实现。
///
/// ## 线程约定
///
/// 协议**不要求**内核内部同步：串行化（如果需要）是适配器的责任。
/// Erika 的句柄没有内部同步，`ErikaEngine` 用锁串起来；libmpv 本身线程安全，
/// 适配器不用加锁。调用方可以从任意线程调用本协议的方法。
public protocol PlaybackEngine: AnyObject, Sendable {

    // MARK: - 身份

    /// 这个引擎实例对应的内核描述（设置页显示、诊断日志用）。
    static var descriptor: PlaybackEngineDescriptor { get }

    // MARK: - 事件与采样

    /// 内核事件流。**单播**——由 `PlayerState` 独占消费。
    var events: AsyncStream<PlayerEvent> { get }

    /// 最近一次内核位置事件的媒体时间（任意线程可读）。
    ///
    /// App 层弹幕 overlay 用自己的采样时钟读它决定「谁该出场」：暂停 / 缓冲时
    /// 媒体时间冻结，采样值跟着冻结。**适配器必须保证这个读取不会和渲染 / 解码
    /// 抢同一把重锁**——overlay 是 30Hz 采样，被一整帧阻塞会表现成视频掉帧。
    var latestMediaTime: Duration { get }

    /// 最近一次的调试计数器快照（任意线程可读）。
    var latestStats: PlaybackStats { get }

    /// 首帧是否已经出画（播放 loading 覆盖层撤掉的判据）。
    ///
    /// ⚠️ **必须是协议要求，不能只放在扩展里**：调用点持有的是 `any PlaybackEngine`，
    /// 扩展里的实现是静态派发，适配器的重写永远不会被调到。
    /// 实测踩过：mpv 适配器重写了它，但通过协议调用时仍然走默认实现（恒 false），
    /// loading 覆盖层永远不撤。
    var hasRenderedFirstFrame: Bool { get }

    /// 播放页调试行。同上——必须是协议要求才能被适配器重写。
    func debugStatsLine() -> String

    // MARK: - 画面

    /// 造一个承载画面的 SwiftUI 视图。
    ///
    /// 调用方按引擎身份给它 `.id(...)`：换片会换引擎实例，SwiftUI 复用旧视图时
    /// 新引擎不会 attach（无渲染循环 → 无状态事件 → UI 卡在 idle）。
    @MainActor func makeSurfaceView() -> AnyView

    // MARK: - 播放控制

    func open(_ source: PlaybackSource) throws
    func play() throws
    func pause() throws
    func stop() throws
    func seek(to position: Duration) throws
    func setRate(_ rate: Double) throws
    func setVolume(_ volume: Double) throws

    // MARK: - 轨道与字幕

    func tracks() throws -> [TrackInfo]
    func selectAudioTrack(_ id: Int64) throws
    /// `nil` 关闭字幕。
    func selectSubtitleTrack(_ id: Int64?) throws
    /// 外挂字幕（本地路径 / URL），返回新轨道 id。
    @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64
    /// 字幕整体缩放（1.0 = 默认字号）。
    func setSubtitleScale(_ scale: Double) throws

    // MARK: - 截图

    /// 离屏截当前合成帧（视频 + 字幕 + 内核弹幕若有），RGBA8。
    /// 尺寸传视频物理分辨率。
    func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8]

    // MARK: - 内核内置弹幕（可选能力）

    /// 内核是否自带弹幕渲染器。
    ///
    /// `false` 时下面那组方法全部走本协议的默认空实现，适配器什么都不用写；
    /// 设置页也据此隐藏「内核弹幕渲染」开关。App 层 overlay 路线不依赖这组能力。
    static var supportsKernelDanmaku: Bool { get }

    func clearDanmaku() throws
    @discardableResult
    func addDanmakuTrack(json: String, name: String, offset: Duration) throws -> UInt64
    func danmakuTracks() throws -> [DanmakuTrackInfo]
    func setDanmakuEnabled(_ enabled: Bool) throws
    func danmakuConfig() throws -> DanmakuConfig
    func setDanmakuConfig(_ config: DanmakuConfig) throws
    func setDanmakuGlobalOffset(_ offset: Duration) throws
}

// MARK: - 默认实现

public extension PlaybackEngine {

    /// 实例侧的便捷读取（`type(of:).descriptor` 写起来太吵）。
    var descriptor: PlaybackEngineDescriptor { Self.descriptor }
    var supportsKernelDanmaku: Bool { Self.supportsKernelDanmaku }

    /// 首帧是否已经出画。播放 loading 覆盖层撤掉的判据——
    /// 内核报了 ready 不代表屏幕上有东西，必须等真正渲染过一帧，
    /// 否则 loading 撤得太早会露出黑屏（两段式等待）。
    var hasRenderedFirstFrame: Bool { latestStats.renderedVideoFrames >= 1 }

    /// 播放页调试行。列固定，拿不到的内核填 0。
    func debugStatsLine() -> String {
        let s = latestStats
        return """
        解码 \(s.decodedVideoFrames) · 渲染 \(s.renderedVideoFrames) · \
        硬解 \(s.hardwareVideoFrames) · 软解 \(s.softwareVideoFrames) · \
        零拷贝 \(s.zeroCopyVideoFrames) · 音频 \(s.pushedAudioFrames) · \
        渲染失败 \(s.renderFailures) · 音频失败 \(s.audioFailures)
        """
    }

    // 没有内核弹幕的引擎：全部安静地什么都不做。
    // 故意不抛错——调用点（`PlaybackController`）在 overlay 路线下也会顺手调
    // `clearDanmaku()` 保证内核轨道为空，那条路径上抛错只会产生噪音。
    static var supportsKernelDanmaku: Bool { false }

    func clearDanmaku() throws {}
    @discardableResult
    func addDanmakuTrack(json: String, name: String, offset: Duration) throws -> UInt64 { 0 }
    func danmakuTracks() throws -> [DanmakuTrackInfo] { [] }
    func setDanmakuEnabled(_ enabled: Bool) throws {}
    func danmakuConfig() throws -> DanmakuConfig { DanmakuConfig() }
    func setDanmakuConfig(_ config: DanmakuConfig) throws {}
    func setDanmakuGlobalOffset(_ offset: Duration) throws {}
}
