import Foundation
import XCTest

/// Run the same contracts against the delivered static package and a dylib.
enum OcpTestLibrary {
    static func path() throws -> String? {
        if let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty {
            return path
        }
#if canImport(OcPlayerCoreFFI)
        return nil
#else
        throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to exercise the Rust library")
#endif
    }
}
