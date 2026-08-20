// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DanmakuKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DanmakuKit", targets: ["DanmakuKit"])
    ],
    dependencies: [
        // 统一诊断日志（JSONL + OSLog，敏感字段自动脱敏），沿用 JellyfinKit / ErikaKit 的模式。
        .package(path: "../DiagnosticsKit"),
    ],
    targets: [
        .target(
            name: "DanmakuKit",
            dependencies: ["DiagnosticsKit"]
        ),
        .testTarget(name: "DanmakuKitTests", dependencies: ["DanmakuKit"]),
    ]
)
