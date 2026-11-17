import Foundation

/// `RemoteImage` 的可测状态机：**位图槽 + 双键 + 代次**。
///
/// 拆出来的理由：`RemoteImage` 的 `.task(id:)` 是这套逻辑唯一的运行现场，而 SwiftUI
/// 视图没有便宜的单元测试。「谁该上屏」的判断收进这个纯值类型之后，换 URL / 失败 /
/// 乱序到达 / 取消都能直接断言（见 `RemoteImageStateTests`）。
///
/// 三个槽位各管一件事，互不覆盖：
/// - `image` + `displayedKey`：屏幕上**正在显示**的那一帧（同生共死）；
/// - `representedKey`：属性此刻**要求**的那张图；
/// - `failed`：当前这次要求是否已经失败（与「有没有图」正交）。
///
/// 三条不变式（都有对应用例）：
/// 1. **换 URL 不动位图**：`represent(_:)` 只推进 `representedKey` 与代次，旧位图原样
///    留着 —— 卡片换图不再先清成灰底再淡入，这是本轮要修的主要症状；
/// 2. **成功要双匹配**：`representedKey` 与 `generation` 同时命中才允许 `apply`，
///    旧键 / 旧代次的回调一律丢弃（快速滚动时这是常态）；
/// 3. **失败不抹图**：`fail` 只置 `failed`，位图保留；只有**从来没拿到过图**时才落占位。
struct RemoteImageState {
    /// 屏幕上正在显示的那一帧。nil = 没有图可画（加载中 / 失败 / 本来就没有地址）。
    private(set) var image: PlatformImage?
    /// 属性此刻要求的图（=`RemoteImage` 的加载键）。
    private(set) var representedKey: String?
    /// 屏幕上这张位图对应的加载键。与 `image` 同生共死：只在 `apply` / 清空时移动。
    private(set) var displayedKey: String?
    /// 每次「表示」推进一次；旧代次的回调据此作废。
    private(set) var generation: UInt64 = 0
    /// 当前这次表示是否已经失败。
    private(set) var failed = false

    /// 空状态，或「首帧就有位图」的同步缓存命中态。
    init(image: PlatformImage? = nil, displayedKey: String? = nil) {
        // 没有位图就不该有键：两者必须同生共死，否则 `represent` 的「已经是这张图」
        // 快速路径会把一个空屏幕误判成「不用加载」。
        let key = image == nil ? nil : displayedKey
        self.image = image
        self.representedKey = key
        self.displayedKey = key
    }

    /// 声明「现在要这张图」。返回值是这次加载应当记住的代次；
    /// **nil = 屏幕上已经是这张图**，调用方不必再加载。
    ///
    /// 代次在「发现可复用当前位图」时也会推进：那一下会作废所有在途回调，
    /// 免得同一张图的两个回调互相盖掉。
    @discardableResult
    mutating func represent(_ key: String?) -> UInt64? {
        generation &+= 1
        representedKey = key
        failed = false

        guard let key else {
            // 没有地址 = 明确的清空意图（宿主把 URL 换成了 nil）。
            image = nil
            displayedKey = nil
            return generation
        }
        guard displayedKey != key else { return nil }
        return generation
    }

    /// 这次回调是否仍然代表「现在该上屏的那张图」。
    func isCurrent(key: String, generation: UInt64) -> Bool {
        representedKey == key && self.generation == generation
    }

    /// 只有 represented key + 代次都吻合，成功结果才允许上屏。
    @discardableResult
    mutating func apply(
        _ image: PlatformImage,
        key: String,
        generation: UInt64
    ) -> Bool {
        guard isCurrent(key: key, generation: generation) else { return false }
        self.image = image
        displayedKey = key
        failed = false
        return true
    }

    /// 失败只更新当前请求的失败态；已有 displayed image/key 原样保留。
    @discardableResult
    mutating func fail(key: String, generation: UInt64) -> Bool {
        guard isCurrent(key: key, generation: generation) else { return false }
        failed = true
        return true
    }

    /// 没有位图可画时是否该落「空图」图标。
    ///
    /// - 加载中（有地址、还没结果）：`false` —— 底层灰块就是加载态；
    /// - 失败且从没成功过：`true`；
    /// - 本来就没有地址：`true`（旧实现在这条分支会永远停在灰底，是本次一并修掉的）。
    func showsEmptyPlaceholder(hasURL: Bool) -> Bool {
        image == nil && (failed || !hasURL)
    }
}
