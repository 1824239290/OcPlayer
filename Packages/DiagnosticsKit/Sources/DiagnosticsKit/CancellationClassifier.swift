import Foundation

/// 「这是取消，不是失败」的统一判据。
///
/// ## 为什么需要它
///
/// Swift 并发里有**两种**形态都会出现在「正常取消」路径上，而它们**不是同一个类型**：
///
/// 1. `CancellationError` —— `Task.checkCancellation()` / `Task.sleep` 抛的；
/// 2. `URLError(.cancelled)`（`NSURLErrorDomain` 码 **-999**）—— `URLSession`
///    在请求被取消时抛的。
///
/// 只写 `catch is CancellationError` 的站点**接不住第二种**，于是正常取消会掉进
/// 通用 `catch`，被记成 `warning`。后果是日志口径失真：快速滚动列表、切页面、
/// 关窗口这些**天天发生**的操作都会刷出「加载失败」warning，真正的故障淹在里面。
///
/// 本项目已因这个错配踩过一次：`MoviePilotDownloadsView` 的轮询在
/// `scenePhase` 切换时被取消，`URLError(.cancelled)` 落进通用 catch 弹了错误卡片
/// （见 `DownloadsRefreshSurface.shouldSurfaceError` 的注释）。
///
/// ## 为什么放在 `DiagnosticsKit`
///
/// 判据要被多个包共用（`AppDesignKit` / `DanmakuKit` / `BangumiKit` / `JellyfinKit` …），
/// 而这些包**都依赖 `DiagnosticsKit`** —— 放这里能有一个真源，避免每包各抄一份
/// 而后各自漂移。`JellyfinKit.JellyfinError.isCancellation` 委托到本类型。
///
/// - Note: 判据取「宽」：取消类错误按取消处理、**不**上报。反过来（把真失败当取消）
///   才会漏报故障，所以这里只收窄已知的取消形态，不做启发式猜测。
public enum CancellationClassifier {

    /// 任务取消或 `URLSession` 取消都算「正常取消」。
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        // `CancellationError` 之外还有 `URLError.cancelled`：`URLSession` 把取消
        // 包成 `URLError`，而它既不是 `CancellationError`、`is CancellationError`
        // 也为假 —— 必须显式认这一码。
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// 取消归一成 `CancellationError`，其余原样透传。
    ///
    /// 给「已经决定要向上报告取消」的站点用：调用方因此只需认一种类型。
    public static func normalized(_ error: any Error) -> any Error {
        isCancellation(error) ? CancellationError() : error
    }
}
