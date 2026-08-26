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
            // Xcode 的 iOS test build 会把 SPM 包编成动态框架，传递依赖（Get 及 swift-nio
            // 子模块）不会进 JellyfinKit 的链接命令。Get 的 framework 名带 hash 后缀，
            // autolink 也匹配不上；因此仅 iOS 补链 NIO 系框架并允许未定义符号推迟到
            // 运行时解析。macOS 走静态链接，加 .when 条件确保完全不受影响。
            linkerSettings: [
                .linkedFramework("NIOCore", .when(platforms: [.iOS])),
                .linkedFramework("NIOPosix", .when(platforms: [.iOS])),
                .linkedFramework("NIO", .when(platforms: [.iOS])),
                .linkedFramework("NIOConcurrencyHelpers", .when(platforms: [.iOS])),
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"], .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
    ]
)
