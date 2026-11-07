import XCTest
@testable import PlaybackKit

final class PlaybackWatchClockTests: XCTestCase {
    func testPartialPlaybackCountsWithoutFinishing() {
        var clock = PlaybackWatchClock()
        XCTAssertEqual(clock.sample(position: 120, playing: true, buffering: false, rate: 1, time: 0), 0)
        var total = 0.0
        for second in 1...180 {
            total += clock.sample(position: 120 + Double(second), playing: true, buffering: false, rate: 1, time: Double(second))
        }
        XCTAssertEqual(total, 180, accuracy: 0.001)
    }

    func testPauseAndBufferDoNotEarnTime() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0)
        XCTAssertEqual(clock.sample(position: 1, playing: false, buffering: false, rate: 1, time: 1), 1)
        XCTAssertEqual(clock.sample(position: 1, playing: false, buffering: false, rate: 1, time: 30), 0)
        XCTAssertEqual(clock.sample(position: 1, playing: true, buffering: true, rate: 1, time: 31), 0)
        XCTAssertEqual(clock.sample(position: 1, playing: true, buffering: false, rate: 1, time: 40), 0)
        XCTAssertEqual(clock.sample(position: 2, playing: true, buffering: false, rate: 1, time: 41), 1)
    }

    func testDoubleSpeedCountsElapsedViewingTime() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 2, time: 0)
        XCTAssertEqual(clock.sample(position: 2, playing: true, buffering: false, rate: 2, time: 1), 1)
        XCTAssertEqual(clock.sample(position: 4, playing: true, buffering: false, rate: 2, time: 2), 1)
        XCTAssertEqual(clock.sample(position: 4.5, playing: true, buffering: false, rate: 0.5, time: 3), 0)
        XCTAssertEqual(clock.sample(position: 5, playing: true, buffering: false, rate: 0.5, time: 4), 1)
    }

    func testSeekAndBackwardsJumpResetAnchor() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0)
        clock.reset()
        XCTAssertEqual(clock.sample(position: 600, playing: true, buffering: false, rate: 1, time: 1), 0)
        XCTAssertEqual(clock.sample(position: 601, playing: true, buffering: false, rate: 1, time: 2), 1)
        XCTAssertEqual(clock.sample(position: 50, playing: true, buffering: false, rate: 1, time: 3), 0)
        XCTAssertEqual(clock.sample(position: 1200, playing: true, buffering: false, rate: 1, time: 4), 0)
    }

    func testFrozenAndSuspendedIntervalsAreExcluded() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0)
        XCTAssertEqual(clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 1), 0)
        XCTAssertEqual(clock.sample(position: 0.25, playing: true, buffering: false, rate: 1, time: 1.25), 0.25)
        XCTAssertEqual(clock.sample(position: 100, playing: true, buffering: false, rate: 1, time: 101), 0)
        XCTAssertEqual(clock.sample(position: 101, playing: true, buffering: false, rate: 1, time: 102), 1)
    }

    func testRepeatedPositionsBatchSubFrameProgress() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0)
        for tick in 1...14 {
            XCTAssertEqual(clock.sample(position: Double(tick) / 60, playing: true, buffering: false, rate: 1, time: Double(tick) / 60), 0)
        }
        XCTAssertEqual(clock.sample(position: 0.25, playing: true, buffering: false, rate: 1, time: 0.25), 0.25)
    }

    func testInvalidSamplesAndClockGoingBackwardsAreDiscarded() {
        var clock = PlaybackWatchClock()
        _ = clock.sample(position: 0, playing: true, buffering: false, rate: 1, time: 10)
        XCTAssertEqual(clock.sample(position: 1, playing: true, buffering: false, rate: 1, time: 9), 0)
        XCTAssertEqual(clock.sample(position: .nan, playing: true, buffering: false, rate: 1, time: 10), 0)
        XCTAssertEqual(clock.sample(position: 100, playing: true, buffering: false, rate: 0, time: 11), 0)
    }
}
