import CryptoKit
import Foundation
import SwiftUI

/// 位图与容器比例不一致时怎么放。卡片图区（`MediaArtwork`）默认 `.fit`：
/// **服务端给什么比例就显示什么比例，不裁切**——Jellyfin/Emby 的海报并不是教科书
/// 2:3，实测本机库 26 部剧集里 22 部是 400×570（≈0.702）、2 部 400×533（0.75）、
/// 只有 1 部是 400×600（0.667），按 2:3 铺等于**每一张都裁掉一截**（0.702 的左右
/// 各裁 ~2.5%，0.75 的各裁 ~5.6%，阿松 / Re:0 那种连标题字都被切掉）。
public enum ArtworkScaling: Sendable {
    /// 填满容器、溢出裁掉（横排拼图这类「必须铺满」的场景）。
    case fill
    /// 完整显示整张图，等比缩放到容器内（不裁切）。
    case fit
}

/// 远程图视图：加载中 / 失败都有落点，占位色跟主题走。
public struct RemoteImage: View {
    /// 位图状态机：位图槽 + `representedKey` / `displayedKey` 双键 + 代次。
    /// 换 URL **不在这里清图**——旧帧留到新图真正上屏为止（见 `RemoteImageState`）。
    @State private var state = RemoteImageState()
    /// 已经回报过的位图尺寸：只在变化时回调，避免同一张图反复触发上层重排。
    @State private var reportedSize: CGSize?
    /// 已交给 `ImageArrivalScheduler`、还没上屏的到达项。
    ///
    /// 换 URL / 凭证 / 解码预算（= `.task(id:)` 重启）时取消它：旧图不该晚一拍盖上来。
    /// 取消是**优化**而不是正确性依赖：`RemoteImageState.apply` 自己会按代次作废旧回调。
    @State private var pendingArrival: ImageArrivalScheduler.Arrival?

    public let url: URL?
    public var authHeader: String?
    /// 解码目标最大长边像素数；指定后通过 ImageIO 进行下采样，大幅降低大图内存开销。
    /// nil = 不下采样（由调用方自己保证展示尺寸已知并显式给值）。
    public var maxPixelSize: Int? = nil
    /// 没有地址（或加载失败）时的占位图标，默认通用「photo」。
    /// 合集这类**容器条目在服务端本来就不带图**，给它们一个语义更准的图标
    /// （`PosterCard` 传 `rectangle.stack.fill`），别让整墙都是破图符号。
    public var emptyIcon: String = "photo"
    /// 换图时是否保留当前位图，直到新图加载完成。
    ///
    /// **保留仅为源码兼容**：双键 + 代次的状态机**始终**保留旧帧（换 URL 只移动
    /// `representedKey`），所以这个开关现在不再改变行为——灰闪已经由状态机本身消除。
    /// 老调用点（背景氛围层、详情翻页）继续传 `true` 也不会出问题。
    public var preserveCurrentImageOnReload = false
    /// 位图与容器比例不一致时的铺法（见 `ArtworkScaling`）。默认 `.fill` 沿用旧行为，
    /// 卡片图区由 `MediaArtwork` 按卡片语义决定。
    public var scaling: ArtworkScaling = .fill
    /// 位图解码完成后回报它的像素尺寸，供上层把盒子调成图片自己的比例。
    ///
    /// **为什么需要**：服务端没给 `PrimaryImageAspectRatio` 时（老服务器 / 条目是外部
    /// 加进去的），盒子只能先按兜底比例画；等图真到手上再按真实比例校正一次，
    /// 才能做到「图片四边刚好贴在边框上」——既不裁切、也不留灰边。
    /// 回调只在**尺寸变化**时触发（同一张图重复加载不会反复改布局）。
    public var onImageSizeChange: ((CGSize) -> Void)?
    /// 图片替换时使用的淡入节奏；未指定时使用标准短淡入。
    public var fadeAnimation: Animation? = nil
    /// 显式指定图片管道；nil = 取环境的 `imagePipeline`（默认 `.shared`）。
    ///
    /// 之所以同时留参数与环境值：环境值让 14 个调用点零改动就能被测试整体替换，
    /// 参数让个别用法可以钉死自己的管道（例如预览里塞一个空缓存实例）。
    public var pipeline: ImagePipeline? = nil

    @Environment(\.imagePipeline) private var environmentPipeline
    private var effectivePipeline: ImagePipeline { pipeline ?? environmentPipeline }

    /// `init` 里算好一次，body 里直接读。
    ///
    /// 改前这是**计算属性**，而它在 body 里被读 3 次（`.task(id:)` / `guard` / 赋值），
    /// 每次都要重跑 `credentialFingerprint`（SHA256 + 十六进制编码）。实测单次
    /// **15.04 µs**（其中 13.7 µs 花在 `String(format: "%02x")` 上），一屏 20 张卡
    /// 就是 **301 µs**。
    ///
    /// 能提前算的前提（已核）：`url` / `authHeader` / `maxPixelSize` 都只在 `init`
    /// 里赋值、之后不再改 —— `maxPixelSize` 虽声明 `var`，全仓无任何改写点。
    private let loadKeyValue: String

