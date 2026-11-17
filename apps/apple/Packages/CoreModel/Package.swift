// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CoreModel",
    // 与 ErikaKit 对齐：Observation 要 macOS 14 / iOS 17。
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoreModel", targets: ["CoreModel"])
    ],
    targets: [
        .target(name: "CoreModel"),
        .testTarget(name: "CoreModelTests", dependencies: ["CoreModel"]),
    ]
)
