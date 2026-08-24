// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DanmakuRenderKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DanmakuRenderKit", targets: ["DanmakuRenderKit"])
    ],
    targets: [
        // 上游是 qyz777/DanmakuKit 1.6.0（MIT），vendored 改名以避开本仓库
        // 取数层 DanmakuKit 的模块名冲突；改动记录见 PROVENANCE.md。
        .target(
            name: "DanmakuRenderKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DanmakuRenderKitTests",
            dependencies: ["DanmakuRenderKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
