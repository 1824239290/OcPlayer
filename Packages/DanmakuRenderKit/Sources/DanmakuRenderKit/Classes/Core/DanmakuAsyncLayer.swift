//
//  DanmakuAsyncLayer.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2020/8/16.
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

class Sentinel: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Int32 = 0

    public func getValue() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func increase() {
        lock.lock()
        value += 1
        lock.unlock()
    }

}

public class DanmakuAsyncLayer: CALayer {
    
    /// When true, it is drawn asynchronously and is ture by default.
    public var displayAsync = true
    
    public var willDisplay: ((_ layer: DanmakuAsyncLayer) -> Void)?
    
    public var displaying: ((_ context: CGContext, _ size: CGSize, _ isCancelled:(() -> Bool)) -> Void)?
    
    public var didDisplay: ((_ layer: DanmakuAsyncLayer, _ finished: Bool) -> Void)?
    
    /// The number of queues to draw the danmaku.
    /// 6（上游 16）：队列由所有 cell 轮转共用，单次绘制只是往小位图里画一行字，陈旧
    /// 任务还有 sentinel 作废；16 条 `.userInteractive` 队列在弹幕爆发（seek 补发 /
    /// 密集段）时抢核，反而拖慢主线程的提交与合成。
    public static var drawDanmakuQueueCount = 6 {
        didSet {
            guard drawDanmakuQueueCount != oldValue else { return }
            pool = nil
            createPoolIfNeed()
        }
    }
    
    private let sentinel = Sentinel()
    
    private static var pool: DanmakuQueuePool?
    
    override init() {
        super.init()
        // 不在这里取 `NSScreen.main` / `UIScreen.main` 的 scale：那是主屏的值，窗口在
        // 副屏 / 外接屏上会出糊图。改由 DanmakuCell 在挂窗口、背板变化时下发
        // （见 `DanmakuCell.syncLayerScale`）。
    }
    
    override init(layer: Any) {
        super.init(layer: layer)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    deinit {
        sentinel.increase()
    }
    
    public override func setNeedsDisplay() {
        //1. Cancel the last drawing
        sentinel.increase()
        //2. call super
        super.setNeedsDisplay()
    }
    
    public override func display() {
        display(isAsync: displayAsync)
    }
    
    private func display(isAsync: Bool) {
        guard displaying != nil, bounds.size.width > 0, bounds.size.height > 0 else {
            willDisplay?(self)
            contents = nil
            didDisplay?(self, true)
            return
        }
        
        if isAsync {
            willDisplay?(self)
            let value = sentinel.getValue()
            let isCancelled = {() -> Bool in
                return value != self.sentinel.getValue()
            }
            let size = bounds.size
            let scale = contentsScale
            let opaque = isOpaque
            let backgroundColor = (opaque && self.backgroundColor != nil) ? self.backgroundColor : nil
            queue.async {
                guard !isCancelled() else { return }
                #if os(macOS)
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
                guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: alphaInfo.rawValue) else {
                    return
                }
                context.scaleBy(x: scale, y: scale)
                if opaque {
                    context.saveGState()
                    if backgroundColor == nil || (backgroundColor?.alpha ?? 0) < 1 {
                        context.setFillColor(NSColor.white.cgColor)
                        context.fill(CGRect(origin: .zero, size: size))
                    }
                    if let bg = backgroundColor {
                        context.setFillColor(bg)
                        context.fill(CGRect(origin: .zero, size: size))
                    }
                    context.restoreGState()
                }
                #else
                UIGraphicsBeginImageContextWithOptions(size, opaque, scale)
                guard let context = UIGraphicsGetCurrentContext() else {
                    UIGraphicsEndImageContext()
                    return
                }
                if opaque {
                    context.saveGState()
                    if backgroundColor == nil || (backgroundColor?.alpha ?? 0) < 1 {
                        context.setFillColor(UIColor.white.cgColor)
                        // UIGraphics 上下文已带 scale 变换，坐标系里直接用逻辑尺寸
                        //（原先再乘一次 scale 是双重缩放，靠越界裁剪掩盖）。
                        context.addRect(CGRect(origin: .zero, size: size))
                        context.fillPath()
                    }
                    if let backgroundColor = backgroundColor {
                        context.setFillColor(backgroundColor)
                        context.addRect(CGRect(origin: .zero, size: size))
                        context.fillPath()
                    }
                    context.restoreGState()
                }
                #endif
                self.displaying?(context, size, isCancelled)
                if isCancelled() {
                    #if os(macOS)
                    // no UIGraphics context to end on macOS
                    #else
                    UIGraphicsEndImageContext()
                    #endif
                    DispatchQueue.main.async {
                        self.didDisplay?(self, false)
                    }
                    return
                }
                #if os(macOS)
                let cgImage = context.makeImage()
                if isCancelled() {
                    DispatchQueue.main.async { self.didDisplay?(self, false) }
                    return
                }
                DispatchQueue.main.async {
                    if isCancelled() { self.didDisplay?(self, false) }
                    else { self.contents = cgImage; self.didDisplay?(self, true) }
                }
                #else
                let image = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                if isCancelled() {
                    DispatchQueue.main.async {
                        self.didDisplay?(self, false)
                    }
                    return
                }
                DispatchQueue.main.async {
                    if isCancelled() {
                        self.didDisplay?(self, false)
                    } else {
                        self.contents = image?.cgImage
                        self.didDisplay?(self, true)
                    }
                }
                #endif
            }
            
        } else {
            sentinel.increase()
            willDisplay?(self)
            #if os(macOS)
            let size = bounds.size
            let scale = contentsScale
            let opaque = isOpaque
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
            guard let context = CGContext(data: nil,
                                          width: Int(size.width * scale),
                                          height: Int(size.height * scale),
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: alphaInfo.rawValue) else {
                return
            }
            context.scaleBy(x: scale, y: scale)
            if opaque {
                context.saveGState()
                if self.backgroundColor == nil || (self.backgroundColor?.alpha ?? 0) < 1 {
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                }
                if let bg = self.backgroundColor {
                    context.setFillColor(bg)
                    context.fill(CGRect(origin: .zero, size: size))
                }
                context.restoreGState()
            }
            displaying?(context, bounds.size, {() -> Bool in return false})
            let image = context.makeImage()
            contents = image
            didDisplay?(self, true)
            #else
            UIGraphicsBeginImageContextWithOptions(bounds.size, isOpaque, contentsScale)
            guard let context = UIGraphicsGetCurrentContext() else {
                UIGraphicsEndImageContext()
                return
            }
            displaying?(context, bounds.size, {() -> Bool in return false})
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            contents = image?.cgImage
            didDisplay?(self, true)
            #endif
        }
    }
    
    private static func createPoolIfNeed() {
        guard DanmakuAsyncLayer.pool == nil else { return }
        DanmakuAsyncLayer.pool = DanmakuQueuePool(name: "com.DanmakuKit.DanmakuAsynclayer", queueCount: DanmakuAsyncLayer.drawDanmakuQueueCount, qos: .userInteractive)
    }
    
    private lazy var queue: DispatchQueue = {
        DanmakuAsyncLayer.createPoolIfNeed()
        return DanmakuAsyncLayer.pool?.queue ?? DispatchQueue(label: "com.DanmakuKit.DanmakuAsynclayer")
    }()
    
}
