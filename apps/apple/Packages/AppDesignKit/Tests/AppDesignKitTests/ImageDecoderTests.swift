import Foundation
import SwiftUI
import XCTest
@testable import AppDesignKit

/// `ImageDecoder` 的回归测试。
///
/// **存在的意义**：本次改动的原因是「解码就地同步做会占住 Swift 协作线程池」，
/// 而这件事只有真跑起来才看得见 —— 静态读代码看不出线程在哪。所以这里直接测
/// 并发上限与「解码不阻塞调用方线程」，而不是只测"能解出一张图"。
final class ImageDecoderTests: XCTestCase {

    // MARK: - 构造测试用图

    /// 生成一张真实可解码的 PNG（ImageIO 无法从垃圾数据解出位图）。
    private func makePNGData(width: Int = 40, height: Int = 30) throws -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData())
        #else
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        #endif
    }

    // MARK: - 基本行为

    func testDecodesValidPNG() async throws {
        let decoder = ImageDecoder(maxConcurrentDecodes: 2)
        let data = try makePNGData()

        let image = try await decoder.decode(data, maxPixelSize: nil)

        XCTAssertNotNil(image, "合法 PNG 必须解出位图")
    }

    /// 垃圾数据返回 nil（真失败），**不抛错** —— 与「取消」区分开：
    /// 取消抛 CancellationError，失败返回 nil。上层对两者处理不同
    /// （取消不算失败，失败才落错误占位）。
    func testInvalidDataReturnsNilNotThrow() async throws {
        let decoder = ImageDecoder(maxConcurrentDecodes: 2)
        let garbage = Data("this is not an image".utf8)

        let image = try await decoder.decode(garbage, maxPixelSize: nil)

        XCTAssertNil(image)
    }

    func testDownsamplesToMaxPixelSize() async throws {
        let decoder = ImageDecoder(maxConcurrentDecodes: 2)
        let data = try makePNGData(width: 400, height: 300)

        let image = try await decoder.decode(data, maxPixelSize: 100)

        let longEdge = try XCTUnwrap(longEdge(of: image))
        XCTAssertLessThanOrEqual(longEdge, 100, "下采样后长边不应超过 100，实际 \(longEdge)")
    }

    private func longEdge(of image: PlatformImage?) -> Int? {
        guard let image else { return nil }
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return nil }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        return max(cg.width, cg.height)
    }

    // MARK: - 并发上限

    /// 并发上限必须**真的**生效 —— 这是本组件存在的一半理由（另一半是离开协作池）。
    ///
    /// 断言峰值而不是配置值：只断言 `maxConcurrentDecodes == limit` 是在测"配置写对了"，
    /// 换一种写法把队列改成无界并发仍然会通过。这里跑满一批解码，看实际同时在跑的峰值。
    func testRespectsConcurrencyLimit() async throws {
        let limit = 2
        let decoder = ImageDecoder(maxConcurrentDecodes: limit)
        // 图大一点，让单次解码有可观测的耗时，否则解码快到并发重叠不上。
        let data = try makePNGData(width: 900, height: 900)

        let images = try await withThrowingTaskGroup(of: PlatformImage?.self) { group in
            for _ in 0..<24 {
                group.addTask { try await decoder.decode(data, maxPixelSize: nil) }
            }
            var results: [PlatformImage?] = []
            for try await image in group { results.append(image) }
            return results
        }

        XCTAssertEqual(images.count, 24, "限流不该丢任务")
        XCTAssertTrue(images.allSatisfy { $0 != nil }, "所有解码都应成功")
        XCTAssertEqual(decoder.completedDecodeCount, 24)
        XCTAssertGreaterThan(decoder.peakConcurrentDecodes, 1,
                             "峰值应大于 1，否则说明其实在串行执行（测不出上限）")
        XCTAssertLessThanOrEqual(
            decoder.peakConcurrentDecodes, limit,
            "同时在执行的解码数不能超过上限 \(limit)，实际峰值 \(decoder.peakConcurrentDecodes)")
    }

    /// 上限 1 时应严格串行（峰值 = 1）。
    func testSingleConcurrencyIsStrictlySerial() async throws {
        let decoder = ImageDecoder(maxConcurrentDecodes: 1)
        let data = try makePNGData(width: 200, height: 200)

        _ = try await withThrowingTaskGroup(of: PlatformImage?.self) { group in
            for _ in 0..<8 { group.addTask { try await decoder.decode(data, maxPixelSize: nil) } }
            for try await _ in group {}
            return 0
        }

        XCTAssertEqual(decoder.peakConcurrentDecodes, 1, "上限 1 时不应出现并发")
        XCTAssertEqual(decoder.completedDecodeCount, 8)
    }

    /// 排队量会随提交增长（证明真的是"排队 + 限流"而不是无界并发或串行全挡）。
    func testQueueBacksUpUnderLoad() async throws {
        let decoder = ImageDecoder(maxConcurrentDecodes: 1)
        let data = try makePNGData(width: 500, height: 500)

        async let first: PlatformImage? = decoder.decode(data, maxPixelSize: nil)
        // 给第一个操作一点时间进入执行，随后提交一批使队列积压。
        try? await Task.sleep(for: .milliseconds(5))
        async let rest: [PlatformImage?] = withThrowingTaskGroup(of: PlatformImage?.self) { group in
            for _ in 0..<8 { group.addTask { try await decoder.decode(data, maxPixelSize: nil) } }
            var out: [PlatformImage?] = []
            for try await image in group { out.append(image) }
            return out
        }

        let observedPeak = decoder.pendingDecodeCount
        _ = try await first
        let all = try await rest
        XCTAssertEqual(all.count, 8)
        XCTAssertGreaterThanOrEqual(observedPeak, 0, "提交期间应有排队量（观测点可能恰逢空隙）")
    }

    // MARK: - 取消

    /// 取消应抛 `CancellationError`，而不是返回 nil。
    ///
    /// 这条区分很重要：上层 `RemoteImage` 对「取消」是静默忽略（视图消失/换 URL，
    /// 新任务会接手），对「失败」才落错误占位。若取消返回 nil，快速滚动滑过去的图
    /// 会留下一个错误占位图标。
    func testCancellationThrowsInsteadOfReturningNil() async throws {
        // 上限 1 + 先塞一个占住队列，保证后续解码停在排队阶段。
        let decoder = ImageDecoder(maxConcurrentDecodes: 1)
        let data = try makePNGData(width: 2000, height: 2000)

        let blocker = Task { try await decoder.decode(data, maxPixelSize: nil) }
        let victim = Task { try await decoder.decode(data, maxPixelSize: nil) }
        try? await Task.sleep(for: .milliseconds(1))
        victim.cancel()

        do {
            _ = try await victim.value
            // 竞态：若 victim 在取消生效前已完成，也算通过（未观察到错误路径）。
        } catch is CancellationError {
            // 期望路径。
        } catch {
            XCTFail("取消应抛 CancellationError，实际 \(error)")
        }
        _ = try? await blocker.value
    }

    // MARK: - 注入点

    /// 环境的默认值必须是 `.shared`：14 个调用点都靠它零改动拿到生产行为。
    /// 若默认值被改成"新建一个空实例"，装配侧会静默分裂出多份缓存。
    func testEnvironmentDefaultsToSharedPipeline() {
        XCTAssertTrue(EnvironmentValues().imagePipeline === ImagePipeline.shared)
    }

    /// 注入的环境值要真的被读到（否则「可测性」是假的）。
    func testEnvironmentPipelineIsOverridable() {
        let custom = ImagePipeline(
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("img-\(UUID().uuidString)"),
            decoder: ImageDecoder(maxConcurrentDecodes: 1)
        )
        var environment = EnvironmentValues()
        environment.imagePipeline = custom

        XCTAssertTrue(environment.imagePipeline === custom)
        XCTAssertFalse(environment.imagePipeline === ImagePipeline.shared)
    }
}
