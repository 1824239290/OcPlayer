import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

/// PiP 喂帧的 IOSurface 轮转池：一块内存的三个视图
/// （`IOSurface` + `CVPixelBuffer` + `MTLTexture`），内核渲染进 texture，
/// 显示层消费 pixelBuffer，全程零拷贝。
///
/// **复用判据用 `IOSurfaceGetUseCount`**：`AVSampleBufferDisplayLayer` 释放某帧的
/// pixelBuffer 引用后 use count 回零，此刻复用才不会覆写还在显示的画面。
/// 轮转一周全部在飞时返回 nil（上层丢这一拍）——丢帧优于覆写出花屏。
///
/// 线程约定：`acquire()` 只被纹理档的定时器队列串行调用；
/// `replaceSize` / `invalidate` 可能来自主线程（档位切换），内部用锁保护槽位数组。
final class FrameSurfacePool {

    /// 一块可复用的渲染目标。
    ///
    /// `pixelBuffer` 会随 sample buffer 被显示层持有到该帧被替换；
    /// `texture` 的生命周期与之相同（同一 IOSurface），内核只在
    /// `set_flutter_texture_buffer` + `render_tick` 的窗口内写它。
    struct Slot {
        let surface: IOSurface
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
        /// 槽位自持的 use count 基准（pixelBuffer + texture 各贡献 1）。
        /// 显示层持有 sample 期间 use count 超过基准；回落到基准即可复用。
        let baseUseCount: Int

        /// 把这帧封装成可入队的 sample buffer。`pts` 必须与显示层的
        /// controlTimebase 同源且单调递增。
        func makeSampleBuffer(presentationTimeStamp pts: CMTime) throws -> CMSampleBuffer {
            var formatDescription: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription
            )
            guard formatStatus == noErr, let formatDescription else {
                throw PoolError.formatDescriptionCreationFailed(formatStatus)
            }
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
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
                throw PoolError.sampleBufferCreationFailed(sampleStatus)
            }
            return sample
        }
    }

    enum PoolError: Error, CustomStringConvertible {
        case slotCreationFailed(OSStatus)
        case textureCreationFailed
        case formatDescriptionCreationFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)

        var description: String {
            switch self {
            case .slotCreationFailed(let status): "FrameSurfacePool: 槽位创建失败 status=\(status)"
            case .textureCreationFailed: "FrameSurfacePool: IOSurface → MTLTexture 失败"
            case .formatDescriptionCreationFailed(let status): "FrameSurfacePool: 格式描述创建失败 status=\(status)"
            case .sampleBufferCreationFailed(let status): "FrameSurfacePool: sample buffer 创建失败 status=\(status)"
            }
        }
    }

    private let lock = NSLock()
    private var slots: [Slot]
    private var cursor: Int = 0
    let pixelWidth: Int
    let pixelHeight: Int

    /// 槽位数：显示层最多同时持有最近几帧，4 个在「入队速率 ≈ 消费速率」时
    /// 既不缺帧也很少触发丢拍。
    private static let slotCount = 4

    init(pixelWidth: Int, pixelHeight: Int, device: MTLDevice) throws {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        var built: [Slot] = []
        built.reserveCapacity(Self.slotCount)
        for _ in 0..<Self.slotCount {
            built.append(try Self.makeSlot(pixelWidth: pixelWidth, pixelHeight: pixelHeight, device: device))
        }
        slots = built
    }

    /// 取一个可写的槽位；全部在飞（use count 超出基准，即显示层还攥着）时返回 nil，
    /// 调用方丢这一拍。
    ///
    /// 轮转指针保证「全部在飞」的判断覆盖整圈，而不是反复卡在最近入队的槽上。
    func acquire() -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<slots.count {
            let slot = slots[cursor]
            cursor = (cursor + 1) % slots.count
            if Int(IOSurfaceGetUseCount(slot.surface)) <= slot.baseUseCount {
                return slot
            }
        }
        return nil
    }

    private static func makeSlot(pixelWidth: Int, pixelHeight: Int, device: MTLDevice) throws -> Slot {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: pixelWidth,
            kIOSurfaceHeight: pixelHeight,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            throw PoolError.slotCreationFailed(-1)
        }
        var pixelBufferPointer: Unmanaged<CVPixelBuffer>?
        let bufferStatus = CVPixelBufferCreateWithIOSurface(nil, surface, nil, &pixelBufferPointer)
        guard bufferStatus == noErr, let pixelBuffer = pixelBufferPointer?.takeRetainedValue() else {
            throw PoolError.slotCreationFailed(bufferStatus)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw PoolError.textureCreationFailed
        }
        // pixelBuffer 与 texture 各持有一次 surface；显示层入队后在此基础上 +1。
        return Slot(
            surface: surface,
            pixelBuffer: pixelBuffer,
            texture: texture,
            baseUseCount: Int(IOSurfaceGetUseCount(surface))
        )
    }
}
