import AppDesignKit
import CoreModel
import SwiftUI

/// 何时尝试装载氛围池。
///
/// 抽成纯值是为了可测：这里的判断错一次，后果是**整个会话都停在纯色底**
/// —— 而它恰恰只在冷启动抢跑时才出错，平时看不出来。
///
/// 实机日志（2026-09-30）就是这个场景：启动瞬间网络还没就绪，五个请求全部
/// `-1009`，其中氛围池的 `randomBackdropItems` 与它的回退源（`home.latest` /
/// `resume` / `nextUp`）**同时为空** → 池子装不上；而 `.task(id:)` 只认
/// `sessionGeneration`，它没变 → 这个会话再也不会重试，背景灰到关 App。
/// 下次启动网络恰好就绪，于是"自己好了"——这种偶发性正是它难被发现的原因。
struct BackdropCarouselTrigger: Hashable {
    let session: Int
    /// 是否值得再试一次。
    let shouldRetry: Bool
    /// 当前生效的服务器地址。地址换了（局域网 → Tailscale）时池子里的图片 URL
    /// 全部指着刚失效的那条，必须重拉一遍 —— 服务器地址是运行时决议的，视图不重建
    /// 就发现不了（`MediaServer` 的 `profile.baseURL` 不是可观察状态）。
    let endpoint: String?

    init(
        sessionGeneration: Int,
        poolIsEmpty: Bool,
        hasHomeFallback: Bool,
        endpoint: String? = nil
    ) {
        self.session = sessionGeneration
        self.endpoint = endpoint
        // 池子空着 + 首页数据已到位 = 一次值得重试的机会。
        // 池子装好后 `shouldRetry` 恒为 false，触发键稳定在 session 上，
        // 不会因为首页后续刷新（isLoading 翻转等）反复重启换片循环。
        self.shouldRetry = poolIsEmpty && hasHomeFallback
    }
}

