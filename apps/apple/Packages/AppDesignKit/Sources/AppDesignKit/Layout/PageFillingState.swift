import SwiftUI

/// 抱紧内容的状态视图（空态 / 失败态 / 门控引导）的**铺满载体**。
///
/// ## 为什么必须用它
///
/// AppShell 把氛围底图挂在根节点的 `.background` 上，而 `.background` 拿到的
/// 尺寸就是宿主视图的尺寸、且**不会反过来把宿主撑大**——宿主多大，背景就多大。
/// 于是当分区的根视图是一个「理想尺寸固定」的状态视图时，整条尺寸链会跟着塌成
/// 内容那一小块，背景也只剩那一小块：整页看起来「只有中间一块有图」，窗口其余
/// 部分露出窗口底色，顶栏玻璃底下也没了图。
///
/// 实机实测（1100×700 窗口，MoviePilot 未登录门控）：`ContentUnavailableView`
/// 的理想尺寸是 **400×400**，且**不随窗口变化**——同一页面在 1384×869 与
/// 1100×700 两个窗口下，有图的那块都是 400×400 居中。对照同窗口的 Bangumi 页：
/// 顶栏像素 (159,127,99)（透过玻璃的氛围图），而 MoviePilot 页顶栏与四周一律
/// (41,43,43)（`windowBackgroundColor`）——即背景层确实塌了，不是遮罩盖的。
///
/// ## 为什么是 ScrollView
///
/// ScrollView 不吃「理想尺寸」，它铺满被给到的空间，于是这条尺寸链从它开始
/// 一路把页面、导航栈、外壳撑满窗口，`.background` 自然拿到整窗尺寸。
/// 给状态视图自己加 `.frame(maxWidth: .infinity, maxHeight: .infinity)`（哪怕
/// 连带 `.ignoresSafeArea()`）**不管用**——实测仍然塌（见 CHANGELOG 里
/// 「裸 EmptyState 连 frame 撑满 + ignoresSafeArea 都救不回来」那条）。
/// `containerRelativeFrame(.vertical)` 负责把内容在可视区里垂直居中。
///
/// 同款载体原先在 `HomeView` 里有一份私有实现（`SearchEmptyState` 与
/// `errorState` 内联各一份），提到这里是为了让「根级状态视图必须铺满」这条约定
/// 只有一个落点、一处解释。
public struct PageFillingState<Content: View>: View {
    @ViewBuilder public var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
