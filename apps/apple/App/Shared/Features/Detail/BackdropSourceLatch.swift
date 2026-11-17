import Foundation

/// 详情页背景图（氛围底图）的「先解析、再上屏、之后锁定」状态机。
///
/// ## 为什么需要它（2026-11-03 实测）
///
/// 用户报「打开详情页会有一瞬间闪另一张背景图，感觉出来后马上被 tmdb 的替代了」。
/// 探针实测同一部片（赛博朋克：边缘行者）在一屏里出现了**三张**背景图，URL 依次是：
///
/// 1. `…/Items/8fe73569…/Images/Backdrop` —— 氛围池兜底图（详情未落地时顶底）；
/// 2. `…/Items/082528dc…/Images/Backdrop` —— 服务端 backdrop（详情落地）；
/// 3. `https://image.tmdb.org/t/p/original/3UbHGmu9…` —— TMDB key art（overlay 到达）。
///
/// 第 2→3 次是用户看到的那次「闪」：同一部片的两张不同背景图之间硬切了一下。
///
/// ## 根因不在数据层，在渲染顺序
///
/// TMDB 图片策略**默认就是「优先顶替服务端已有的图」**（`TMDbPreferences
/// .replaceExistingImages` 默认 true，用户口径：「填了 key 就是想要完整补全」）。
/// 所以数据侧只有一条规则，没有给出两份互相矛盾的答案。问题是这条规则的输入
/// （`tmdbOverlay`）是**异步**到的：`overlay(for:)` 虽然只查库、不发网络，但仍要
/// 等一次 async 跳转。它排在 `load()` 末尾，于是详情内容先按「服务端图」上屏，
/// 几十~几百毫秒后才被换成 TMDB 图。
///
/// ## 语义
///
/// * **`markResolved()` 之前不锁定**：overlay 还没读，`shown` 可能还是列表条目
///   （不带 backdrop tag），这时算出来的可能是 nil —— 锁死就会永远看不到 TMDB 那张；
/// * **解析完成后的第一张非空图即锁定**：之后同一宽度档（800 氛围档 / 1600 清晰档）
///   永远返回同一张，本页不再因迟到数据改口；
/// * **解析完成但结果为空不锁**：详情落地后补上 tag 仍然允许出图；
/// * 锁定按宽度档独立：清晰层与模糊层是两个不同的 URL，不能互相顶替。
///
/// 迟到的 TMDB 数据仍然会落库（`loadTMDbOverlay` 的后台补齐照跑），于是**下次进页**
/// 直接命中缓存、第一次绘制就是 TMDB 那张 —— 「要么一次画对，要么这次先画服务端图
/// 但绝不中途换脸」。
struct BackdropSourceLatch {
    /// 一张背景图的取图目标（与 `MediaItem.imageTarget` 同形）。
    struct Target: Equatable {
        var url: URL?
        var authHeader: String?
        var cacheScope: String? = nil

        init(url: URL?, authHeader: String?, cacheScope: String? = nil) {
            self.url = url
            self.authHeader = authHeader
            self.cacheScope = cacheScope
        }
    }

    /// 是否已经完成首次解析（`DetailViewModel` 读完 TMDB overlay 后置位）。
    private(set) var isResolved = false

    /// 已锁定的取图目标，键为 URL 宽度档（800 / 1600 …）。
    private(set) var locked: [Int: Target] = [:]

    /// 首次解析完成：此后算出来的第一张非空图会被锁定。
    mutating func markResolved() {
        isResolved = true
    }

    /// 取某宽度档的背景图目标。
    ///
    /// - Parameter resolve: 现算规则（TMDB 优先 / 服务端 / 合集成员兜底）。
    ///
    /// ## 解析完成前**一律返回空**
    ///
    /// 这一条是第二轮 review 补的（数据层同事读时序推出来的窗口，其后实测复现三次
    /// 确认）：`DetailView` 的 `.task` 是 `model.attach(app)`（**同步**）→
    /// `await model.load()`，而 `load()` 第一句才是 `await preloadOverlayForFirstPaint`。
    /// 于是「app 已挂上、overlay 还没读回、latch 尚未 resolved」之间存在一个真实的
    /// 时间窗：这一帧现算规则会给出**服务端图**，并且会真的画到屏幕上，overlay 回来
    /// 后再被换成 TMDB 图 —— 只靠「解析后锁定」堵不住它（锁定只能保证解析之后不改口）。
    ///
    /// 返回空让调用方回落**氛围池兜底图**（`DetailView.artTarget` / `artBlurTarget`
    /// 的既有回落分支）：那是设计中的「背景延续」，与首页轮播同 URL、内存缓存命中，
    /// 观感是连续的。解析完成后再一次性给出最终那张（服务端图或 TMDB 图），
    /// 中间不再出现「本条目的一张图被本条目的另一张图顶掉」。
    mutating func target(for width: Int, resolve: () -> Target) -> Target {
        guard isResolved else { return Target(url: nil, authHeader: nil) }
        if let locked = locked[width] { return locked }
        let value = resolve()
        // 只锁非空：解析完成这一刻可能还没有图（详情未落地），锁 nil 会把后面
        // 落地的真实图一起挡掉。
        if value.url != nil {
            locked[width] = value
        }
        return value
    }
}