    public init(
        url: URL?,
        authHeader: String? = nil,
        maxPixelSize: Int? = nil,
        emptyIcon: String = "photo",
        preserveCurrentImageOnReload: Bool = false,
        scaling: ArtworkScaling = .fill,
        onImageSizeChange: ((CGSize) -> Void)? = nil,
        fadeAnimation: Animation? = nil,
        pipeline: ImagePipeline? = nil
    ) {
        self.url = url
        self.authHeader = authHeader
        self.maxPixelSize = maxPixelSize
        self.emptyIcon = emptyIcon
        self.preserveCurrentImageOnReload = preserveCurrentImageOnReload
        self.scaling = scaling
        self.onImageSizeChange = onImageSizeChange
        self.fadeAnimation = fadeAnimation
        self.pipeline = pipeline
        // 加载键只算一次：body 里要读三次（`.task(id:)` / guard / 赋值），
        // 每次重算就是一次 SHA256 + 十六进制编码（实测 15.04 µs）。
        // 同步命中分支也用它，避免留两套算法。
        let key = Self.loadKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
        self.loadKeyValue = key

        // 内存缓存命中就**同步**出图：首帧即有位图，不再经历「先占位、异步命中
        // 再淡入」。否则哪怕图早已在缓存里（详情页背景拿首页轮播那张顶底），推页
        // 那零点几秒里背景仍是页面底色——夜间闪黑、日间闪白。
        //
        // 注意 `init` 拿不到环境值（SwiftUI 的环境只在 body 期可读），所以这里只能
        // 用显式传入的管道或 `.shared`。仅通过环境注入时，这个同步命中会退化为
        // 异步加载的第一次命中——图仍会出，只是少了"首帧即有位图"的优化。
        let syncPipeline = pipeline ?? .shared
        let cached = url.flatMap {
            syncPipeline.memoryCachedImage(
                url: $0, authHeader: authHeader, maxPixelSize: maxPixelSize)
        }
        if let cached {
            // 同步命中也算「位图已在手上」：状态机直接以它开局（两个键都指向这张图），
            // 于是 `.task` 里的 `represent` 会回答「已经是这张」、不重复加载。
            _state = State(initialValue: RemoteImageState(image: cached, displayedKey: key))
            // 同步命中也算「图已到手」：尺寸回调要在同一拍发出去，否则盒子会停在
            // 兜底比例上，等下一次重绘才校正。
            _reportedSize = State(initialValue: cached.size)
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
        // 查表编码而不是 `String(format: "%02x", $0)`：后者每次约 1.7 µs
        // （走 NSString 格式化机器），八个字节就是 13.7 µs；查表一共 3.6 µs。
        // 实测 `String(format:)` 占本函数 **91%** 的时间，SHA256 本身只占 9%。
        // 输出逐字节相同（`testCredentialFingerprintMatchesFormatBasedHex` 对拍）。
        var hex: [UInt8] = []
        hex.reserveCapacity(16)
        for byte in digest.prefix(8) {
            hex.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            hex.append(Self.lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    /// 小写十六进制字符表。`String(format: "%02x")` 输出的就是小写。
    private static let lowercaseHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// 测试探针：把纯函数暴露给 `RemoteImageLoadKeyTests` 做对拍与形状断言。
    /// 只在测试构建（带 `DEBUG`）里编译，不污染发布产物。
    #if DEBUG
    static func probeCredentialFingerprint(_ header: String?) -> String {
        credentialFingerprint(header)
    }

    static func probeLoadKey(url: URL?, authHeader: String?, maxPixelSize: Int?) -> String {
        loadKey(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
    }
    #endif

    private static func loadKey(url: URL?, authHeader: String?, maxPixelSize: Int?) -> String {
        "\(url?.absoluteString ?? "")#\(credentialFingerprint(authHeader))#\(maxPixelSize ?? 0)"
    }

    public var body: some View {
        ZStack {
            // 常驻底层：加载中就是它在当占位，图片到位后从它上面淡入。
            // 灰度取 `Metrics.placeholderFill`，和骨架块同一个值——否则骨架撤掉、
            // 真实卡片上位而图还没下载完的那一瞬间，整墙灰会「变深一档」。
            // 它也是**唯一的布局锚点**：容器大小只由它（即外部提议）决定。
            Rectangle().fill(Metrics.placeholderFill)
            if state.showsEmptyPlaceholder(hasURL: url != nil) {
                // 没有地址（该条目本来就没有这种图）和加载失败共用落点：
                // 显示静态占位图标。判据收在 `RemoteImageState` 里（可单测）。
                // 关键：**只有「从来没有图」才落这里**——加载失败时旧帧还在，走不到这条分支。
                Image(systemName: emptyIcon)
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
            if let image = state.image {
                Image(platform: image)
                    .resizable()
                    // `.fill` ＝铺满裁切（旧行为），`.fit` ＝整张显示不裁切。位图的
                    // 画幅比例由服务端决定，容器比例是我们定的——两者不一致时必须
                    // 让位图赢，否则用户的封面永远缺一条边。
                    .aspectRatio(contentMode: scaling == .fill ? .fill : .fit)
                    // 身份跟着**屏幕上那张图**走（不是跟着属性要求的键走）：
                    // 换 URL 而新图还没到时 `.id` 不变，SwiftUI 不会把旧帧拆掉重建。
                    .id(state.displayedKey)
                    // 加载完成在占位层上淡入，不再硬弹出；保留旧帧时，
                    // 新图也沿同一过渡交叉淡入。
                    .transition(.section)
            }
        }
        .clipped()
        .motion(fadeAnimation ?? Motion.standard, value: state.displayedKey)
        // 位图尺寸变化就回报（见 `onImageSizeChange`）。放在 overlay 之后、不进布局，
        // 用 `.onChange` 而不是在加载回调里直接调——后者会撞上「视图更新期间改状态」。
        .onChange(of: state.image?.size, initial: true) { _, size in
            guard let size, size != reportedSize else { return }
            reportedSize = size
            onImageSizeChange?(size)
        }
        .task(id: loadKeyValue) {
            // A row can keep its SwiftUI identity while its media value changes
            // (season switching / refresh). The state machine keeps the previous
            // bitmap on screen until the replacement is ready; nothing is cleared
            // on URL change, so there is no grey flash in between.

            // 任务重启（换 URL / 凭证 / 解码预算 / 视图消失）先作废还没上屏的到达项：
            // 不取消也能靠代次兜住，但取消能省下一次多余的 SwiftUI 状态写入。
            if let pendingArrival {
                ImageArrivalScheduler.shared.cancel(pendingArrival)
                self.pendingArrival = nil
            }

            guard let url else {
                // 明确的「没有地址」= 明确的清空意图（旧的 URL 不再代表任何东西）。
                state.represent(nil)
                return
            }
            // 推进代次并声明要求。返回 nil = 屏幕上已经是这张图（首帧同步缓存命中 /
            // 同键重入），不必再加载；返回代次 = 这次加载的结果要带着它回来。
            //
            // 失败不记「已加载」：视图再次出现时还能重试——瞬时断网不该让这张图
            // 永远停在占位上。复合键（URL + 凭证 + 目标尺寸）一致才跳过重载，否则
            // 会一直显示错误尺寸 / 别的账号的旧位图。
            guard let generation = state.represent(loadKeyValue) else { return }
            do {
                let loaded = try await effectivePipeline.load(
                    url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }   // 换 URL / 消失：新任务会接手，别写旧图
                guard let loaded else {
                    // 失败：只置 `failed`，旧帧原样留着（从未有图时才会落占位）。
                    state.fail(key: loadKeyValue, generation: generation)
                    return
                }
                apply(loaded, key: loadKeyValue, generation: generation)
            } catch {
                // 只把真正的失败当失败：任务取消（视图消失 / 换 URL）不算，
                // 下次出现时 `.task(id:)` 会重新走一遍。
                guard !Task.isCancelled else { return }
                state.fail(key: loadKeyValue, generation: generation)
            }
        }
    }

    // MARK: - 上屏

    /// 把一次成功的到达交给 `ImageArrivalScheduler`，由它按帧预算批量上屏。
    ///
    /// **为什么要排队**：一墙海报同时下载完时，N 个 `@State` 写入会让 SwiftUI 在
    /// 同一拍里跑 N 次 body 求值 + 布局；按帧预算摊到几帧之后，掉帧变成可预测的匀速。
    ///
    /// 失败**不排队**：失败只写一个 `Bool`，而且用户等这个结果（占位要尽快出现），
    /// 没有理由让它排在图片后面。
    private func apply(_ image: PlatformImage, key: String, generation: UInt64) {
        // 闭包通过 `self` 写入 `@State`（`State` 的 setter 是 nonmutating，视图是值类型
        // 也能安全写）。它最多活到下一帧就被执行，所以这里的 `self` 捕获是短命的。
        let arrival = ImageArrivalScheduler.shared.enqueue {
            // 代次 / 键不匹配（换 URL 了、或已经上过别的图）→ 这次到达作废。
            // 判断在状态机里，闭包不需要再问一遍「我还是最新的吗」。
            _ = self.state.apply(image, key: key, generation: generation)
        }
        guard let arrival else {
            // 队列撞上硬上限（只在「重入生产」时发生）：正确性优先于帧预算，
            // 立刻上屏。静默丢一张已经下载好的图会让界面永远停在旧帧上。
            state.apply(image, key: key, generation: generation)
            return
        }
        // 只记最新一次到达项：`.task` 重启时取消它（对已执行的令牌是幂等 no-op），
        // 因此不需要在闭包里回写这个槽位。
        pendingArrival = arrival
    }
}
