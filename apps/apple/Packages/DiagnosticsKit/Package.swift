// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiagnosticsKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"])
    ],
    targets: [
        .target(name: "DiagnosticsKit"),
        .testTarget(name: "DiagnosticsKitTests", dependencies: ["DiagnosticsKit"])
    ]
)
