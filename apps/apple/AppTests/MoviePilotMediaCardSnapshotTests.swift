import AppDesignKit
import MoviePilotKit
import SwiftUI
import XCTest
@testable import OcPlayer

#if os(iOS)
import UIKit

/// MoviePilot 搜索结果卡的**导出工具（不是回归测试）**。
///
/// ## ⚠️ 定性：这是导出工具，不要当成视觉回归防护
///
/// 本类**没有任何基线比对**——它只做两件事：渲染一帧、把 PNG 写到指定目录。
/// 唯一的断言是「高度 > 40」（防止渲染彻底失败），也就是说：
/// **任何版式回归它都不会红**。把它计入「测试全绿」会让回归静默上线。
/// 真正的回归判定在 `MoviePilotMediaCardLayoutTests`（几何钉子）。
///
/// 未设 `OCPLAYER_SNAPSHOT_DIR` 时整类 `XCTSkip`（而不是静默通过），这样 CI 的
/// skip 计数能如实反映「这类没在验证任何东西」。
///
/// ## 为什么用 UIKit 合成链路而不是 `ImageRenderer`
///
/// `ImageRenderer` 对 iOS 26 的 `.glassEffect` 只画出一个占位符（黄底红叉），
/// 量出来的几何可信、但**看不到版式本身**。这里把真机视图挂进 `UIWindow` 再
/// `layer.render(in:)`：液态玻璃的材质、文字色、Dynamic Type 都按真实渲染走一遍。
///
/// ## 用法
///
/// ```bash
/// TEST_RUNNER_OCPLAYER_SNAPSHOT_DIR=/tmp/cards xcodebuild ... \
///   -only-testing:OcPlayerTests-iOS/MoviePilotMediaCardSnapshotTests test
/// ```
/// 产物用于人工核对版式（改版式后重新导一份对比）。
///
/// - Note: `xcodebuild` 只把 **`TEST_RUNNER_` 前缀**的环境变量透传给测试进程，
///   所以调用方要写 `TEST_RUNNER_OCPLAYER_SNAPSHOT_DIR=...`（进程内读到的是去掉前缀的
///   `OCPLAYER_SNAPSHOT_DIR`）。
@MainActor
final class MoviePilotMediaCardSnapshotTests: XCTestCase {

    private static func media() -> MPMediaInfo {
        MPMediaInfo(raw: [
            "media_source": .string("tmdb"),
            "type": .string("电视剧"),
            "title": .string("药屋少女的呢喃"),
            "year": .string("2023"),
            "media_id": .string("tmdb:209867"),
            "tmdb_id": .number(209_867),
            "vote_average": .number(8.7),
            "overview": .string("花街出身的药师少女猫猫被拐入后宫，凭药学知识破解宫中一桩桩悬案。"),
        ])
    }

    /// 没给输出目录时整类跳过：这是导出工具，没有目录就没有任何意义，
    /// 静默「通过」会让 CI 误以为这里有防护。
    private func snapshotDirectory() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["OCPLAYER_SNAPSHOT_DIR"],
              !dir.isEmpty
        else {
            throw XCTSkip(
                "未设 OCPLAYER_SNAPSHOT_DIR —— 本类是快照导出工具，不是回归测试（见类注释）"
            )
        }
        return dir
    }

    private func card(sizeClass: UserInterfaceSizeClass, subscribed: Bool = false) -> some View {
        MoviePilotMediaGlassCard(
            media: Self.media(),
            isSubscribed: subscribed,
            isAdding: false,
            onQuickSubscribe: {},
            onConfigureSubscribe: {},
            onOpenResource: {}
        )
        .environment(\.horizontalSizeClass, sizeClass)
        .background(Color.black)
    }

    /// 把 SwiftUI 视图挂进离屏窗口渲染，返回真实像素图。
    private func snapshot(
        _ view: some View,
        width: CGFloat,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let dir = try snapshotDirectory()
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .black

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1000))
        window.rootViewController = host
        window.makeKeyAndVisible()

        // 让 SwiftUI 完成一次完整布局（异步排版 + 图片占位），再截图。
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.view.layoutIfNeeded()

        // 高度自己量：先把视图按目标宽度摆好，再取 SwiftUI 报的 fitting size。
        // （`UIHostingController` 的 `sizeThatFits` 覆写要求传入 `UIViewController` 上下文，
        //  这里没有实际窗口控制器，绕开它更直接。）
        host.view.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        host.view.layoutIfNeeded()
        let height = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let bounds = CGRect(x: 0, y: 0, width: width, height: max(height, 1))
        host.view.frame = bounds
        window.frame = bounds
        host.view.layoutIfNeeded()

        // SwiftUI 的图层不在 `drawHierarchy` 的合成路径里（实测只能拿到纯色底），
        // 走 `CALayer.render(in:)` 才能把真实图层画出来。
        // 液态玻璃由 `UIVisualEffectView` 承载，这一路同样吃得下。
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = false
            return format
        }())
        let image = renderer.image { context in
            host.view.layer.render(in: context.cgContext)
        }
        window.isHidden = true

        XCTAssertTrue(image.size.height > 40, "快照高度异常：\(image.size)", file: file, line: line)

        guard let data = image.pngData() else {
            print("[snapshot] pngData() 为 nil：\(name)")
            return
        }
        let path = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: path)
            print("[snapshot] 已写入 \(path.path)（\(data.count) bytes, size=\(image.size)）")
        } catch {
            print("[snapshot] 写盘失败 \(path.path): \(error)")
        }
    }

    /// 紧凑档（iPhone 竖屏）——就是线上出问题的那个宽度（402 − 22×2 = 358pt）。
    func testSnapshotCompact() throws {
        try snapshot(card(sizeClass: .compact), width: 358, name: "real-compact")
    }

    /// 紧凑档 + 已订阅态。
    func testSnapshotCompactSubscribed() throws {
        try snapshot(card(sizeClass: .compact, subscribed: true), width: 358, name: "real-compact-subscribed")
    }

    /// 常规档（iPad / macOS 全宽）。
    func testSnapshotRegular() throws {
        try snapshot(card(sizeClass: .regular), width: 792, name: "real-regular")
    }
}
#endif
