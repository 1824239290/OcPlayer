import CErika
import Foundation
import PlaybackKit

/// Erika 内核的错误。`ErikaStatus` 非 Ok/NoEvent 时，内核把可读信息写在**线程局部**槽位里，
/// 必须在发生错误的那条线程上立即读取。
public struct ErikaError: Error, CustomStringConvertible {
    public let status: ErikaStatus
    public let message: String?

    public var description: String {
        "ErikaError(status: \(status.rawValue)\(message.map { ", \($0)" } ?? ""))"
    }

    /// 读取并清空当前线程的最后一条内核错误信息。
    static func takeLastMessage() -> String? {
        guard let raw = erika_last_error_message() else { return nil }
        defer { erika_string_free(raw) }
        let text = String(cString: raw)
        return text.isEmpty ? nil : text
    }

    static func check(_ status: ErikaStatus) throws {
        guard status != ErikaStatus_Ok, status != ErikaStatus_NoEvent else { return }
        throw ErikaError(status: status, message: takeLastMessage())
    }
}

/// 一个 `ErikaPresenterHandle` 的持有者。
///
/// 内核句柄**没有内部同步**：同一 handle 的所有调用必须串行。本类型只负责生命周期与
/// 逐个 C 调用的薄封装，串行化与显示回调驱动由 `ErikaEngine` 负责，
/// 因此这里刻意不声明 `Sendable`。
public final class ErikaPresenter {
    let handle: OpaquePointer

    /// 创建 presenter。失败时抛错，原因取自内核的线程局部错误槽。
    public init(outputMode: ErikaPresenterOutputMode = ErikaPresenterOutputMode_Auto,
                edrHeadroom: Float = 0,
                upscaler: ErikaLumaUpscalerMode = ErikaLumaUpscalerMode_Off) throws {
        let config = ErikaPresenterConfig(
            output_mode: Int32(outputMode.rawValue),
            edr_headroom: edrHeadroom,
            luma_upscaler: Int32(upscaler.rawValue)
        )
        guard let handle = erika_presenter_create_with_config(config) else {
            throw ErikaError(status: ErikaStatus_PlayerError, message: ErikaError.takeLastMessage())
        }
        self.handle = handle
    }

    deinit {
        erika_presenter_destroy(handle)
    }

    // MARK: - 媒体

    /// 打开媒体源。`headers` 非空时走 `open_with_headers`。
    public func open(_ source: PlaybackSource) throws {
        guard !source.headers.isEmpty else {
            try ErikaError.check(erika_presenter_open(handle, source.uri))
            return
        }
        // C 侧要求 header 数组在调用期间存活：先把所有键值转成 C 字符串，调完再释放。
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func dup(_ text: String) -> UnsafePointer<CChar> {
            let copy = strdup(text)!
            owned.append(copy)
            return UnsafePointer(copy)
        }
        let raw = source.headers.map { ErikaHttpHeader(name: dup($0.key), value: dup($0.value)) }
        try raw.withUnsafeBufferPointer { buffer in
            try ErikaError.check(
                erika_presenter_open_with_headers(handle, source.uri, buffer.baseAddress, UInt(buffer.count))
            )
        }
    }

    public func play() throws { try ErikaError.check(erika_presenter_play(handle)) }
    public func pause() throws { try ErikaError.check(erika_presenter_pause(handle)) }
    public func stop() throws { try ErikaError.check(erika_presenter_stop(handle)) }
    public func close() throws { try ErikaError.check(erika_presenter_close(handle)) }

    public func seek(to position: Duration) throws {
        let micros = max(0, position.microseconds)
        try ErikaError.check(erika_presenter_seek(handle, UInt64(micros)))
    }

    public func setRate(_ rate: Double) throws {
        try ErikaError.check(erika_presenter_set_playback_rate(handle, rate))
    }

    public func setVolume(_ volume: Double) throws {
        try ErikaError.check(erika_presenter_set_volume(handle, min(max(volume, 0), 1)))
    }

    // MARK: - 画面承载

    /// `layer` 是 `CAMetalLayer` 的裸指针；尺寸传**物理像素**，`scale` 传 backingScaleFactor。
    public func attachMetalLayer(_ layer: UInt64, pixelWidth: Int, pixelHeight: Int, scale: Double) throws {
        try ErikaError.check(
            erika_presenter_attach_metal_layer(handle, layer, UInt32(pixelWidth), UInt32(pixelHeight), scale)
        )
    }

    /// 尺寸 / DPI 变化后必须在下一次 tick **之前**调用。
    public func resizeSurface(pixelWidth: Int, pixelHeight: Int, scale: Double) throws {
        try ErikaError.check(
            erika_presenter_resize_surface(handle, UInt32(pixelWidth), UInt32(pixelHeight), scale)
        )
    }

    public func detachSurface() throws {
        try ErikaError.check(erika_presenter_detach_surface(handle))
    }

    // MARK: - 帧驱动与事件

    /// `presentationTime` 必须是该帧的**绝对呈现时间**（秒，`CACurrentMediaTime` 同源），不是 delta。
    @discardableResult
    public func renderTick(at presentationTime: Double) throws -> ErikaPresenterStats {
        var stats = ErikaPresenterStats()
        try ErikaError.check(erika_presenter_render_tick(handle, presentationTime, &stats))
        return stats
    }

    /// 没有画面（窗口隐藏 / 纯音频）时推进音频。
    @discardableResult
    public func audioOnlyTick() throws -> ErikaPresenterStats {
        var stats = ErikaPresenterStats()
        try ErikaError.check(erika_presenter_audio_only_tick(handle, &stats))
        return stats
    }

    /// 当前播放统计。
    public func stats() throws -> ErikaPresenterStats {
        var stats = ErikaPresenterStats()
        try ErikaError.check(erika_presenter_get_stats(handle, &stats))
        return stats
    }

    /// 离屏截当前合成帧（视频 + 字幕 + 弹幕），RGBA8。没有可用帧时内核会报错。
    /// 后续「截图」功能直接用它；测试里也用它证明画面真的解出来了。
    public func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBufferPointer { buffer in
            try ErikaError.check(
                erika_presenter_capture_frame_rgba(handle, UInt32(width), UInt32(height),
                                                   buffer.baseAddress, UInt(buffer.count))
            )
        }
        return pixels
    }

    /// 取一条事件；返回 `nil` 表示队列已空（内核给 `NoEvent`）。事件是**轮询**模型，没有回调。
    public func pollEvent() throws -> PlayerEvent? {
        var raw = ErikaEvent()
        let status = erika_presenter_poll_event(handle, &raw)
        if status == ErikaStatus_NoEvent { return nil }
        try ErikaError.check(status)
        if raw.kind == ErikaEventKind_None { return nil }
        // 错误信息必须在当前线程取，所以在这里就地读掉。
        return PlayerEvent(raw, errorMessage: ErikaError.takeLastMessage())
    }
}
