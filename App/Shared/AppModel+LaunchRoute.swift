import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit

/// `OCPLAYER_START_ROUTE` 的落地逻辑（Debug 自动化通道；Release 恒 nil）。
///
/// 与"分区直落"分开的理由：分区直落可以在 `init` 里同步设完，而这些目标页
/// **依赖已加载的数据**——媒体库网格要等 `libraries` 就绪、条目详情要有条目。
/// 所以它挂在 `AppShellView` 的 `.task` 上（那时 `phase == .ready`、`isCompact`
/// 也已由布局设定），按需等待数据、再走正常的 `open*` 入口。
extension AppModel {

    /// 落地深链目标页。已落地 / 目标不可达时安静返回（记一条日志）。
    func applyLaunchRouteIfNeeded() async {
        guard !didApplyLaunchRoute else { return }
        didApplyLaunchRoute = true
        guard let route = LaunchOptions.initialRoute else { return }
        // 让布局先定型：`isCompact` 由 AppShell 的 onAppear 设置，而 `push()` 按它
        // 分派到正确的栈（紧凑用当前 Tab 的栈、常规用共享栈）。同帧读取会拿到
        // 默认值 false，页面就落到错误的栈里。
        try? await Task.sleep(for: .milliseconds(300))
        await apply(route)
    }

    private func apply(_ route: LaunchRoute) async {
        switch route {
        case .library:
            guard let library = await firstLibrary() else {
                return logLaunchRouteSkip("library", reason: "没有可用的媒体库")
            }
            openLibrary(library)

        case .detail:
            guard let item = firstBackdropItem() else {
                return logLaunchRouteSkip("detail", reason: "首页没有带背景图的条目")
            }
            openDetail(item)

        case .bangumiProfile:
            openBangumiProfile()

        case .bangumiCalendar:
            openBangumiCalendar()

        case .bangumiSubject(let id):
            openBangumiSubject(id: id)

        case .settings(let subpage, let leaf):
            // 叶子页由宿主子页消费；标记必须在 push 之前写好，否则宿主页先出现、
            // 标记后到，就永远不会展开。
            pendingPresentedLeaf = leaf
            openSettingsSubpage(subpage)

        case .search:
            // 搜索是 iOS 的 Tab（`Tab(role: .search)`），常规布局没有这一页。
            selectedSection = .search
        }
        AppDiagnostics.logInfo("深链落地 target=\(route.logDescription)")
    }

    /// 等第一个媒体库（首页的三条 rail 与库列表是并发拉的，深链可能先到）。
    private func firstLibrary(timeout: Duration = .seconds(10)) async -> MediaLibrary? {
        if let library = libraries.first { return library }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if let library = libraries.first { return library }
        }
        return nil
    }

    /// 第一个**带 backdrop** 的首页条目：验收详情页氛围底时，条目自带图才有意义
    /// （没图的条目本来就回退清晰横幅，测了也说明不了问题）。
    private func firstBackdropItem() -> MediaItem? {
        (home.resume + home.nextUp + home.latest).first { $0.backdropImageTag != nil }
    }

    private func logLaunchRouteSkip(_ target: String, reason: String) {
        AppDiagnostics.logWarning("深链跳过 target=\(target) reason=\(reason)")
    }
}

private extension LaunchRoute {
    /// 日志用的稳定短名（不含参数细节，便于 grep）。
    var logDescription: String {
        switch self {
        case .library: "library"
        case .detail: "detail"
        case .bangumiProfile: "bangumi.profile"
        case .bangumiCalendar: "bangumi.calendar"
        case .bangumiSubject(let id): "bangumi.subject.\(id)"
        case .settings(let subpage, let leaf):
            leaf.map { "settings.\(subpage.routeKey).\($0.rawValue)" } ?? "settings.\(subpage.routeKey)"
        case .search: "search"
        }
    }
}
