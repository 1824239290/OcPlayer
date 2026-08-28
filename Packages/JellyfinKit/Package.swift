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
        .package(path: "../DiagnosticsKit"),
    ],
    targets: [
        .target(
            name: "JellyfinKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                "CoreModel",
                "DiagnosticsKit",
            ],
            // 勿在此用 linkerSettings 给 iOS 补链 NIO 系框架：静态库的 linker flags 会
            // 传导进 App 的 Archive 链接，而 SPM 不产出 .framework，必报 framework not found。
        ),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
    ]
)
