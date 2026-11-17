import Foundation
import JellyfinKit
import OcPlayerCore
@testable import OcPlayer
import XCTest

@MainActor
final class RustCoreActivationTests: XCTestCase {
    private func requireNativeCore() throws {
        guard ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1",
              ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
            throw XCTSkip("Run with OCP_CORE_ENABLED=1 and OCP_CORE_LIBRARY_PATH to verify native integration")
        }
    }

    func testAppTestHostLoadsRequestedRustLibrary() throws {
        try requireNativeCore()
        XCTAssertTrue(OcpCoreFeature.isEnabled)
        let client = try OcpCoreClient()
        let response = try client.call("ping")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(OcpCoreClient.abiVersion, 1)
    }

    func testCoreDoesNotReplaceInjectedInMemoryServer() throws {
        try requireNativeCore()
        XCTAssertTrue(OcpCoreFeature.isEnabled)
        let stub = StubMediaServer()
        XCTAssertNil(RustCoreMediaServer(wrapping: stub), "Core must retain caller-injected transport implementations")
    }
}
