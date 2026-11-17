import Foundation

/// 跨页面高频复用的中文文案集中定义。
///
/// 不建 .xcstrings：自用单语、字面量隐式走 LocalizedStringKey，catalog 只分离
/// 语言文件与代码、无实际收益还带几十文件级联 diff。这里只收
/// 真正跨文件重复的文案（加载失败 / 重试 / 空态），一次性按钮文字留在原地。
public enum UIStrings {
    /// 通用「加载失败」标题（各页 ContentUnavailableView 统一）。
    public static let loadFailed = "加载失败"
    /// 通用「重试」按钮。
    public static let retry = "重试"
    /// 通用「搜索失败」标题（搜索结果为空但出错时）。
    public static let searchFailed = "搜索失败"
    /// 通用「加载更多」按钮（分页列表底部）。
    public static let loadMore = "加载更多"
}
