import AppDesignKit
import MoviePilotKit
import SwiftUI
import XCTest
@testable import OcPlayer

#if os(macOS)
import AppKit

/// 资源搜索卡片流的**懒加载钉子**（真宿主窗口 + 真实 `LazyVStack`）。
///
/// ## 为什么不测「窗口条数」，测「物化了多少行」
///
/// `TorrentRevealWindowTests` 钉的是窗口算术；但窗口算对了**不代表**视图真的只建
/// 那么多行——`LazyVStack` 只按**直接子视图**决定物化哪些，卡片流一旦被 `VStack`
/// 包住，那整块会被当成一个子视图一次求值，窗口再小也是全量物化。
///
/// 2026-11-01 改造前就是这个形状：`torrentsSection` 返回 `VStack`，60 条窗口实际
/// 首帧物化 **120** 行，而且 footer 的 `onAppear` 在同一帧被消费掉、之后滚到底
/// 再也不触发。这类回归**不报编译错、不会让任何断言失败**，只会在真机上把一屏
/// 液态玻璃卡一次性铺出来。唯一稳定的判据是「行到底被建了多少」——`LazyVStack`
/// 的物化是系统内部分支，外部唯一能观察到的信号就是行自身的 `onAppear`。
///
/// ## 反向验证（实做过，不是推测）
///
/// - 把 `MoviePilotTorrentList.body` 包回 `VStack(spacing: 12)`：
///   `testFirstFrameMaterializesOnlyViewportRows` 从 ≤12 变成 **120** 变红；
///   同时 `testRevealAddsOnePagePerScrollToBottom` 因为窗口在首帧就被推到 120、
///   之后不再增长而变红。
/// - 去掉 footer 的 `.id(window.limit)`：`testRevealAddsOnePagePerScrollToBottom`
///   在第二次触底时停住（不再 +60）。
///
/// - Note: 无 WindowServer 的环境（纯 SSH / 无登录会话）整类 `XCTSkip`，不静默通过。
@MainActor
final class MoviePilotTorrentListLazinessTests: XCTestCase {

    // MARK: - 观察器

    /// 记录「哪些行真的被建出来了」与窗口状态。
    ///
    /// `window` 用 `@Published`：`onAppear` 里推进窗口要真的驱动一次重算，
    /// 否则测的是旧帧。
    private final class Recorder: ObservableObject {
        @Published var window = TorrentRevealWindow()
        var appearedIDs: [String] = []
        var revealCount = 0
    }

