// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MoviePilotKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MoviePilotKit", targets: ["MoviePilotKit"])
    ],
    dependencies: [
        .package(path: "../DiagnosticsKit"),
        .package(path: "../OcPlayerCore"),
    ],
    targets: [
        .target(
            name: "MoviePilotKit",
            dependencies: ["DiagnosticsKit", "OcPlayerCore"]
        ),
        .testTarget(name: "MoviePilotKitTests", dependencies: ["MoviePilotKit"], resources: [.copy("Fixtures")]),
    ]
)
