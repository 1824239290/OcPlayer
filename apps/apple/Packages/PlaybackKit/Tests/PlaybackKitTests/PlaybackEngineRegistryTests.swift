import XCTest
@testable import PlaybackKit

/// 注册表语义。重点在**回退**：一条失效的偏好绝不能让播放器打不开——
/// 这正是「以后删掉某个适配器不影响后续」的技术保证。
@MainActor
final class PlaybackEngineRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.clearSelection()
    }

    override func tearDown() {
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.clearSelection()
        super.tearDown()
    }

    private func registerStub(_ id: String) {
        PlaybackEngineRegistry.register(
            PlaybackEngineDescriptor(
                id: id,
                displayName: id.capitalized,
                summary: "stub",
                supportsKernelDanmaku: false
            ),
            make: { FakePlaybackEngine() }
        )
    }

    func testAvailableFollowsRegistrationOrder() {
        registerStub("erika")
        registerStub("stub2")
        XCTAssertEqual(PlaybackEngineRegistry.available.map(\.id), ["erika", "stub2"])
    }

    func testReRegisteringSameIDReplacesInPlace() {
        registerStub("erika")
        registerStub("stub2")
        registerStub("erika")
        // 覆盖而不是追加，顺序也不该被打乱。
        XCTAssertEqual(PlaybackEngineRegistry.available.map(\.id), ["erika", "stub2"])
    }

    func testDefaultsToFirstRegisteredWhenNothingSelected() {
        registerStub("erika")
        registerStub("stub2")
        XCTAssertNil(PlaybackEngineRegistry.storedSelectionID)
        XCTAssertEqual(PlaybackEngineRegistry.selected?.id, "erika")
        XCTAssertFalse(PlaybackEngineRegistry.selectionIsStale)
    }

    func testExplicitSelectionWins() {
        registerStub("erika")
        registerStub("stub2")
        PlaybackEngineRegistry.select("stub2")
        XCTAssertEqual(PlaybackEngineRegistry.selected?.id, "stub2")
        XCTAssertFalse(PlaybackEngineRegistry.selectionIsStale)
    }

    /// 核心保证：选了第二个内核，之后该适配器被删掉——不能崩、不能打不开，
    /// 要静默回退到还在的那个，并且能把「回退了」这件事告诉设置页。
    func testStaleSelectionFallsBackInsteadOfFailing() throws {
        registerStub("erika")
        registerStub("stub2")
        PlaybackEngineRegistry.select("stub2")

        // 模拟「第二个适配器被移除」：重建注册表，只剩 erika。存的偏好还指向已删的 id。
        PlaybackEngineRegistry.resetForTesting()
        registerStub("erika")

        XCTAssertEqual(PlaybackEngineRegistry.storedSelectionID, "stub2")
        XCTAssertTrue(PlaybackEngineRegistry.selectionIsStale)
        XCTAssertEqual(PlaybackEngineRegistry.selected?.id, "erika")
        XCTAssertNoThrow(try PlaybackEngineRegistry.makeSelected())
    }

    func testMakeSelectedThrowsWhenNothingRegistered() {
        XCTAssertThrowsError(try PlaybackEngineRegistry.makeSelected()) { error in
            guard case PlaybackEngineRegistryError.noEngineAvailable = error else {
                return XCTFail("期望 noEngineAvailable，实际 \(error)")
            }
        }
    }

    func testClearSelectionReturnsToDefault() {
        registerStub("erika")
        registerStub("stub2")
        PlaybackEngineRegistry.select("stub2")
        PlaybackEngineRegistry.clearSelection()
        XCTAssertNil(PlaybackEngineRegistry.storedSelectionID)
        XCTAssertEqual(PlaybackEngineRegistry.selected?.id, "erika")
    }
}
