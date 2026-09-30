import CryptoKit
import Foundation
import SwiftUI

/// 远程图视图：加载中 / 失败都有落点，占位色跟主题走。
public struct RemoteImage: View {
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var loadedKey: String?

    public let url: URL?
    public var authHeader: String?
    /// 解码目标最大长边像素数；指定后通过 ImageIO 进行下采样，大幅降低大图内存开销。
    public var maxPixelSize: Int? = nil
    /// 换图时是否保留当前位图，直到新图加载完成。适合背景图等需要连续画面的场景。
    public var preserveCurrentImageOnReload = false
    /// 图片替换时使用的淡入节奏；未指定时使用标准短淡入。
    public var fadeAnimation: Animation? = nil
    /// 显式指定图片管道；nil = 取环境的 `imagePipeline`（默认 `.shared`）。
    ///
    /// 之所以同时留参数与环境值：环境值让 14 个调用点零改动就能被测试整体替换，
    /// 参数让个别用法可以钉死自己的管道（例如预览里塞一个空缓存实例）。
    public var pipeline: ImagePipeline? = nil

    @Environment(\.imagePipeline) private var environmentPipeline
    private var effectivePipeline: ImagePipeline { pipeline ?? environmentPipeline }

    public init(
        url: URL?,
        authHeader: String? = nil,
        maxPixelSize: Int? = nil,
        preserveCurrentImageOnReload: Bool = false,
        fadeAnimation: Animation? = nil,
        pipeline: ImagePipeline? = nil
    ) {
        self.url = url
        self.authHeader = authHeader
        self.maxPixelSize = maxPixelSize
        self.preserveCurrentImageOnReload = preserveCurrentImageOnReload
        self.fadeAnimation = fadeAnimation
        self.pipeline = pipeline
        // 内存缓存命中就**同步**出图：首帧即有位图，不再经历「先占位、异步命中
        // 再淡入」。否则哪怕图早已在缓存里（详情页背景拿首页轮播那张顶底），推页
        // 那零点几秒里背景仍是页面底色——夜间闪黑、日间闪白。
        //
        // 注意 `init` 拿不到环境值（SwiftUI 的环境只在 body 期可读），所以这里只能
        // 用显式传入的管道或 `.shared`。仅通过环境注入时，这个同步命中会退化为
        // 异步加载的第一次命中——图仍会出，只是少了"首帧即有位图"的优化。
        let syncPipeline = pipeline ?? .shared
        if let url,
           let cached = syncPipeline.memoryCachedImage(
            url: url, authHeader: authHeader, maxPixelSize: maxPixelSize
           ) {
            _image = State(initialValue: cached)
            _loadedKey = State(initialValue: Self.loadKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize))
        }
    }

    /// 与 .task(id:) 一致的复合加载键：URL + 凭证指纹 + 目标尺寸。
    ///
    /// 凭证指纹用 SHA256 截断，不用 `String.hashValue`：hashValue 只保证同进程内
    /// 同一字符串稳定，且这里比较的是「头字符串是否逐字节一致」——历史教训是
    /// authHeader 由 Dictionary 拼接、键序会抖，同语义头产生多种字节串、hash
    /// 随之漂移，.task(id:) 每次漂移都当作「新任务」清图重载，表现为图片反复闪。
    private static func credentialFingerprint(_ header: String?) -> String {
        guard let header else { return "none" }
        let digest = SHA256.hash(data: Data(header.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadKey(url: URL?, authHeader: String?, maxPixelSize: Int?) -> String {
        "\(url?.absoluteString ?? "")#\(credentialFingerprint(authHeader))#\(maxPixelSize ?? 0)"
    }

    private var loadKey: String {
        Self.loadKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            // 常驻底层：加载中就是它在当占位，图片到位后从它上面淡入。
            // 灰度取 `Metrics.placeholderFill`，和骨架块同一个值——否则骨架撤掉、
            // 真实卡片上位而图还没下载完的那一瞬间，整墙灰会「变深一档」。
            // 它也是**唯一的布局锚点**：容器大小只由它（即外部提议）决定。
            Rectangle().fill(Metrics.placeholderFill)
            if image == nil, failed || url == nil {
                // 没有地址（该条目本来就没有这种图）和加载失败共用落点：
                // 显示静态占位图标。否则 url 为 nil 时会永远转圈（task 里被 guard 挡掉）。
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            // 加载中不需要额外分支：底层那块灰就是占位（原来这里又画了一块
            // 一模一样的 Rectangle，视觉上是 no-op，只多一层合成）。
        }
        // 位图画在 overlay：成败与否都**不反哺布局**。此前位图直接当 ZStack
        // 子层，scaledToFill 的覆盖尺寸会参与布局——位图到位瞬间容器理想尺寸
        // 从「无比例」跳到「图片比例」，挂在容器上的长动画（氛围层 1.6s）会把它
        // 当几何变化播出来：整窗背景「闪一下变大再沉降」。overlay 不影响宿主
        // 尺寸，图到位只剩纯淡入。
        .overlay {
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFill()
                    .id(loadedKey)
                    // 加载完成在占位层上淡入，不再硬弹出；背景图保留旧帧时，
                    // 新图也沿同一过渡交叉淡入。
                    .transition(.section)
            }
        }
        .clipped()
        .animation(imageFade, value: loadedKey)
        .task(id: loadKey) {
            // A row can keep its SwiftUI identity while its media value changes
            // (season switching / refresh). Ordinary content clears the previous
            // bitmap; background content keeps it until the replacement is ready.
            guard let url else {
                image = nil
                loadedKey = nil
                failed = false
                return
            }
            // 只有成功过的组合才跳过重载：失败的不记 loadedKey，
            // 视图再次出现时还能重试（瞬时断网不该让这张图永远 404 下去）。
            // 复合键（URL+凭证+目标尺寸）一致才跳过：同 URL 换尺寸/凭证要重载，
            // 否则会一直显示错误尺寸的旧位图。
            guard loadedKey != loadKey else { return }
            // 普通内容先清空，避免复用行时旧海报贴在新标题旁边；背景图则保留
            // 当前帧，直到新图加载完成，避免切换时闪灰色占位。
            if !preserveCurrentImageOnReload {
                image = nil
                loadedKey = nil
            }
            failed = false
            do {
                let loaded = try await effectivePipeline.load(url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }   // 换 URL / 消失：新任务会接手，别写旧图
                if let loaded {
                    image = loaded
                    loadedKey = loadKey
                } else {
                    failed = true
                }
            } catch {
                // 只把真正的失败当失败：任务取消（视图消失 / 换 URL）不算，
                // 下次出现时 `.task(id:)` 会重新走一遍。
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    /// 图片出现/消失的淡入淡出；减弱动态效果时直接切换，不播动画。
    private var imageFade: Animation? {
        reduceMotion ? nil : (fadeAnimation ?? Motion.standard)
    }
}
