import CoreGraphics
import XCTest

@testable import AppDesignKit

/// `RemoteImageState`：**位图槽 + 双键 + 代次**。
///
/// 这套状态机是「换图不闪」的全部正确性来源：视图只负责把 `.task` 的结果交给它，
/// 谁该上屏、谁该被丢弃全在这里判断。用例按不变式分组，失败信息写成「用户会看到什么」，
/// 而不是「哪个布尔不对」——这些 bug 在真机上都表现为闪图或贴错图。
final class RemoteImageStateTests: XCTestCase {

    // MARK: - 不变式 1：换 URL 不动位图

    /// 换 URL 只移动 `representedKey`，屏幕上的旧帧必须原样留着。
    ///
    /// 这是本轮重构的主目标：旧实现 `image = nil` 之后要等新图下载 + 解码，
    /// 期间卡片是一块灰底（夜间尤其明显）。
    func testURLChangeKeepsShowingPreviousImage() {
        let old = makeTestImage(gray: 0.2)
        var state = RemoteImageState()
        let firstGeneration = state.represent("A")
        XCTAssertNotNil(firstGeneration)
        XCTAssertTrue(state.apply(old, key: "A", generation: firstGeneration!))

        let secondGeneration = state.represent("B")
        XCTAssertNotNil(secondGeneration, "换了 URL 就要一次新加载")

        XCTAssertTrue(state.image === old, "换 URL 时旧位图必须留在屏幕上，否则卡片会先闪一下灰")
        XCTAssertEqual(state.displayedKey, "A", "displayedKey 要跟着位图走，此时还应该是旧图")
        XCTAssertEqual(state.representedKey, "B", "representedKey 表示属性现在要的是新图")
        XCTAssertFalse(state.failed)
        XCTAssertFalse(
            state.showsEmptyPlaceholder(hasURL: true),
            "旧图还在，不该落空图占位")
    }

    /// 屏幕上已经是这张图时不该再加载（首帧同步缓存命中的快速路径）。
    func testRepresentReturnsNilWhenImageAlreadyDisplayed() {
        let image = makeTestImage(gray: 0.4)
        var state = RemoteImageState(image: image, displayedKey: "A")

        XCTAssertNil(state.represent("A"), "已经是这张图，返回 nil = 不必重新加载")
        XCTAssertEqual(state.representedKey, "A")
        XCTAssertEqual(state.displayedKey, "A")
    }

    /// 即使「不用加载」，代次也要推进：否则同一张图的旧回调会被当成最新。
    func testRepresentAdvancesGenerationEvenWhenReusingImage() {
        let image = makeTestImage(gray: 0.5)
        var state = RemoteImageState()
        let generation = state.represent("A")!
        XCTAssertTrue(state.apply(image, key: "A", generation: generation))

        let before = state.generation
        XCTAssertNil(state.represent("A"), "屏幕上是这张图，返回 nil")
        XCTAssertGreaterThan(state.generation, before, "代次仍要推进，作废在途的旧回调")
        XCTAssertTrue(state.image === image, "推进代次不该动位图")
    }

    // MARK: - 不变式 2：成功要双匹配（键 + 代次）

    /// 旧代次的成功结果绝不允许上屏（快速滚动时天天发生）。
    func testStaleGenerationCannotApply() {
        let old = makeTestImage(gray: 0.1)
        let late = makeTestImage(gray: 0.9)
        var state = RemoteImageState()
        let generationA = state.represent("A")!
        XCTAssertTrue(state.apply(old, key: "A", generation: generationA))

        let generationB = state.represent("B")!
        XCTAssertFalse(
            state.apply(late, key: "A", generation: generationA),
            "旧代次的图不该盖上来")
        XCTAssertTrue(state.image === old)
        XCTAssertEqual(state.displayedKey, "A")

        XCTAssertTrue(state.apply(late, key: "B", generation: generationB))
        XCTAssertTrue(state.image === late)
        XCTAssertEqual(state.displayedKey, "B")
        XCTAssertEqual(state.representedKey, "B")
    }

    /// 代次对、键不对，同样作废：`isCurrent` 是「键 **且** 代次」。
    func testMismatchedKeyCannotApply() {
        let image = makeTestImage(gray: 0.3)
        var state = RemoteImageState()
        let generation = state.represent("B")!

        XCTAssertFalse(state.apply(image, key: "A", generation: generation))
        XCTAssertNil(state.image)
        XCTAssertNil(state.displayedKey)
    }

