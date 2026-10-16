import XCTest
import DanmakuKit
@testable import OcPlayer

/// 弹幕时间轴对齐指针：`DanmakuOverlayController.upperBound`。
///
/// 原实现是 `comments.firstIndex { $0.time > now } ?? comments.count`——线性扫描。
/// 一张热番的弹幕表有几万条（dandanplay 单集常见 3k–30k），而每次 seek / 换源 /
/// 改偏移都要对齐一次指针；二分是 O(log n)。这里钉住它与线性扫描**逐字等价**
/// （边界：空表 / 全部超过 / 全部不超过 / 恰好相等 / 重复时间戳）。
final class DanmakuOverlayTimelinePointerTests: XCTestCase {

    private func entries(_ times: [Double]) -> [DanmakuJSONParser.Entry] {
        times.map { DanmakuJSONParser.Entry(time: $0, mode: .scroll, color: 0xFFFFFF, text: "t") }
    }

    /// 参照实现：原线性扫描的语义。
    private func reference(_ comments: [DanmakuJSONParser.Entry], _ seconds: Double) -> Int {
        comments.firstIndex { $0.time > seconds } ?? comments.count
    }

    func testMatchesLinearScanOnRepresentativeCases() {
        let tables: [[Double]] = [
            [],
            [0],
            [1.5],
            [0, 1, 2, 3],
            [0, 0, 0, 0],
            [1, 1, 2, 2, 2, 5],
            [-3, -1, 0, 7.25, 7.25, 100],
        ]
        let probes: [Double] = [-5, -3, -1, 0, 0.5, 1, 1.999, 2, 2.5, 3, 5, 7.25, 7.26, 100, 1000]
        for times in tables {
            let comments = entries(times)
            for probe in probes {
                XCTAssertEqual(
                    DanmakuOverlayController.upperBound(of: comments, time: probe),
                    reference(comments, probe),
                    "times=\(times) probe=\(probe)"
                )
            }
        }
    }

    func testEmptyTablePointsAtZero() {
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: [], time: 12), 0)
    }

    func testAllPastPointsAtCount() {
        let comments = entries([1, 2, 3])
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: comments, time: 3), 3)
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: comments, time: 99), 3)
    }

    func testBeforeFirstEntryPointsAtZero() {
        let comments = entries([10, 20])
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: comments, time: 9.999), 0)
    }

    /// 相等的那一条**不算超过**：口径是 `time > seconds`，不是 `>=`。
    func testEntryExactlyAtTimeIsNotPast() {
        let comments = entries([5, 6])
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: comments, time: 5), 1)
    }

    /// 重复时间戳：指针应落在整段重复之后。
    func testDuplicateTimestamps() {
        let comments = entries([2, 2, 2, 2, 9])
        XCTAssertEqual(DanmakuOverlayController.upperBound(of: comments, time: 2), 4)
    }

    /// 与线性扫描在大表上逐点比对（覆盖二分的中段分支）。
    func testMatchesLinearScanOnLargeTable() {
        let comments = entries((0..<2000).map { Double($0) * 0.37 })
        for i in stride(from: -3, through: 2000, by: 7) {
            let probe = Double(i) * 0.37
            XCTAssertEqual(
                DanmakuOverlayController.upperBound(of: comments, time: probe),
                reference(comments, probe),
                "probe=\(probe)"
            )
        }
    }
}
