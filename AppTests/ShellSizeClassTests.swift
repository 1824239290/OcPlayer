#if os(iOS)
import SwiftUI
import UIKit
@testable import OcPlayer
import XCTest

/// iPad 外壳的尺寸类口径：**iPad 恒为紧凑**（用户口径「只用 iPhone 版的样式」），
/// iPhone 原样。
///
/// 这条用例守的是一个**刻意的平台背离**：iPadOS 18 起系统把标签栏放顶部，我们靠
/// 「把 `TabView` 那一层的尺寸类钉成 compact」把它压回 iPhone 形态（底部栏 + 图标），
/// 内容版式与横向留白也跟着走紧凑档。系统怎么渲染只能靠实拍（见 `AppShellView`
/// 的注释），但「哪些设备被强制、哪些设备不动」是我们自己的决策，必须能防回归。
@MainActor
final class ShellSizeClassTests: XCTestCase {

    /// iPad：不管真实尺寸类是什么（常规 / 分屏紧凑 / nil），一律紧凑。
    func testIPadAlwaysResolvesToCompact() {
        XCTAssertEqual(ShellSizeClass.resolved(idiom: .pad, actual: .regular), .compact)
        XCTAssertEqual(ShellSizeClass.resolved(idiom: .pad, actual: .compact), .compact)
        XCTAssertEqual(ShellSizeClass.resolved(idiom: .pad, actual: nil), .compact)
    }

    /// iPhone 原样返回：compact 是它的常态；Pro Max 横屏是 regular，那是它自己的
    /// 版式，**不动**（改动只针对 iPad）。
    func testPhoneKeepsItsOwnSizeClass() {
        XCTAssertEqual(ShellSizeClass.resolved(idiom: .phone, actual: .compact), .compact)
        XCTAssertEqual(ShellSizeClass.resolved(idiom: .phone, actual: .regular), .regular)
        XCTAssertNil(ShellSizeClass.resolved(idiom: .phone, actual: nil))
    }
}
#endif
