#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import ErikaKit
import PlaybackKit
import UIKit

/// iOS 系统画中画的宿主侧协调器。
///
/// 架构（方案见 `Docs/ios-pip-plan.md`）：Erika 内核渲染进宿主纹理
/// （`ErikaEngine.beginTextureRendering` 的 IOSurface 池），本协调器把帧封装成
/// `CMSampleBuffer` 喂给 `AVSampleBufferDisplayLayer`，由系统的
/// `AVPictureInPictureController` 投进 PiP 窗口。PiP 窗口里的播放/暂停/快进控件
/// 通过 `AVPictureInPictureSampleBufferPlaybackDelegate` 转发回 `PlaybackController`
/// 的既有入口。
///
/// 生命周期：由 `PlaybackController` 长期持有；`displayLayer` 常驻（挂在
/// PlayerScreen 的零尺寸 host view 上，**必须在 window 树内 PiP 才能启动**），
/// 平时不喂帧，进 PiP 才切引擎的纹理档。
///
/// 线程：本类主 actor；帧回调来自引擎的定时器队列，`makeFrameSink()` 返回的闭包
/// `nonisolated`，入队（线程安全）直接在回调线程完成，不 hop 主线程。
@MainActor
final class PipCoordinator: NSObject {

    /// 离屏渲染长边像素。PiP 窗口物理尺寸远小于全屏，全分辨率离屏纯浪费；
    /// 按视频宽高比缩到长边 1280。
    private static let renderLongEdgePixels = 1280

    // MARK: - 状态

    /// PiP 窗口当前是否活跃（didStart 与 didStop 之间）。
    private(set) var isActive = false

    /// 设备 / 系统是否支持 PiP（HUD 按钮的显隐依据）。
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 退出 App 时自动进 PiP（设置开关，默认开）。iOS 没有系统级的
    /// 「自动 PiP」属性（那是 tvOS 的），自动行为由 `handleSceneBackground()`
    /// 在退后台钩子里手动触发。
    var beginsAutomatically = true

    /// 喂帧目标。常驻视图树（`PipHostView`），零尺寸不影响布局。
    /// `nonisolated`：喂帧闭包在引擎定时器队列上读它（`enqueue` 本身线程安全）。
    nonisolated let displayLayer = AVSampleBufferDisplayLayer()

    private var pipController: AVPictureInPictureController?

    private weak var controller: PlaybackController?

    /// 显示层时间基准（configureTimebase 建，syncTimebaseRate 改速率）。
    private var timebase: CMTimebase?

    /// PiP 控件查询缓存。delegate 的 `timeRange` / `isPlaybackPaused` 是**同步**
    /// 查询且在非隔离上下文回调（不能等主 actor），由 `cacheLock` 保护；
    /// 控制变化时在主线程刷新（`refreshControlCache`）。
    private nonisolated let cacheLock = NSLock()
    nonisolated(unsafe) private var cachedIsPaused = true
    nonisolated(unsafe) private var cachedDurationSeconds = 0.0

    /// `start()` 已发出、didStart 还没回来（或失败了）——这段窗口里
    /// `beginSystemSuspension` 也要按「PiP 接管中」处理，不能切仅音频档。
    private var startRequested = false

    /// PiP 正在接管（活跃或启动中）——`beginSystemSuspension` 的判据。
    var isEngaged: Bool { isActive || startRequested }

    // MARK: - 绑定

