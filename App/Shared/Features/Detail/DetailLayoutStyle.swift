import SwiftUI

/// 详情页版式的**唯一判定点**。
///
/// ## 为什么要有它
///
/// 2026-11-04 之前，详情页的版式选择散在 `DetailView` / `DetailPageFlip` 里
/// **12 处 `#if os(macOS)`**（编译期）。那种写法只能表达「macOS 一套 / iOS 另一套」，
/// 表达不了「同一个二进制里，iPad 全屏要 flip、分屏要 banner」——
/// 而后者是运行期才知道的。
///
/// 所以版式选择收成这一个类型：**判定只有一处，消费方一律读 `detailLayoutStyle`**。
/// 各处不再自己写平台判断，也就不会再出现「这里按 os 判、那里按宽度判」的分叉
/// （那种分叉在 iPad 上必然对不上，而且只有真机才看得见）。
///
/// ## 与平台门控的分工（不要混）
///
/// 这个类型回答的是**版式**。它**不**回答**API 可用性**：
///
/// | 类型 | 例子 | 形态 |
/// | --- | --- | --- |
/// | 版式选择 | 走 flip 还是 banner | 运行期（本类型） |
/// | API 可用性 | `NSEvent` 滚轮监视器 / `NSWindow` 回报 | 编译期（仍留 `#if`） |
///
/// `DetailPageFlip` 里的滚轮监视器、`DetailPageWindowAnchor` 是 macOS 专属 API，
/// 即使 `DetailLayoutStyle` 是 `.flip` 它们也只在 macOS 存在——那部分必须继续
/// 留在 `#if os(macOS)` 内，**不能靠改这个类型的返回值让它们跨平台**。
enum DetailLayoutStyle: Hashable {
    /// 整页翻页版式：第一页头图 + 选集带，翻到第二页正文。
    /// 视觉与状态机见 `DetailPageFlip`。
    case flip

    /// 横幅 + 详情滚动区版式（改造前 iOS 的既有版式，含紧凑头部与常规头部两档）。
    /// 实现见 `DetailView` 里 `#if !os(macOS)` 那段。
    case banner

    /// 判定入口。**所有版式相关的分支都必须调它**，不要在别处重复这套逻辑。
    ///
    /// - Parameters:
    ///   - isPad: 当前是不是 iPad 类设备（`UIDevice.userInterfaceIdiom == .pad`；
    ///     macOS 传 `false`，它由下面的编译期分支直接短路）。
    ///   - hSizeClass: 当前窗口的 `horizontalSizeClass`。iPad 分屏 / 侧拉是 `.compact`。
    ///
    /// ## 判定表（阶段 ①，2026-11-04 起生效）
    ///
    /// | 设备 | 宽度 | 版式 |
    /// | --- | --- | --- |
    /// | iPhone | 任意（含 Pro Max 横屏的 `.regular`） | `.banner` |
    /// | iPad | `.regular`（全屏） | `.flip` |
    /// | iPad | `.compact`（分屏 / 侧拉） | `.banner` |
    /// | iPad | `nil`（尺寸类未知） | `.banner` |
    ///
    /// iPad 分屏退回 banner 的理由：翻页版式的第一页是左右分栏（左 LOGO / 简介 / 播放钮，
    /// 右清晰剧照），紧凑宽度下会挤成一列；而且此时可用宽度与 iPhone 同级，保持一致。
    ///
    /// `nil` 取 banner 是保守选择：宁可维持旧版式，也不给一个「有版式没输入」的翻页界面。
    static func resolve(isPad: Bool, hSizeClass: UserInterfaceSizeClass?) -> Self {
        #if os(macOS)
        // macOS 详情页只有 flip 一套（旧横幅已整个删掉，无剧照条目由
        // `DetailPageArt` 自己出占位底色，没有回退分支）。
        return .flip
        #else
        // iOS：判定表在 `resolveTable` 里，拆出去是为了**两个 CI 平台都测得到**。
        return resolveTable(isPad: isPad, hSizeClass: hSizeClass)
        #endif
    }

    /// 判定表本体：**纯函数，不碰任何平台 API**。
    ///
    /// 之所以要从 `resolve` 里拆出来：`resolve` 在 macOS 上被 `#if os(macOS)` 短路，
    /// 判定表若写在它内部，macOS 的测试 job 就永远执行不到这几行——
    /// 「iPhone 恒 banner」这条判据只在 iOS 那半边成立，有人动了 macOS 的短路也不会有用例变红。
    /// 拆出来以后，两个平台的测试跑的是**同一份实现**。
    static func resolveTable(isPad: Bool, hSizeClass: UserInterfaceSizeClass?) -> Self {
        // iPhone 一律 banner，与尺寸类无关：不要因为 Pro Max 横屏是 `.regular`
        // 就把它切成翻页版式。
        guard isPad else { return .banner }
        // iPad 只有「常规宽度」才走翻页版式；分屏 / 侧拉 / 未知宽度都维持 banner。
        return hSizeClass == .regular ? .flip : .banner
    }
}
