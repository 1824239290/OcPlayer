import SwiftUI
import XCTest
@testable import OcPlayer

/// 详情页版式判定表（`DetailLayoutStyle`）。
///
/// **这里分两层测，因为两层在 macOS 上走的是不同的路：**
///
/// - `resolveTable` 是纯函数（不碰任何平台 API），**两个平台的测试 job 都真跑** →
///   判定表本身在这里被钉死；
/// - `resolve` 在 macOS 上被 `#if os(macOS)` 短路成 `.flip`，只有 iOS 才会真的调表。
///
/// 如果判定表只写在 `resolve` 内部，macOS 那半边 CI 就永远执行不到这几行，
/// 「iPhone 恒 banner」这条判据只在 iOS job 里成立——有人把 macOS 的短路删掉、
/// 或者把 iOS 的分支改错，都不会有用例变红。拆成纯函数就是为了让两边测同一份实现。
///
/// 覆盖的是**判定**，不是像素：iPad 能不能翻页（滚动联动）由 `DetailPageFlip` 负责，
/// 本文件不做渲染，也就不需要服务器数据。
///
/// **本文件不测「iPad 上真的切了版式」**——那条需要真机/模拟器实跑。原因记在这里，免得
/// 有人重复踩：我试过用离屏 `UIWindow` 挂 `NavigationStack` + `navigationDestination`
/// 去断言 destination 读到的尺寸类，结果证明这条路本身不可靠：
///
/// - 同一个宿主里 destination 的 `body` 会被求值多次，先后读到的档位不一样；
/// - 在栈**外层**注入 `horizontalSizeClass` 时，destination 读到的值与我预期的
///   「内层 `.pageContentSizeClass` 覆盖外层」顺序不符（这与
///   `ShellSizeClassTests.testPageContentModifierRestoresDeviceSizeClass` 里普通视图的
///   行为不同——普通视图内层确实覆盖外层）。
///
/// 也就是说「详情页那一格宽度是谁给的」在测试宿主里**证不准**，硬写会得到一条时绿时红的
/// 用例。真实链路留到模拟器实跑验收（见 Reports/ipad-detail-layout-20261104/）。
final class DetailLayoutStyleTests: XCTestCase {

    /// 三个真实可能出现的尺寸类取值。`nil` 不是理论值：iPad 分屏拖动过程中、
    /// 被弹出面板覆盖时，`horizontalSizeClass` 都可能是 nil。
    private let sizeClasses: [UserInterfaceSizeClass?] = [.regular, .compact, nil]

    // MARK: - iPad

    /// iPad 全屏（常规宽度）= 翻页版式。**这是整个 iPad 改版唯一的行为增量**，
    /// 其余断言存在的意义都是「除了这一格，别的都没变」。
    func testIPadRegularWidthGetsFlip() {
        XCTAssertEqual(
            DetailLayoutStyle.resolveTable(isPad: true, hSizeClass: .regular), .flip,
            "iPad 全屏必须走翻页版式，否则这次改版没有任何效果"
        )
    }

    /// iPad 分屏 / 侧拉（紧凑宽度）= 横幅版式。翻页版式的第一页是左右分栏
    /// （左 LOGO / 简介 / 播放钮，右清晰剧照），紧凑宽度下会挤成一列；
    /// 而且此时可用宽度与 iPhone 同级，与 iPhone 保持一致更稳。
    func testIPadCompactWidthGetsBanner() {
        XCTAssertEqual(
            DetailLayoutStyle.resolveTable(isPad: true, hSizeClass: .compact), .banner,
            "iPad 分屏必须退回横幅版式：翻页版式是左右分栏，紧凑宽度会挤成一列"
        )
    }

    /// iPad 尺寸类未知 = 横幅版式（保守）。宁可维持旧版式，也不给一个
    /// 「有版式没输入」的翻页界面——翻页版式在没有滚动联动时是翻不动的。
    func testIPadUnknownSizeClassGetsBanner() {
        XCTAssertEqual(
            DetailLayoutStyle.resolveTable(isPad: true, hSizeClass: nil), .banner,
            "尺寸类未知时必须退回横幅版式，不能给一个翻不动的翻页界面"
        )
    }

