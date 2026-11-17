import SwiftUI
import XCTest
@testable import OcPlayer

/// 触控分页的方向、手势边界和转场互斥。UI 观感另在真实导航宿主验收。
@MainActor
final class DetailScrollFlipTests: XCTestCase {
    func testUpwardSwipeOpensBody() {
        XCTAssertEqual(target(.art, dx: 0, dy: -60), .body)
        XCTAssertNil(target(.art, dx: 0, dy: 100))
        XCTAssertNil(target(.art, dx: 0, dy: -59))
    }

    func testHorizontalEpisodeSwipeDoesNotFlip() {
        for page in [DetailPagePager.Page.art, .body] {
            XCTAssertNil(target(page, dx: 160, dy: -90))
            XCTAssertNil(target(page, dx: -160, dy: 90))
            XCTAssertNil(target(page, dx: 100, dy: 150))
        }
    }

    func testBodyRequiresNewPullStartingAtTop() {
        XCTAssertEqual(target(.body, dx: 0, dy: 80, atTop: true), .art)
        // 滚动途中到达顶部的同一次拖动不能翻回去。
        XCTAssertNil(target(.body, dx: 0, dy: 180, atTop: false))
        XCTAssertNil(target(.body, dx: 0, dy: -180, atTop: true))
    }

