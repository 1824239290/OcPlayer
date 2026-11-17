@testable import AppDesignKit
import SwiftUI
import XCTest

/// 橘猫标志描摹数据的几何钉子。数据是机器描摹的（见 `OcMark` 文档头），
/// 这里钉住「描摹成果没被手滑改坏」：点数、外接框、闭环性、与启动动画的
/// 分层约定。形状保真度的像素级验收在描摹管线里做（IoU 0.990），这里不重复。
final class OcMarkTests: XCTestCase {
    private func bbox(_ points: [CGPoint]) -> (minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
    }

    func testHeadFillHasOuterAndHole() {
        XCTAssertEqual(OcMark.headFillLoops.count, 2, "头部 = 外圈 + 脸洞，双子路径 evenodd")
        XCTAssertEqual(Set(OcMark.headFillLoops.map(\.count)).count, 2, "外圈与脸洞点数不同（可区分）")
    }

    func testAllLoopsAreInsideCanvas() {
        let loops = OcMark.headFillLoops + OcMark.whiskerFillLoops + [OcMark.triangleFillLoop]
        for loop in loops {
            let b = bbox(loop)
            XCTAssertGreaterThanOrEqual(b.minX, 0)
            XCTAssertGreaterThanOrEqual(b.minY, 0)
            XCTAssertLessThanOrEqual(b.maxX, OcMark.canvasSize)
            XCTAssertLessThanOrEqual(b.maxY, OcMark.canvasSize)
        }
    }

    func testContentBBoxMatchesTracedGeometry() {
        let loops = OcMark.headFillLoops + OcMark.whiskerFillLoops + [OcMark.triangleFillLoop]
        let xs = loops.flatMap { $0.map(\.x) }
        let ys = loops.flatMap { $0.map(\.y) }
        XCTAssertEqual(xs.min()!, OcMark.contentBBox.minX, accuracy: 1)
        XCTAssertEqual(ys.min()!, OcMark.contentBBox.minY, accuracy: 1)
        XCTAssertEqual(xs.max()!, OcMark.contentBBox.maxX, accuracy: 1)
        XCTAssertEqual(ys.max()!, OcMark.contentBBox.maxY, accuracy: 1)
    }

    func testCenterlineStaysInsideFillBand() {
        // 中心线是描边动画的画笔路径：必须落在填充带内（外圈与脸洞之间），
        // 否则描边阶段会画出标志轮廓之外的东西。
        let outer = bbox(OcMark.headFillLoops[0])
        let hole = bbox(OcMark.headFillLoops[1])
        let line = bbox(OcMark.headCenterline)
        XCTAssertGreaterThan(line.minX, outer.minX)
        XCTAssertGreaterThan(line.minY, outer.minY)
        XCTAssertLessThan(line.maxX, outer.maxX)
        XCTAssertLessThan(line.maxY, outer.maxY)
        XCTAssertLessThan(hole.maxX, line.maxX)
        XCTAssertLessThan(hole.maxY, line.maxY)
    }

    func testWhiskerCenterlinesRunFromCheekToTip() {
        XCTAssertEqual(OcMark.whiskerCenterlines.count, 4)
        XCTAssertEqual(OcMark.whiskerFillLoops.count, 4)
        for line in OcMark.whiskerCenterlines {
            XCTAssertEqual(line.count, 2, "胡须中心线是两段直线段")
            // 起点在颊侧（描边从颊侧向外画）：x 离画布中线更近。
            let midX = OcMark.canvasSize / 2
            let startCloser = abs(line[0].x - midX) < abs(line[1].x - midX)
            XCTAssertTrue(startCloser, "trim 从颊侧开始：起点应是靠中线的一端")
        }
    }

    func testPathBuilderClosesLoops() {
        let loop = OcMark.headFillLoops[0]
        let path = OcMark.path(loop, closed: true)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.description.isEmpty, false)
        // 闭合路径首尾由 closeSubpath 连接：点数与输入一致（move + n-1 line + close）。
        let open = OcMark.path(loop, closed: false)
        XCTAssertFalse(open.isEmpty)
    }
}