    // MARK: - iPhone（唯一不能出错的一条）

    /// **iPhone 恒横幅版式，与尺寸类无关。**
    ///
    /// 这条不只是「iPhone 竖屏」：iPhone Pro Max 横屏的 `horizontalSizeClass` 是 `.regular`。
    /// 如果判定表漏了 `isPad` 判断、写成「regular 就翻页」，那台机器一横过来就会变成翻页
    /// 版式，而其余所有 iPhone 用例仍然是绿的——所以这里必须逐个尺寸类都断言。
    func testPhoneAlwaysGetsBanner() {
        for sizeClass in sizeClasses {
            XCTAssertEqual(
                DetailLayoutStyle.resolveTable(isPad: false, hSizeClass: sizeClass), .banner,
                "iPhone 行为必须零变化（含 Pro Max 横屏的 .regular）；"
                    + "实际尺寸类 = \(String(describing: sizeClass))"
            )
        }
    }

    // MARK: - 整张表：翻页版式只由一格产出

    /// 穷举 2 × 3 种输入，断言**整个表里只有「iPad + regular」这一格产出 `.flip`**。
    ///
    /// 上面几条是逐格断言，这条管的是「有没有多出第 7 格」：以后有人加设备形态
    /// （分屏左右窗、Mac Catalyst、视觉 Pro）时，任何新的 `.flip` 输入都会在这里浮现，
    /// 而不是等到真机上发现某个宽度下版式突然变了。
    func testFlipIsProducedByExactlyOneInputCombination() {
        var flipInputs: [(isPad: Bool, sizeClass: UserInterfaceSizeClass?)] = []
        for isPad in [false, true] {
            for sizeClass in sizeClasses where
                DetailLayoutStyle.resolveTable(isPad: isPad, hSizeClass: sizeClass) == .flip
            {
                flipInputs.append((isPad, sizeClass))
            }
        }

        XCTAssertEqual(
            flipInputs.count, 1,
            "产出翻页版式的输入必须恰好一种，实际 \(flipInputs.count) 种："
                + "\(flipInputs.map { "isPad=\($0.isPad), sizeClass=\(String(describing: $0.sizeClass))" })"
        )
        XCTAssertEqual(flipInputs.first?.isPad, true, "翻页版式只允许出现在 iPad 上")
        XCTAssertEqual(flipInputs.first?.sizeClass, .regular, "iPad 只在常规宽度下才是翻页版式")
    }

    // MARK: - 入口真的走这张表

    #if os(iOS)
    /// iOS：`resolve` 必须与判定表**逐格一致**。
    ///
    /// 判定表对、入口没接上，是这类重构最典型的漏法：表本身绿着，界面却还是旧行为。
    func testResolveDelegatesToTableOnIOS() {
        for isPad in [false, true] {
            for sizeClass in sizeClasses {
                XCTAssertEqual(
                    DetailLayoutStyle.resolve(isPad: isPad, hSizeClass: sizeClass),
                    DetailLayoutStyle.resolveTable(isPad: isPad, hSizeClass: sizeClass),
                    "resolve(isPad: \(isPad), sizeClass: \(String(describing: sizeClass))) 没走判定表"
                )
            }
        }
    }
    #endif

    #if os(macOS)
    /// macOS：`resolve` 是编译期短路，恒 `.flip`，与入参无关。
    ///
    /// 这条钉住「macOS 行为零变化」：macOS 详情页的旧横幅早已删掉，
    /// 如果有人把短路换成调表，macOS 上 `isPad == false` 会让详情页退回横幅版式。
    func testResolveIsAlwaysFlipOnMacOS() {
        for isPad in [false, true] {
            for sizeClass in sizeClasses {
                XCTAssertEqual(
                    DetailLayoutStyle.resolve(isPad: isPad, hSizeClass: sizeClass), .flip,
                    "macOS 详情页只有翻页版式，resolve 必须与入参无关"
                )
            }
        }
    }
    #endif
}
