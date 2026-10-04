// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MetadataKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MetadataKit", targets: ["MetadataKit"])
    ],
    dependencies: [
        // 本地 SQLite（媒体元数据缓存层），与 BangumiKit 同一条 GRDB 依赖线。
        // 版本区间刻意与 Packages/BangumiKit/Package.swift 一致：同源同 pin，
        // 于是两个包解析到同一个 revision（workspace Package.resolved 已是 7.11.1），
        // 不产生第二次下载。
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(path: "../CoreModel"),
        .package(path: "../DiagnosticsKit"),
        // 装饰器要 conform `MediaServer`，故依赖 JellyfinKit（连带 jellyfin-sdk-swift，
        // 已在 SwiftPM 缓存里）。换来的是 `CachedMediaServer` 能在包内离线测试。
        .package(path: "../JellyfinKit"),
    ],
    targets: [
        .target(
            name: "MetadataKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "CoreModel",
                "DiagnosticsKit",
                "JellyfinKit",
            ]
        ),
        .testTarget(name: "MetadataKitTests", dependencies: ["MetadataKit"]),
    ]
)
