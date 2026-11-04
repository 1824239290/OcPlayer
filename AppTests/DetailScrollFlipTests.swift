import SwiftUI
import XCTest
@testable import OcPlayer

/// iPad 翻页版式的**滚动进度 → 视觉**映射（阶段 ②）。
///
/// 这里只测纯函数 `DetailPagePager.scrollFlipVisuals(forProgress:)`，不渲染：
/// 「滚动能不能真的翻页、吸附是否生效」由系统滚动行为决定，得在模拟器/真机上实跑
/// （见 Reports/ipad-detail-layout-20261104/），单测证明不了。
///
/// 之所以把这个映射独立出来测，是因为它有三个**容易写反、且写反了不会崩**的点：
/// 阈值、越界夹取、以及「前景/正文不参与透明度」这个决定。
final class DetailScrollFlipTests: XCTestCase {

    private func visuals(_ p: CGFloat) -> (blurExpanded: Bool, artForegroundVisible: Bool, bodyVisible: Bool) {
        DetailPagePager.scrollFlipVisuals(forProgress: p)
    }

    // MARK: - 阈值

    /// 进度**过半**才扫开模糊块。正文是深色小字，压在「左糊右清」的剧照上读不清；
    /// 扫成整幅全糊对比度才够。阈值写在 0.5：低于它时第一页还是主体。
    func testBlurExpandsAtHalfProgress() {
        XCTAssertFalse(visuals(0).blurExpanded, "停在第一页时背景必须是「左糊右清」")
        XCTAssertFalse(visuals(0.25).blurExpanded)
        XCTAssertFalse(visuals(0.49).blurExpanded, "不到一半就不该扫开")
        XCTAssertTrue(visuals(0.5).blurExpanded, "过半即扫开（含 0.5 这一点）")
        XCTAssertTrue(visuals(0.75).blurExpanded)
        XCTAssertTrue(visuals(1).blurExpanded, "第二页顶满屏时必须已是全糊")
    }

    /// **翻回第一页时模糊块要跟着收回去**。这条不是多余的：如果映射只写成
    /// `p > 0.5 ? true : blurExpanded`（保留旧值），往回滚就会停在「全糊」，
    /// 第一页的清晰剧照再也回不来 —— 而这在单向上滚的用例里看不出来。
    func testBlurRestoresWhenScrollingBack() {
        XCTAssertTrue(visuals(1).blurExpanded)
        XCTAssertFalse(visuals(0.4).blurExpanded, "滚回一半以下必须收回「左糊右清」")
        XCTAssertFalse(visuals(0).blurExpanded, "回到第一页必须完全恢复")
    }

    // MARK: - 越界与脏值

    /// 回弹时 offset 会是负值；内容比一屏还长时进度会 > 1。两者都必须夹到 [0,1]，
    /// 否则 `artForegroundVisible` 之类的判断会跟着越界值漂。
    func testOutOfRangeProgressIsClamped() {
        XCTAssertFalse(visuals(-0.5).blurExpanded, "回弹越界（负进度）按「停在第一页」处理")
        XCTAssertFalse(visuals(-999).blurExpanded)
        XCTAssertTrue(visuals(1.5).blurExpanded, "超过一屏按「已到第二页」处理")
        XCTAssertTrue(visuals(999).blurExpanded)
    }

    /// NaN / 无穷是真实可能进来的（`contentOffset` 在布局未定时可能是 NaN，
    /// 视口高度为 0 时除法会产出 inf）。判据是**不能崩、且落到安全侧**。
    func testNonFiniteProgressFallsBackToFirstPage() {
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            let v = visuals(bad)
            XCTAssertFalse(v.blurExpanded, "非有限进度必须退到第一页（左糊右清），实际输入 \(bad)")
        }
    }

    // MARK: - 前景 / 正文可见性恒 true

    /// **这两层不参与滚动过渡，是刻意的。**
    ///
    /// iPad 上两页在同一个滚动容器里上下排布、永不重叠，「谁可见」已经由视口位置决定。
    /// 如果再给它们叠一层淡入淡出，就是「边滑边淡」的双重过渡——观感是一层灰雾，
    /// 而不是页面在走。这条用例把「不要给它们加透明度」钉住：
    /// 谁哪天想「顺手加个淡出更平滑」，这里会红。
    func testForegroundAndBodyNeverFade() {
        for p in stride(from: CGFloat(-0.2), through: 1.2, by: 0.05) {
            let v = visuals(p)
            XCTAssertTrue(
                v.artForegroundVisible,
                "第一页前景不参与透明度（进度 \(p)）：滚动本身已经在移走它了"
            )
            XCTAssertTrue(
                v.bodyVisible,
                "正文不参与透明度（进度 \(p)）：它已经由滚动位置决定可见性"
            )
        }
    }
}