/// 首页氛围背景：从库里随机取一批带 backdrop 的电影 / 剧集（`randomBackdropItems`），
/// 复用 `BackdropAmbienceView` 铺成模糊+雾化的固定底，每 12 秒淡入淡出换一张。
/// 纯装饰：查询失败或库里没有带 backdrop 的条目就整体不出现，页面回退纯色底。
///
/// 氛围图**常开**：设置页原有的「海报氛围背景」开关与 `SettingsKeys.ambientBackdrop`
/// 已一并移除，首页与详情页一律铺氛围底。旧偏好键不再有任何读取点——老用户盘上
/// 残留的 `false` 是死键，升级后氛围图照常出（见 CHANGELOG）。
struct AmbientBackdropCarousel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowFullscreen) private var isWindowFullscreen
    /// 池子大小 × 换片间隔 ≈ 一轮 96s：够「随机感」也不浪费带宽。
    private static let poolSize = 8
    private static let swapInterval: Duration = .seconds(12)
    /// 氛围底图统一 800 宽小图 + 512px 解码下采样——反正要糊掉，不拉原画。
    private static let imageWidth = 800

    @State private var pool: [MediaItem] = []
    @State private var index = 0
    /// 已装载池子的会话代次。iOS 上轮播垫在首页 Tab 栈内，`.task` 随 Tab 离屏被
    /// 取消、回到首页重启——同代次不重拉重洗，否则每次回首页背景都换成新一批
    /// 随机图，其他 Tab 垫的 `homeAmbience` 也跟着闪换成「首页刚刷出来的那张」。
    @State private var loadedGeneration: Int?
    /// 装载池子时用的服务器地址。协议决议（局域网 / Tailscale 择优）可能在同一
    /// 会话内换址，池子里的图片 URL 随之作废，得按新地址重拉一次。
    @State private var loadedEndpoint: String?

    /// 首页是否已有可作回退的条目（`loadPool` 在随机查询失败时用它们兜底）。
    private var hasHomeFallback: Bool {
        !(app.home.latest.isEmpty && app.home.resume.isEmpty && app.home.nextUp.isEmpty)
    }

    /// 装载触发键：会话代次 + 当前生效地址 + 「池子空着但已有回退源」这个补救机会。
    private var loadTrigger: BackdropCarouselTrigger {
        BackdropCarouselTrigger(
            sessionGeneration: app.sessionGeneration,
            poolIsEmpty: pool.isEmpty,
            hasHomeFallback: hasHomeFallback,
            endpoint: app.serverEndpointURL?.absoluteString)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if !pool.isEmpty {
                    BackdropAmbienceView(
                        target: pool[index % pool.count]
                            .imageTarget(app.server, kind: .backdrop, width: Self.imageWidth),
                        scrim: .home
                    )
                    .transition(.section)
                }
            }
            .animation(Motion.ambient, value: index)

            // 全屏顶栏是不透明硬底（macOS 26 系统行为），顶部向窗口底色渐隐衔接；
            // 窗口态工具栏透明，图直接透出。见 FullscreenTitlebarFade。
            // **放在换片动画作用域之外**：放进去换片时会被交叉淡入卷着一起动，
            // 背景里滑出一条渐变带（全屏下肉眼可见）。
            if isWindowFullscreen {
                FullscreenTitlebarFade()
                    .transition(.opacity)
            }
        }
        .animation(Motion.ambient, value: isWindowFullscreen)
        // 会话代次并进 task id：换服务器 / 重新登录时重拉池子。
        // 另外并进 `shouldRetry`：冷启动抢跑导致池子空着时，等首页数据到位再试一次
        // （见 `BackdropCarouselTrigger` 的注释——不加这个，那个会话就一直是纯色底）。
        .task(id: loadTrigger) {
            let endpoint = app.serverEndpointURL?.absoluteString
            if loadedGeneration != app.sessionGeneration || loadedEndpoint != endpoint {
                await loadPool()
                // 拉取失败不记账：下次触发还能重试。
                if !pool.isEmpty {
                    loadedGeneration = app.sessionGeneration
                    loadedEndpoint = endpoint
                }
            }
            await warmUpAndRotate()
        }
        // 把当前这张声明给 AppModel：详情页在自身底图就绪前拿它顶底（见
        // `AppModel.homeAmbience`）。
        .onChange(of: index) { _, _ in publishCurrent() }
        .onChange(of: pool) { _, _ in publishCurrent() }
    }

    private func publishCurrent() {
        guard !pool.isEmpty else { return }
        let target = pool[index % pool.count]
            .imageTarget(app.server, kind: .backdrop, width: Self.imageWidth)
        app.homeAmbience = target.url.map {
            WindowAmbience(url: $0, authHeader: target.authHeader, scrim: .home)
        }
    }

    /// 查询 → 去重洗牌 → 首图进缓存后才亮相，避免首页一进来先闪一块灰占位。
    private func loadPool() async {
        pool = []
        index = 0
        guard let server = app.server else { return }

        // 全程留痕（info 级，默认档可见）。氛围底"没出来"是个用户能一眼看到、
        // 但我们此前**完全没有证据**的现象——排查时只能靠截图猜它卡在哪一步。
        // 冷启动抢跑（网络未就绪）正是它最常出现的时机，而那又是最难看出来的。
        var source = "random"
        var fetched = (try? await server.randomBackdropItems(limit: 24)) ?? []
        if fetched.isEmpty {
            // 服务器不支持随机查询 / 拉取失败：回退到首页已经拿到的条目。
            source = "home"
            fetched = app.home.latest + app.home.resume + app.home.nextUp
        }
        var seen = Set<String>()
        let candidates = fetched.filter { $0.backdropImageTag != nil && seen.insert($0.id).inserted }
        guard !candidates.isEmpty else {
            // 关键诊断点：两个来源同时为空 = 冷启动抢跑。此时不记账（调用方
            // `loadedGeneration` 不推进），等触发键变化后会再试一次。
            AppDiagnostics.logInfo(
                "氛围池为空，等首页数据到位后重试 source=\(source) fetched=\(fetched.count)",
                fields: ["source": .string(source), "fetched": .integer(Int64(fetched.count))])
            return
        }

        let picked = Array(candidates.shuffled().prefix(Self.poolSize))
        if let first = picked.first {
            let target = first.imageTarget(server, kind: .backdrop, width: Self.imageWidth)
            if let url = target.url {
                _ = try? await ImagePipeline.shared.load(
                    url, authHeader: target.authHeader, maxPixelSize: 512
                )
            }
        }
        if Task.isCancelled { return }
        pool = picked
        AppDiagnostics.logInfo(
            "氛围池已装载 count=\(picked.count) source=\(source)",
            fields: ["count": .integer(Int64(picked.count)), "source": .string(source)])
    }

    /// 剩余图片预热进 ImagePipeline（之后每次切换都命中内存缓存），再进入换片循环。
    /// `reduceMotion` 下只保留静态首图，不做轮换。
    private func warmUpAndRotate() async {
        guard let server = app.server, !pool.isEmpty else { return }
        for item in pool.dropFirst() {
            if Task.isCancelled { return }
            let target = item.imageTarget(server, kind: .backdrop, width: Self.imageWidth)
            guard let url = target.url else { continue }
            _ = try? await ImagePipeline.shared.load(
                url, authHeader: target.authHeader, maxPixelSize: 512
            )
        }
        guard pool.count > 1, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.swapInterval)
            if Task.isCancelled { return }
            index = (index + 1) % pool.count
        }
    }
}
