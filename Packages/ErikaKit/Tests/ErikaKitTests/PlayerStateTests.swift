import XCTest
@testable import ErikaKit

final class PlayerStateTests: XCTestCase {

    @MainActor
    func testOnlyLatestEngineConsumerCanMutateState() async throws {
        let media = try TestMedia.makeShortMovie()
        defer { try? FileManager.default.removeItem(at: media) }

        let oldEngine = try ErikaEngine()
        let currentEngine = try ErikaEngine()
        defer {
            try? oldEngine.close()
            try? currentEngine.close()
        }

        let state = PlayerState()
        let oldTask = state.start(consuming: oldEngine)
        let currentTask = state.start(consuming: currentEngine)
        defer {
            oldTask.cancel()
            currentTask.cancel()
        }

        try oldEngine.open(PlaybackSource(fileURL: media))
        try oldEngine.play()
        for _ in 0..<10 {
            _ = try? oldEngine.audioOnlyTick()
            await Task.yield()
        }

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(state.position, .zero)
        XCTAssertEqual(state.duration, .zero)
    }
}