    /// 旧代次的失败也不能把当前请求标记成失败（否则新图还在路上就落占位）。
    func testStaleFailureCannotMarkCurrentRequestFailed() {
        var state = RemoteImageState()
        let generationA = state.represent("A")!
        _ = state.represent("B")

        XCTAssertFalse(state.fail(key: "A", generation: generationA))
        XCTAssertFalse(state.failed)
        XCTAssertFalse(state.showsEmptyPlaceholder(hasURL: true))
    }

    // MARK: - 不变式 3：失败不抹图

    /// 失败时旧帧继续显示；占位只在「从来没拿到过图」时才出现。
    func testFailureKeepsPreviousImageOnScreen() {
        let old = makeTestImage(gray: 0.15)
        var state = RemoteImageState()
        let generationA = state.represent("A")!
        XCTAssertTrue(state.apply(old, key: "A", generation: generationA))

        let generationB = state.represent("B")!
        XCTAssertTrue(state.fail(key: "B", generation: generationB))

        XCTAssertTrue(state.failed)
        XCTAssertTrue(state.image === old, "新图失败时旧图必须留着——这是「不闪」的另一半")
        XCTAssertEqual(state.displayedKey, "A")
        XCTAssertFalse(
            state.showsEmptyPlaceholder(hasURL: true),
            "有旧图就不该落破图占位")
    }

    /// 从没有过图时，失败才落占位。
    func testFailureWithoutAnyImageShowsPlaceholder() {
        var state = RemoteImageState()
        let generation = state.represent("A")!
        XCTAssertTrue(state.fail(key: "A", generation: generation))

        XCTAssertNil(state.image)
        XCTAssertTrue(state.showsEmptyPlaceholder(hasURL: true))
    }

    /// 加载中不落占位：底层灰块就是加载态，多画一个破图符号反而闪。
    func testLoadingStateDoesNotShowPlaceholder() {
        var state = RemoteImageState()
        _ = state.represent("A")
        XCTAssertFalse(state.showsEmptyPlaceholder(hasURL: true))
    }

    /// 成功要清掉之前的失败态（重试成功之后不能再顶着占位）。
    func testSuccessfulApplyClearsFailure() {
        let image = makeTestImage(gray: 0.6)
        var state = RemoteImageState()
        let first = state.represent("A")!
        XCTAssertTrue(state.fail(key: "A", generation: first))
        XCTAssertTrue(state.failed)

        let second = state.represent("A")!
        XCTAssertTrue(state.apply(image, key: "A", generation: second))
        XCTAssertFalse(state.failed)
        XCTAssertTrue(state.showsEmptyPlaceholder(hasURL: true) == false)
    }

    // MARK: - 清空

    /// `url = nil` 是**明确的清空意图**：位图与两个键一起走。
    func testNilURLClearsBitmap() {
        let image = makeTestImage(gray: 0.7)
        var state = RemoteImageState(image: image, displayedKey: "A")

        state.represent(nil)

        XCTAssertNil(state.image)
        XCTAssertNil(state.displayedKey)
        XCTAssertNil(state.representedKey)
        XCTAssertTrue(state.showsEmptyPlaceholder(hasURL: false))
    }

    /// 清空之后再回来：旧代次的回调仍然作废（不能「清空时顺手把在途结果放进来」）。
    func testClearingVoidsInFlightGenerations() {
        let image = makeTestImage(gray: 0.8)
        var state = RemoteImageState()
        let generation = state.represent("A")!
        state.represent(nil)

        XCTAssertFalse(state.apply(image, key: "A", generation: generation))
        XCTAssertNil(state.image)
    }

    /// 没有位图就不该有 displayedKey：构造时别让「空屏幕」看上去像「已显示某张图」。
    func testInitWithoutImageDropsDisplayedKey() {
        let state = RemoteImageState(image: nil, displayedKey: "A")
        XCTAssertNil(state.displayedKey)
        XCTAssertNil(state.representedKey)
    }
}

// MARK: - 测试位图

/// 造一张**互不相同**的位图（用 `===` 区分身份，不比较像素）。
private func makeTestImage(gray: CGFloat) -> PlatformImage {
    let width = 4
    let height = 6
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = context.makeImage()!
    #if canImport(UIKit)
    return UIImage(cgImage: cgImage)
    #else
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    #endif
}