    /// 复刻资源搜索页的容器形状：`ScrollView` → `LazyVStack` →（页头占位 / 标题 /
    /// 卡片流）。页头占位高度取真实页头量级（hero 卡 + 搜索条 + 筛选条 ≈ 320pt），
    /// 这样「首屏能放几行」与线上同量级。
    private struct Host: View {
        @ObservedObject var recorder: Recorder
        let torrents: [MPTorrent]

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 320)
                    Text("资源")
                        .font(.title3.weight(.bold))
                    MoviePilotTorrentList(
                        displayed: torrents,
                        window: recorder.window,
                        addingDownloadID: nil,
                        onDownload: { _ in },
                        onReveal: {
                            recorder.revealCount += 1
                            recorder.window.reveal(total: torrents.count)
                        },
                        onRowAppear: { recorder.appearedIDs.append($0) }
                    )
                }
                .padding(.horizontal, Metrics.compactContentInset)
            }
        }
    }

    // MARK: - 夹具

    /// 复刻 SSE 元素的字段形态：卡片读 title / description / site_name / size /
    /// seeders / labels / date_elapsed，字段齐了行高才与线上同量级（≈90pt）。
    private static func torrents(_ count: Int) -> [MPTorrent] {
        (0..<count).map { index in
            MPTorrent(
                raw: [
                    "title": .string("药屋少女的呢喃 S01E\(String(format: "%02d", index % 24 + 1)) [1080p][x265][LoliHouse]"),
                    "description": .string("第 \(index % 24 + 1) 话 · LoliHouse 压制 · Web 源"),
                    "enclosure": .string("https://example.invalid/t/\(index).torrent"),
                    "site_name": .string("馒头"),
                    "size": .number(Double(1_200_000_000 + index * 7_300_000)),
                    "seeders": .number(Double(index % 97)),
                    "date_elapsed": .string("\(index % 30 + 1) 天前"),
                    "downloadvolumefactor": .number(index % 4 == 0 ? 0 : 1),
                    "labels": .array([.string("简繁")]),
                ],
                meta: ["resource_pix": .string("1080p"), "resource_team": .string("LoliHouse")]
            )
        }
    }

    // MARK: - 宿主窗口

    private func makeWindow(_ view: some View) -> NSWindow? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 402, height: 874),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        return window
    }

    /// 抽帧：让 SwiftUI 完成布局 / 显示 / `onAppear`。`Layout` 与 `Display` 两轮都要走，
    /// 只跑 run loop 不刷 CATransaction 时，`onAppear` 会晚到。
    private func pump(_ seconds: Double = 1.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        CATransaction.flush()
        let settle = Date().addingTimeInterval(0.2)
        while Date() < settle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = findScrollView(subview) { return found }
        }
        return nil
    }

    /// 像用户那样**一格一格**地往下滚，记录窗口的每一次变化。
    ///
    /// ## 为什么不用「一口气滚到底」
    ///
    /// `LazyVStack` 的文档高度是**估算值**，而且每次新行落位都会把它抬高——「底」在
    /// 滚动过程中一直在移动。一次跳到 `maxY` 只能命中当时的估算底，之后内容长出来
    /// 就停在那儿不动了（实测：真实宿主窗口里第二页永远触发不到）。
    /// 真实滚动是连续的：一帧走几百点，走到哪算哪，lazy 栈跟着补行。这里就是那样一帧
    /// 一帧地推，每推一次让 run loop 走一小段。
    ///
    /// - Returns: 依次出现的窗口条数（首项是滚动前的 60）。
    private func revealSteps(
        _ window: NSWindow, recorder: Recorder, stops: Int = 3, maxFrames: Int = 240
    ) -> [Int] {
        var steps = [recorder.window.limit]
        guard let contentView = window.contentView,
              let scroll = findScrollView(contentView) else { return steps }

        for _ in 0..<maxFrames {
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.05)

            let current = recorder.window.limit
            if current != steps[steps.count - 1] {
                steps.append(current)
                if steps.count >= stops { break }
            }
        }
        return steps
    }

    private func requireWindowServer() throws {
        try XCTSkipIf(
            NSScreen.screens.isEmpty,
            "没有 WindowServer 会话，无法验证 LazyVStack 的真实物化行为"
        )
    }

    // MARK: - 用例

    /// 首帧只物化视口附近的行（探针实测 500 条数据时是 7 行；≤12 是留了预取余量）。
    func testFirstFrameMaterializesOnlyViewportRows() throws {
        try requireWindowServer()

        let recorder = Recorder()
        let torrents = Self.torrents(500)
        guard let window = makeWindow(Host(recorder: recorder, torrents: torrents)) else {
            throw XCTSkip("宿主窗口建不起来")
        }
        defer { window.orderOut(nil) }

        pump(1.5)

        XCTAssertGreaterThan(recorder.appearedIDs.count, 0, "一行都没建出来说明宿主窗口没在渲染")
        XCTAssertLessThanOrEqual(
            recorder.appearedIDs.count, 12,
            """
            首帧物化了 \(recorder.appearedIDs.count) 行——卡片流没有作为 LazyVStack 的\
            直接子视图被懒加载（改造前的形状是 120 行：60 条窗口 + footer 当帧续载）。
            """
        )
        XCTAssertEqual(recorder.window.shownCount(total: torrents.count), 60, "窗口本身不该被首帧推动")
        XCTAssertEqual(recorder.revealCount, 0, "首帧 footer 不应在视口里")
    }

    /// 每滚到底一次，窗口**只** +60 条（不多不少）；连着往下滚就一页一页地露。
    func testRevealAddsOnePagePerScrollToBottom() throws {
        try requireWindowServer()

        let recorder = Recorder()
        let torrents = Self.torrents(500)
        guard let window = makeWindow(Host(recorder: recorder, torrents: torrents)) else {
            throw XCTSkip("宿主窗口建不起来")
        }
        defer { window.orderOut(nil) }

        pump(1.5)
        XCTAssertEqual(recorder.window.limit, 60, "首帧不该续载")

        let steps = revealSteps(window, recorder: recorder, stops: 3)

        XCTAssertEqual(
            steps, [60, 120, 180],
            """
            触底续载序列是 \(steps)（期望 [60, 120, 180]）。停在 [60] = footer 的 \
            onAppear 没再触发（改造前那版只在首帧消费一次的病）；出现 [60, 180] 这类 \
            跳档 = footer 身份没换、在视口里反复触发。
            """
        )
        XCTAssertEqual(recorder.revealCount, 2, "涨了两窗就该触发两次续载")
    }

    /// 结果不足一窗时不出现 footer，也不会多建行。
    func testShortResultShowsEverythingWithoutFooter() throws {
        try requireWindowServer()

        let recorder = Recorder()
        let torrents = Self.torrents(8)
        guard let window = makeWindow(Host(recorder: recorder, torrents: torrents)) else {
            throw XCTSkip("宿主窗口建不起来")
        }
        defer { window.orderOut(nil) }

        pump(1.5)

        XCTAssertEqual(recorder.window.shownCount(total: 8), 8)
        XCTAssertFalse(recorder.window.hasMore(total: 8))
        XCTAssertEqual(recorder.revealCount, 0)
        XCTAssertLessThanOrEqual(recorder.appearedIDs.count, 12)
    }
}

#endif
