import AppDesignKit
import Foundation
import JellyfinKit
import XCTest

@testable import OcPlayer

@MainActor
final class ImageServerScopeTests: XCTestCase {
    private func profile(server: String?, host: String = "a.invalid", user: String = "same-user",
                         kind: ServerKind = .jellyfin) -> ServerProfile {
        ServerProfile(id: "legacy:\(user)", serverName: "Test", baseURL: URL(string: "https://\(host)")!,
                      userID: user, kind: kind, serverID: server)
    }

    func testVerifiedServerKeepsScopeAcrossAddresses() {
        XCTAssertEqual(profile(server: "A").imageCacheScope,
                       profile(server: "A", host: "b.invalid").imageCacheScope)
    }

    func testDistinctServersAccountsAndProductsAreIsolated() {
        let a = profile(server: "A").imageCacheScope
        XCTAssertNotEqual(a, profile(server: "B").imageCacheScope)
        XCTAssertNotEqual(a, profile(server: "A", user: "other").imageCacheScope)
        XCTAssertNotEqual(a, profile(server: "A", kind: .emby).imageCacheScope)
    }

    func testUnverifiedLegacyProfilesUseConservativeOriginFallback() {
        XCTAssertNotEqual(profile(server: nil).imageCacheScope,
                          profile(server: nil, host: "b.invalid").imageCacheScope)
    }

    func testFieldSeparatorsCannotMergeScopes() {
        XCTAssertNotEqual(profile(server: "A:user", user: "B").imageCacheScope,
                          profile(server: "A", user: "user:B").imageCacheScope)
    }
}