    /// 每次播放会话开始时调用（controller 长活，engine 每次换新）。
    func bind(to controller: PlaybackController) {
        self.controller = controller
        refreshControlCache()
        // 「退出 App 自动小窗」每次会话从偏好读一遍（设置页改动下一次播放生效）。
        beginsAutomatically = UserDefaults.standard.bool(
            forKey: SettingsKeys.autoPictureInPicture, default: true
        )
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: source)
            pip.delegate = self
            pipController = pip
        }
    }

    // MARK: - 进出 PiP

    /// HUD 小窗按钮入口：切纹理档 + 启动系统 PiP。
    ///
    /// 顺序是**先喂帧再启动**——PiP 起来时窗口里就有画面；代价是按钮按下到
    /// PiP 动画接管之间的零点几秒里 App 内画面短暂冻结（metal layer 已被换下）。
    func start() {
        guard let controller, let engine = controller.engine as? ErikaEngine else { return }
        guard !isActive, !startRequested else { return }
        guard controller.state.state == .playing || controller.state.state == .paused else { return }
        guard let pipController else { return }

        let size = Self.renderSize(for: controller.state.videoParams)
        // 引擎回调在定时器队列上直接入队（`enqueue` 线程安全，不 hop 主线程）。
        // displayLayer 用盒子过并发检查：引用只在这一条喂帧链上使用（见
        // `PipFrameSink`），与 ErikaKit 的 `UncheckedSendableBox` 同款处理。
        let layerBox = UncheckedSendableBox(value: displayLayer)
        let entered = engine.beginTextureRendering(pixelWidth: size.width, pixelHeight: size.height) {
            pixelBuffer, pts in
            PipFrameSink.enqueue(pixelBuffer, pts: pts, into: layerBox.value)
        }
        guard entered else {
            PlaybackLog.warning("进纹理档失败，PiP 取消")
            return
        }
        startRequested = true
        configureTimebase()
        pipController.startPictureInPicture()
    }

    /// `scenePhase → background` 钩子（自动 PiP 入口，`beginsAutomatically` 门控）。
    /// 在 `beginSystemSuspension` **之前**调：start 同步进纹理档并置 `isEngaged`，
    /// 后者据此走 `.pip` 挂起模式而不是仅音频档。
    func handleSceneBackground() {
        guard beginsAutomatically, !isEngaged else { return }
        start()
    }

    /// 关 PiP（自然播完 / 会话收口调用；用户在 PiP 窗口点关闭不走这里，走 didStop）。
    func stop() {
        pipController?.stopPictureInPicture()
    }

    /// 播放控制变了（HUD / 键盘 / 远程命令 / PiP 控件都算）：同步显示层 timebase
    /// 的速率，刷新控件查询缓存，并让 PiP 控件刷新状态（按钮态 / skip 可用性）。
    func notePlaybackControlsChanged() {
        refreshControlCache()
        guard isActive else { return }
        syncTimebaseRate()
        pipController?.invalidatePlaybackState()
    }

    /// 主线程读 controller、写非隔离缓存。
    private func refreshControlCache() {
        guard let controller else { return }
        cacheLock.lock()
        cachedIsPaused = controller.state.state != .playing
        cachedDurationSeconds = Double(controller.state.duration.microseconds) / 1_000_000
        cacheLock.unlock()
    }

    /// 播放收口到 `.stopped`（自然播完 / 出错折叠）：PiP 窗口该关了，
    /// 纹理档退出交给 didStop 的统一路径。
    func handlePlaybackStopped() {
        guard isActive else { return }
        stop()
    }

    // MARK: - timebase

    /// 显示层的时间基准：与帧 PTS 同用 host clock。**必须设置**，否则带时间戳的
    /// sample 不渲染、PiP 黑屏（社区踩得最多的坑）。
    private func configureTimebase() {
        let clock = CMClockGetHostTimeClock()
        var created: CMTimebase?
        let status = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault, masterClock: clock, timebaseOut: &created
        )
        guard status == noErr, let timebase = created else {
            PlaybackLog.error("CMTimebase 创建失败 status=\(status)")
            return
        }
        try? timebase.setTime(CMClockGetTime(clock))
        try? timebase.setRate(1)
        displayLayer.controlTimebase = timebase
        self.timebase = timebase
    }

    private func syncTimebaseRate() {
        guard let timebase, let controller else { return }
        let playing = controller.state.state == .playing
        try? timebase.setTime(CMClockGetTime(CMClockGetHostTimeClock()))
        try? timebase.setRate(playing ? 1 : 0)
    }

    /// 按视频宽高比算离屏尺寸：长边钳到 `renderLongEdgePixels`，偶数对齐
    /// （纹理宽高必须偶数）。
    private static func renderSize(for params: VideoParams?) -> (width: Int, height: Int) {
        guard let params, params.width > 0, params.height > 0 else {
            return (1280, 720)
        }
        let longEdge = max(params.width, params.height)
        let scale = min(1.0, Double(renderLongEdgePixels) / Double(longEdge))
        let width = max(2, Int(Double(params.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(params.height) * scale) / 2 * 2)
        return (width, height)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

/// `@preconcurrency`：AVKit 声明这些回调在主线程，但协议本身没标 `@MainActor`；
/// 类是 `@MainActor` 的，不标的话 Swift 6 会把 conformance 判成跨隔离。
extension PipCoordinator: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didStartPictureInPictureWithAnimationCompleted completed: Bool
    ) {
        isActive = true
        PlaybackLog.info("PiP 已开始")
    }

    /// 用户关闭 PiP（×）或系统还原。两种情况都统一退纹理档：
    /// - App 仍后台：切回后台音频档继续出声（与「后台听」能力一致）；
    /// - App 回前台：`endSystemSuspension` 的 `.pip` 分支负责，这里不重复。
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didStopPictureInPictureWithAnimationCompleted completed: Bool
    ) {
        isActive = false
        startRequested = false
        PlaybackLog.info("PiP 已停止")
        guard let controller, let engine = controller.engine as? ErikaEngine else { return }
        engine.endTextureRendering()
        // 后台关 PiP = 继续听；回前台的还原路径由 endSystemSuspension 接管。
        if UIApplication.shared.applicationState == .background,
           controller.state.state == .playing {
            engine.setBackgroundAudioOnly(true)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        startRequested = false
        PlaybackLog.error("PiP 启动失败 error=\(error)")
        // 纹理档已经进了但 PiP 没起来：退回显示档，别让 App 黑屏。
        (controller?.engine as? ErikaEngine)?.endTextureRendering()
    }

    /// 用户点 PiP 窗口的「还原」按钮：把 App 拉回前台。UI 本来就挂着
    /// （PlayerScreen 是 overlay），completion() 即可。
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PipCoordinator: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor in
            guard let controller else { return }
            if controller.state.state == .playing, !playing {
                controller.togglePlayPause()
            } else if controller.state.state != .playing, playing {
                controller.togglePlayPause()
            }
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        cacheLock.lock()
        let duration = cachedDurationSeconds
        cacheLock.unlock()
        guard duration > 0 else { return .invalid }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedIsPaused
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // completion 要送进 MainActor 的 Task：用盒子过并发检查（协议签名固定，
        // 没法在参数上标 @Sendable）。PiP 控件的 completion 只会被调一次。
        let completion = UncheckedSendableBox(value: completionHandler)
        Task { @MainActor in
            self.controller?.skip(by: skipInterval.seconds)
            completion.value()
        }
    }

    /// PiP 窗口尺寸变化（本 SDK 里是 required）。M2 的分辨率跟随接入点：
    /// 现在只记录，渲染尺寸仍按视频宽高比长边 1280（PiP 窗口物理尺寸更小，够用）。
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 无需处理：见方法注释。
    }
}

