// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ErikaKit",
    // iOS 下限取 17：Observation（`@Observable`）要 iOS 17 / macOS 14，两端刚好对齐。
    // Erika 本身只要 iOS 16，若哪天真要支持 iOS 16，把 PlayerState 换回 ObservableObject 即可。
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ErikaKit", targets: ["ErikaKit"])
    ],
    dependencies: [
        .package(path: "../DiagnosticsKit"),
        .package(path: "../PlaybackKit"),
    ],
    targets: [
        // 由 Scripts/fetch-erika.sh 生成（三 slice：macOS / iOS 设备 / iOS 模拟器）
        .binaryTarget(name: "erika_capi", path: "Vendor/Erika.xcframework"),

        // C 头的模块化封装。erika.h 由 fetch 脚本从 release 同步过来，随 tag 更新
        .target(
            name: "CErika",
            dependencies: ["erika_capi"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),

        .target(name: "ErikaKit", dependencies: ["CErika", "DiagnosticsKit", "PlaybackKit"]),

        .testTarget(name: "ErikaKitTests", dependencies: ["ErikaKit"]),
    ]
)
