
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

        #if os(macOS)
        layer.contentsScale = PlatformScreen.main?.backingScaleFactor ?? 1.0
        #else
        layer.contentsScale = PlatformScreen.main.scale
        #endif
        
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
    
}