    func testInvalidTranslationsDoNotFlip() {
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertNil(target(.art, dx: bad, dy: -100))
            XCTAssertNil(target(.body, dx: 0, dy: bad))
        }
    }

    func testNativeScrollRegionsRespectInsetsNormalizedThresholds() {
        XCTAssertEqual(DetailPagePager.bodyScrollRegion(offsetY: 200), .scrolled)
        XCTAssertEqual(DetailPagePager.bodyScrollRegion(offsetY: 2), .top)
        XCTAssertEqual(DetailPagePager.bodyScrollRegion(offsetY: -39), .top)
        XCTAssertEqual(DetailPagePager.bodyScrollRegion(offsetY: -40), .pulled)
        XCTAssertEqual(DetailPagePager.bodyScrollRegion(offsetY: .nan), .scrolled)
    }

    func testNativeBodyScrollKeepsBodyOpen() async throws {
        let pager = try await bodyPager()
        pager.beginBodyScroll(atTop: true)
        pager.updateBodyScroll(region: .scrolled)
        XCTAssertEqual(pager.bodyOffsetY, 3)
        pager.endBodyScroll()
        XCTAssertEqual(pager.page, .body, "向上拖动正文只滚动内容")
        XCTAssertFalse(pager.isTransitioning)
        pager.reset()
    }

    func testNativePullReturnsOnlyAfterRelease() async throws {
        let pager = try await bodyPager()
        pager.beginBodyScroll(atTop: true)
        pager.updateBodyScroll(region: .pulled)
        XCTAssertEqual(pager.page, .body, "拖动过程中不能中断原生滚动")
        // 松手回弹跨回阈值前，已达到的下拉距离仍应保留。
        pager.updateBodyScroll(region: .top)
        pager.endBodyScroll()
        XCTAssertEqual(pager.page, .art)
        pager.reset()
    }

    func testNativeScrollToTopAndInertiaDoNotReturn() async throws {
        let pager = try await bodyPager()
        pager.beginBodyScroll(atTop: false)
        pager.updateBodyScroll(region: .top)
        pager.updateBodyScroll(region: .pulled)
        pager.endBodyScroll()
        XCTAssertEqual(pager.page, .body, "滚回顶部的同一次拖动不能翻页")
        pager.updateBodyScroll(region: .pulled)
        pager.endBodyScroll()
        XCTAssertEqual(pager.page, .body, "无手指按下的惯性回弹不能翻页")
        pager.beginBodyScroll(atTop: true)
        pager.updateBodyScroll(region: .top)
        pager.endBodyScroll()
        XCTAssertEqual(pager.page, .body, "短距离下拉不能沿用上一轮凭据")
        pager.reset()
    }

    func testDirectInteractionCanReturnToCover() async throws {
        let pager = try await bodyPager()
        pager.handleBodyScrollPhase(from: .idle, to: .interacting, offsetY: 0)
        pager.updateBodyScroll(region: .pulled)
        pager.handleBodyScrollPhase(from: .interacting, to: .decelerating, offsetY: -45)
        XCTAssertEqual(pager.page, .art, "没有独立 tracking 回调也能返回")
        pager.reset()
    }

    func testReleaseGeometryCapturesPullBeforeRegionCallback() async throws {
        let pager = try await bodyPager()
        pager.handleBodyScrollPhase(from: .idle, to: .tracking, offsetY: 0)
        pager.handleBodyScrollPhase(from: .tracking, to: .interacting, offsetY: -10)
        pager.handleBodyScrollPhase(from: .interacting, to: .idle, offsetY: -45)
        XCTAssertEqual(pager.page, .art, "松手时的位置可补足尚未送达的区域变化")
        pager.reset()
    }

    func testNativePhaseSequenceKeepsScrollToTopOpen() async throws {
        let pager = try await bodyPager()
        pager.handleBodyScrollPhase(from: .decelerating, to: .tracking, offsetY: 200)
        pager.handleBodyScrollPhase(from: .tracking, to: .interacting, offsetY: 1)
        pager.handleBodyScrollPhase(from: .interacting, to: .decelerating, offsetY: -45)
        XCTAssertEqual(pager.page, .body)
        pager.handleBodyScrollPhase(from: .decelerating, to: .idle, offsetY: 0)
        XCTAssertEqual(pager.page, .body)
        pager.reset()
    }

    private func bodyPager() async throws -> DetailPagePager {
        let pager = DetailPagePager()
        pager.reduceMotion = true
        pager.flipToBody()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(pager.isTransitioning)
        return pager
    }

    func testTransitionRejectsRepeatedAndReverseSwipes() {
        let pager = DetailPagePager()
        pager.handleSwipe(translation: CGSize(width: 0, height: -100), startedAtTop: true)
        XCTAssertEqual(pager.page, .body)
        XCTAssertFalse(pager.artForegroundVisible)
        XCTAssertTrue(pager.bodyVisible)
        XCTAssertTrue(pager.blurExpanded)
        XCTAssertTrue(pager.isTransitioning)
        pager.handleSwipe(translation: CGSize(width: 0, height: 100), startedAtTop: true)
        pager.flipToArt()
        XCTAssertEqual(pager.page, .body, "转场未结束时不能被另一手势顶回第一页")
        pager.reset()
    }

    func testReducedMotionUnlocksAndAllowsReturn() async throws {
        let pager = DetailPagePager()
        pager.reduceMotion = true
        pager.flipToBody()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(pager.isTransitioning)
        pager.handleSwipe(translation: CGSize(width: 0, height: 100), startedAtTop: true)
        XCTAssertEqual(pager.page, .art)
        XCTAssertTrue(pager.artForegroundVisible)
        XCTAssertFalse(pager.bodyVisible)
        XCTAssertFalse(pager.blurExpanded)
        pager.reset()
    }

    func testResetCancelsPreviousTransitionUnlock() async throws {
        let pager = DetailPagePager()
        pager.reduceMotion = true
        pager.flipToBody()
        pager.reset()
        XCTAssertEqual(pager.page, .art)
        XCTAssertFalse(pager.isTransitioning)
        XCTAssertEqual(pager.bodyOffsetY, 0)
        pager.reduceMotion = false
        pager.flipToBody()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(pager.isTransitioning, "旧转场的完成回调不能解锁新转场")
        pager.reset()
    }

    private func target(_ page: DetailPagePager.Page, dx: CGFloat, dy: CGFloat,
                        atTop: Bool = true) -> DetailPagePager.Page? {
        DetailPagePager.swipeTarget(page: page, translation: CGSize(width: dx, height: dy),
                                   startedAtTop: atTop)
    }
}
