// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OcPlayerCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "OcPlayerCore", targets: ["OcPlayerCore"])],
    targets: [
        // The source checkout uses Xcode's Rust build phase on iOS. macOS
        // keeps its embedded dylib so existing development overrides work.
        .systemLibrary(name: "OcPlayerCoreFFI", path: "NativeFFI"),
        .target(name: "OcPlayerCore", dependencies: [
            .target(name: "OcPlayerCoreFFI", condition: .when(platforms: [.iOS])),
        ], linkerSettings: [
            .linkedFramework("Security", .when(platforms: [.iOS])),
            .linkedFramework("CoreFoundation", .when(platforms: [.iOS])),
            .linkedLibrary("iconv", .when(platforms: [.iOS])),
            .linkedLibrary("resolv", .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "OcPlayerCoreTests", dependencies: ["OcPlayerCore"], resources: [.copy("Fixtures")]),
    ]
)
