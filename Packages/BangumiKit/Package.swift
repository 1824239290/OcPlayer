// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BangumiKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BangumiKit", targets: ["BangumiKit"])
    ],
    dependencies: [
        // 本地 SQLite 缓存（进度/收藏/章节的本地层），与 Bangumi-iOS 同版本线。
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(path: "../DiagnosticsKit"),
    ],
    targets: [
        .target(
            name: "BangumiKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "DiagnosticsKit",
            ]
        ),
        .testTarget(name: "BangumiKitTests", dependencies: ["BangumiKit"]),
    ]
)
