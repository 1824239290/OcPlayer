
//
//  DanmakuCell.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2020/8/16.
//

import Foundation
import QuartzCore
// Use shared platform typealiases
// (see PlatformTypes.swift)
#if canImport(UIKit)
import UIKit
#endif

open class DanmakuCell: PlatformView {

    public var model: DanmakuCellModel?
    
    public internal(set) var animationTime: TimeInterval = 0
    
    var animationBeginTime: TimeInterval = 0

    #if canImport(UIKit)
    public override class var layerClass: AnyClass {
        return DanmakuAsyncLayer.self
    }
    #else
    public override func makeBackingLayer() -> CALayer {
        return DanmakuAsyncLayer()
    }

    public override var wantsLayer: Bool {
        get { return true }
        set { super.wantsLayer = newValue }
    }
    #endif

    public required override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        self.wantsLayer = true
        #else
        // 外接屏 / Stage Manager 换屏时 displayScale 会变；位图是 DanmakuAsyncLayer
        // 自己在 display() 里画的，UIKit 不会替我们重绘，得自己跟上。
        _ = registerForTraitChanges([UITraitDisplayScale.self]) { (cell: DanmakuCell, _) in
            cell.syncLayerScale()
        }
        #endif
        setupLayer()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// Overriding this method, you can get the timing before the content rendering.
    open func willDisplay() {}
    
    
    /// Overriding this method to draw danmaku.
    /// - Parameters:
    ///   - context: drawing context
    ///   - size: bounds.size
    ///   - isCancelled: Whether drawing is cancelled
    open func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {}
    
    /// Overriding this method, you can get the timing after the content rendering.
    /// - Parameter finished: False if draw is cancelled
    open func didDisplay(_ finished: Bool) {}
    
    /// Overriding this method, you can get th timing of danmaku enter track.
    open func enterTrack() {}
    
    /// Overriding this method, you can get th timing of danmaku leave track.
    open func leaveTrack() {}
    
    /// Decide whether to use asynchronous rendering.
    public var displayAsync = true {
        didSet {
            guard let layer = layer as? DanmakuAsyncLayer else { return }
            layer.displayAsync = displayAsync
        }
    }
    
    /// This method can trigger the rendering process, the content can be re-rendered in the displaying(_:_:_:) method.
    public func redraw() {
        #if os(macOS)
        layer?.setNeedsDisplay()
        #else
        layer.setNeedsDisplay()
        #endif
    }
    
    // MARK: - 位图 scale 跟随所在屏幕

    #if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerScale()
    }

    /// 窗口被拖到另一块背板（不同 DPI 的副屏 / 外接屏）时触发。
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerScale()
    }
    #else
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLayerScale()
    }
    #endif
    
}

extension DanmakuCell {
    
    var realFrame: CGRect {
        #if os(macOS)
        if let presentation = layer?.presentation() {
            return presentation.frame
        } else {
            return frame
        }
        #else
        if let presentation = layer.presentation() {
            return presentation.frame
        } else {
            return frame
        }
        #endif
    }
    
    func setupLayer() {
        guard let layer = layer as? DanmakuAsyncLayer else { return }

        // 弹幕 cell 始终在透明上下文中绘制（描边 + 原色填充，无背景色）。
        // 显式标记 layer 非不透明，否则 DanmakuAsyncLayer 的 opaque 分支会用
        // UIColor.white 填充整个背景，在 iOS 上表现为弹幕文字后的白色矩形。
        layer.isOpaque = false

        // 这里不再取 `NSScreen.main` / `UIScreen.main` 的 scale（那是主屏的）：改用
        // 挂窗口 / 背板变化时下发的真实 scale，见 syncLayerScale()。
        
        layer.willDisplay = { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.willDisplay()
        }
        
        layer.displaying = { [weak self] (context, size, isCancelled) in
            guard let strongSelf = self else { return }
            strongSelf.displaying(context, size, isCancelled())
        }
        
        layer.didDisplay = { [weak self] (_, finished) in
            guard let strongSelf = self else { return }
            strongSelf.didDisplay(finished)
        }
    }

    /// 把 layer 的 contentsScale 对齐到**当前所在的窗口屏幕**，并重绘已缓存的位图
    /// （不重绘的话旧 scale 的位图会一直糊着）。不在窗口里时不动——挂上去时
    /// `viewDidMoveToWindow` / `didMoveToWindow` 会再同步一次。
    private func syncLayerScale() {
        guard let layer = layer as? DanmakuAsyncLayer,
              let scale = windowScale(),
              layer.contentsScale != scale
        else { return }
        layer.contentsScale = scale
        redraw()
    }

    private func windowScale() -> CGFloat? {
        #if os(macOS)
        return window?.backingScaleFactor
        #else
        guard window != nil else { return nil }
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : nil
        #endif
    }
    
}
