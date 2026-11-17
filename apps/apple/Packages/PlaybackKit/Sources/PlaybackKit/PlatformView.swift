#if os(macOS)
import AppKit
/// 双端同名的原生视图基类。各内核适配器的画面承载视图都从它派生。
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif
