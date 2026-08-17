// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    dependencies: [
        // 官方 SDK（product 名 JellyfinAPI）：登录 / Quick Connect / Items / 图片全在里面，
        // 我们只做薄封装（多服务器 profile、本地会话、DTO → 域模型映射）。
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift", from: "3.0.0"),
        .package(path: "../CoreModel"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                "CoreModel",
            ]
        ),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
    ]
)
