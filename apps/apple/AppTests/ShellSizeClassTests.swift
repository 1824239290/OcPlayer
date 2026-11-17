#if os(iOS)
import AppDesignKit
import SwiftUI
import UIKit
@testable import OcPlayer
import XCTest

/// iPad 外壳的尺寸类口径，**分两层**（用户口径：「**tabview 保留 iPhone 样式的，但其他
/// 所有都保持 iPad 的**」）：
///
/// - **标签栏那一层**（`TabView` 自己读，`.tabBar`）：iPad 恒紧凑 —— iPadOS 18 起系统把
///   标签栏放顶部，只有把这一层钉成紧凑档才会落回 iPhone 那样的底部栏（SwiftUI 没有
///   「选底部栏」的公开 API，只能借尺寸类这个副作用，见 `AppShellView.compactLayout`）。
/// - **页面内容那一层**（每个 Tab 的内容读，`.pageContent`）：设备真实宽度 —— 首页 rail、
///   媒体库列数、详情页头部、设置卡片全部保持 iPad 版式。外壳的紧凑档**只为标签栏存在**，
///   不该顺着环境继承把内容一起降级。
///
/// 系统把标签栏画成底部还是顶部只能靠实拍，但「哪一层被强制、哪一层不动」是我们的决策，
/// 必须能防回归。
@MainActor
final class ShellSizeClassTests: XCTestCase {

    // MARK: - 标签栏层

    /// iPad：不管真实尺寸类是什么（常规 / 分屏紧凑 / nil），标签栏那一层一律紧凑
    /// —— 这是底部栏成立的前提。
    func testTabBarLayerIsAlwaysCompactOnIPad() {
        for actual: UserInterfaceSizeClass? in [.regular, .compact, nil] {
            XCTAssertEqual(
                ShellSizeClass.resolved(idiom: .pad, actual: actual, layer: .tabBar), .compact,
                "标签栏层必须恒紧凑，否则 iPad 上标签栏会回到系统默认的顶部胶囊"
            )
        }
    }

    // MARK: - 内容层

    /// **iPad 的内容层原样返回**：13″ 屏上就是 `.regular` —— 用户口径里「其他所有都保持
    /// iPad 的」这一句的落点。这条要是退化成 `.compact`，iPad 上整页版式（首页 rail 尺寸、
    /// 媒体库列数、详情页的 iPad 头部与 52pt 留白、设置卡片）会一起变回放大版 iPhone。
    func testPageContentLayerKeepsDeviceWidthOnIPad() {
        XCTAssertEqual(
            ShellSizeClass.resolved(idiom: .pad, actual: .regular, layer: .pageContent), .regular,
            "iPad 常规宽度下内容必须保持常规档（用户口径：其他所有都保持 iPad 的）"
        )
        XCTAssertEqual(
            ShellSizeClass.resolved(idiom: .pad, actual: .compact, layer: .pageContent), .compact,
            "iPad 分屏窄窗本来就是紧凑宽度，内容该走紧凑版式——这条不是被外壳强制的"
        )
        XCTAssertNil(ShellSizeClass.resolved(idiom: .pad, actual: nil, layer: .pageContent))
    }

    // MARK: - iPhone

    /// iPhone 两层都原样返回：compact 是它的常态；Pro Max 横屏是 regular，那是它自己的
    /// 版式，**不动**（改动只针对 iPad）。
    func testPhoneKeepsItsOwnSizeClassInBothLayers() {
        for layer: ShellSizeClass.Layer in [.tabBar, .pageContent] {
            XCTAssertEqual(ShellSizeClass.resolved(idiom: .phone, actual: .compact, layer: layer), .compact)
            XCTAssertEqual(ShellSizeClass.resolved(idiom: .phone, actual: .regular, layer: layer), .regular)
            XCTAssertNil(ShellSizeClass.resolved(idiom: .phone, actual: nil, layer: layer))
        }
    }

    // MARK: - 接线：内容层真的被换回来了

    /// 纯函数只管「算什么值」，这条管「值有没有真的落到内容那棵子树上」：外壳给 `TabView`
    /// 钉的紧凑档会**顺着环境继承**下来（`pageContentSizeClass` 就是为此存在的），这里把
    /// 那条链原样搭出来 —— 再从视图体内读回**实际生效**的值。
    ///
    /// 顺序不能写反：环境的覆盖**就近生效**，内容层那一句必须比外壳那层更靠近内容。真实
    /// 调用点就是这个顺序（`TabView` 的 `.environment` 在外，`compactTabs` 里每个 Tab 内容
    /// 的 `.pageContentSizeClass` 在内）。写反了读到的就是外壳的紧凑档 —— 这条用例第一段
    /// 就是这个反证。
    func testPageContentModifierRestoresDeviceSizeClass() throws {
        let leaked = LayoutProbe()
        try render(
            ProbeView(probe: leaked)
                .environment(\.horizontalSizeClass, .compact)
        )
        XCTAssertEqual(
            leaked.sizeClass, .compact,
            "反证：不挂内容层那一句，外壳的紧凑档会一路继承到内容（这正是这次的 bug 形状）"
        )

        let probe = LayoutProbe()
        try render(
            ProbeView(probe: probe)
                // 内容层：换回设备真实宽度（iPad 常规宽度）。更靠近内容 → 生效。
                .pageContentSizeClass(
                    ShellSizeClass.resolved(idiom: .pad, actual: .regular, layer: .pageContent)
                )
                // 外壳在 `compactLayout` 里钉的那一档：在外层，被上面那条覆盖。
                .environment(\.horizontalSizeClass, .compact)
        )

        XCTAssertEqual(probe.sizeClass, .regular, "内容层没换回来：整页版式会跟着标签栏降级成 iPhone 档")
    }

    // MARK: - 渲染探针

    /// 环境值只在**视图里**读得到，所以让探针视图在 `body` 里把实际生效的值写回来。
    /// 渲染用 `ImageRenderer`（同步、单帧）——这里不需要 `ScrollView` 的视口，
    /// 与 `HomeLayoutTests` 那条「必须挂 `UIWindow`」的约束无关。
    private final class LayoutProbe {
        var sizeClass: UserInterfaceSizeClass?
    }

    private struct ProbeView: View {
        let probe: LayoutProbe
        @Environment(\.horizontalSizeClass) private var sizeClass

        var body: some View {
            probe.sizeClass = sizeClass
            return Color.clear.frame(width: 1, height: 1)
        }
    }

    private func render(_ view: some View) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图（探针视图没被求值？）")
    }
}
#endif
