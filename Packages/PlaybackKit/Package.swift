// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PlaybackKit",
    // 与 ErikaKit 对齐：Observation（`@Observable`）要 iOS 17 / macOS 14。
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"])
    ],
    dependencies: [
        .package(path: "../DiagnosticsKit"),
    ],
    targets: [
        .target(name: "PlaybackKit", dependencies: ["DiagnosticsKit"]),
        .testTarget(name: "PlaybackKitTests", dependencies: ["PlaybackKit"]),
    ]
)