/// sample buffer 封装从 `FrameSurfacePool.Slot` 拆出来的自由函数：
/// App 层拿不到 Slot（pool 在 ErikaKit 内部），只收到 `(CVPixelBuffer, CMTime)`。
private enum SampleBufferError: Error {
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}

/// Sendable 检查逃生舱：值只在单一执行环境使用，由调用点保证
/// （与 ErikaKit 的 `UncheckedSendableBox` 同款）。
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// 喂帧链。sample 封装在引擎定时器队列上完成；入队 hop 到主线程——
/// iOS 27 SDK 把 `enqueue` / `isReadyForMoreMediaData` 标成了 `@MainActor`，
/// PiP 期间 App 在后台、主线程空闲，60Hz 一次 hop 无感，且 MainActor 队列 FIFO
/// 保证 PTS 顺序。背压检查也在主线程（`isReadyForMoreMediaData` 语义更准）。
private enum PipFrameSink {
    static func enqueue(_ pixelBuffer: CVPixelBuffer, pts: CMTime, into rawLayer: AVSampleBufferDisplayLayer) {
        guard let sample = try? FrameSampleBuffer.make(pixelBuffer: pixelBuffer, pts: pts) else { return }
        let layer = UncheckedSendableBox(value: rawLayer)
        let sampleBox = UncheckedSendableBox(value: sample)
        Task { @MainActor in
            let layer = layer.value
            guard layer.status != .failed else { return }
            guard layer.isReadyForMoreMediaData else { return }   // 背压：丢帧优于堆帧
            layer.enqueue(sampleBox.value)
        }
    }
}

private enum FrameSampleBuffer {
    static func make(pixelBuffer: CVPixelBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw SampleBufferError.formatDescriptionFailed(formatStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            throw SampleBufferError.sampleBufferFailed(sampleStatus)
        }
        return sample
    }
}
#endif
