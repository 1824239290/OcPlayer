import SwiftUI
import XCTest
@testable import OcPlayer

@MainActor
final class MyViewingSummaryLayoutTests: XCTestCase {
    private let sizes: [MyViewingCardRole: CGSize] = [
        .collections: CGSize(width: 392, height: 188),
        .genres: CGSize(width: 392, height: 178),
        .month: CGSize(width: 392, height: 410),
        .trends: CGSize(width: 392, height: 220)
    ]

    func testWideCardsAlignAndNeverOverlap() throws {
        let frames = MyViewingSummaryLayout.frames(width: 800, sizes: sizes, singleColumn: false)
        let month = try XCTUnwrap(frames[.month])
        let genre = try XCTUnwrap(frames[.genres])
        let counts = try XCTUnwrap(frames[.collections])
        let trends = try XCTUnwrap(frames[.trends])
        XCTAssertEqual(month.maxY, genre.maxY)
        XCTAssertGreaterThan(genre.minY, counts.maxY)
        XCTAssertGreaterThan(trends.minY, genre.maxY)
        for frame in frames.values {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 800)
            XCTAssertGreaterThan(frame.height, 0)
        }
        for (role, frame) in frames {
            for (otherRole, other) in frames where role != otherRole {
                XCTAssertFalse(frame.intersects(other))
            }
        }
    }

    func testPhoneCardsUseFullWidthInReadingOrder() throws {
        let frames = MyViewingSummaryLayout.frames(width: 343, sizes: sizes, singleColumn: false)
        var bottom: CGFloat = -1
        for role in MyViewingCardRole.allCases {
            let frame = try XCTUnwrap(frames[role])
            XCTAssertEqual(frame.minX, 0)
            XCTAssertEqual(frame.width, 343)
            XCTAssertGreaterThan(frame.minY, bottom)
            bottom = frame.maxY
        }
    }

    func testAccessibilityCanKeepWideWindowInOneColumn() {
        let frames = MyViewingSummaryLayout.frames(width: 1000, sizes: sizes, singleColumn: true)
        XCTAssertTrue(frames.values.allSatisfy { $0.minX == 0 && $0.width == 1000 })
    }

    func testMonthAloneDoesNotLeaveAnEmptyColumn() throws {
        let frames = MyViewingSummaryLayout.frames(width: 1000, sizes: [.month: sizes[.month]!], singleColumn: false)
        let frame = try XCTUnwrap(frames[.month])
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, 1000)
    }
}
