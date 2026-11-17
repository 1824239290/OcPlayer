// swift-tools-version:6.0
import PackageDescription

/// App 设计系统：动效/尺寸 token、骨架屏、卡片与轨道原语、通用控件、远程图管道。
///
/// **铁律：本包只吃纯值（URL / String / Double / 闭包），不依赖任何域模型**
/// （MediaItem / BangumiSubjectDTO / MPSubscribe…）。各域在 App 层写薄适配把数据
/// 喂进来——组件可携带（portable），新 Feature 直接复用而不是重写。
let package = Package(
    name: "AppDesignKit",
    // 与 App 部署目标一致（单轨 macOS 26 / iOS 26）：液态玻璃 API 无可用性分支。
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "AppDesignKit", targets: ["AppDesignKit"])
    ],
    dependencies: [
        .package(path: "../DiagnosticsKit"),
    ],
    targets: [
        .target(name: "AppDesignKit", dependencies: ["DiagnosticsKit"]),
        .testTarget(name: "AppDesignKitTests", dependencies: ["AppDesignKit"]),
    ]
)
