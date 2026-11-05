import SwiftUI

/// 详情页版式的唯一判定点。iPhone 使用竖向封面，宽屏使用左右布局。
enum DetailLayoutStyle: Hashable {
    case flip
    /// iPad 紧凑分屏的滚动版式。
    case banner

    static func resolve(isPad: Bool, hSizeClass: UserInterfaceSizeClass?) -> Self {
        #if os(macOS)
        return .flip
        #else
        return resolveTable(isPad: isPad, hSizeClass: hSizeClass)
        #endif
    }

    static func resolveTable(isPad: Bool, hSizeClass: UserInterfaceSizeClass?) -> Self {
        guard isPad else { return .flip }
        return hSizeClass == .regular ? .flip : .banner
    }
}
