import SwiftUI

/// 登录页海报墙的全部视觉常量，集中一处，调色 / 调几何时不用翻视图代码。
///
/// 这面墙的**唯一**动态来源是鼠标（指针）驱动的 3D 倾斜：没有 `TimelineView`、
/// 没有 `repeatForever`、没有任何跑马灯。静止时它是一张纯静态合成图，不占渲染时钟。
public enum LoginWallStyle {

    // MARK: - 几何

    /// 屏幕上**可见**的列数。墙按 `contentScale` 放大后再缩放回来，所以这个数
    /// 是屏幕口径而不是渲染口径，两者不一致时 tile 会大得像广告牌。
    public static let visibleColumns: CGFloat = 8.6
    public static let contentScale: CGFloat = 1.24
    public static let minimumColumnWidth: CGFloat = 112
    public static let maximumColumnWidth: CGFloat = 178
    /// tile 高宽比。媒体库海报是 2:3 上下，取 1.42 让竖版海报刚好铺满不留边。
    public static let posterAspect: CGFloat = 1.42
    public static let itemSpacing: CGFloat = 13
    public static let cornerRadius: CGFloat = 9
    /// 墙比视口上下各高出这个比例，倾斜后四角依然被盖住。
    public static let verticalOverscan: CGFloat = 0.16

    // MARK: - 墙的压色

    /// 把封面从满饱和拉回来，让卡片与强调橙成为画面里唯一的暖色。
    public static let wallSaturation: Double = 0.78
    public static let wallBrightness: Double = -0.06

    // MARK: - 指针跟随

    /// 墙的静止俯角，以及指针能在此基础上叠加多少度。
    public static let tiltDegrees: Double = 12
    public static let pointerTiltDegrees: Double = 5
    /// 墙整体位移。**没有列级视差**：那需要每列各带一个跟着指针走的 offset，
    /// 而它在布局层改变，实测单独一项就占指针移动时 CPU 的 26 个百分点；
    /// 墙改成「一张合成图」之后它在结构上也不再可能。景深由整墙的 3D 倾斜表达。
    public static let parallaxPoints: CGFloat = 24

    // MARK: - 调色

    /// 品牌橙，直接取自 AppIcon（亮面 `#FE8A03` / 暗面 `#FE6602`）。
    /// 与 demo 的琥珀色几乎同源，所以那套高光 / 光晕配方可以直接沿用。
    public static let accent = Color(red: 0.996, green: 0.541, blue: 0.012)
    public static let accentDeep = Color(red: 0.996, green: 0.400, blue: 0.008)
    /// 氛围层里与暖橙对位的冷色，负责把画面从「一片橙」拉回中性。
    public static let violet = Color(red: 0.47, green: 0.38, blue: 1.0)

    /// 卡片后面那层光晕的颜色：成功态转绿，其余跟随品牌橙。
    public static func glow(success: Bool) -> Color {
        success ? Color(red: 0.42, green: 0.88, blue: 0.60) : accent
    }

    /// 墙后面的底色。海报墙是一张照片，两种外观下都要从一块底色上浮起来——
    /// 夜间近黑、日间近白，与遮罩的 tint 同向。
    public static func backdrop(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 0.93, green: 0.92, blue: 0.94)
            : Color(red: 0.035, green: 0.033, blue: 0.045)
    }

    /// 遮罩强度，按外观取。
    ///
    /// 两个值都是**看着真海报调出来的**（本机 47 张媒体库海报渲染对照）：
    /// 夜间 1.0 会把海报压成一片黑，0.72 才既压得住卡片背后、又留得住海报本身；
    /// 日间是白纱，同样强度会把整面墙洗成灰雾，0.32 是一层薄雾。
    public static func scrimStrength(for scheme: ColorScheme) -> Double {
        scheme == .light ? 0.32 : 0.72
    }

    // MARK: - 取图参数

    /// 复原历史海报时的参数阶梯。
    ///
    /// **`maxWidth`（URL 查询）与 `maxPixelSize`（解码预算）都是缓存键的一部分**
    /// （见 `ImagePipeline.requestKey`），所以想命中库里已经存下的字节，就必须报出
    /// 当初存进去的那一对值。这对值由海报卡的盒子宽度决定
    /// （`ArtworkMetrics.pixelBudget`），会随布局改动而漂移——把历史值列成阶梯逐个
    /// 试，比钉死一个值稳得多：命中任何一档都出图，全不中就退程序化封面。
    ///
    /// 每一档的代价只是一次「文件在不在」的判断，不发网络请求。
    public static let cacheParameterLadder: [(maxWidth: Int, maxPixelSize: Int)] = [
        (400, 400),  // 常规网格海报卡：实测覆盖绝大多数历史缓存
        (300, 300),  // 紧凑布局 / 详情页海报
        (720, 360),  // 库封面 / 横版剧照
    ]
}
