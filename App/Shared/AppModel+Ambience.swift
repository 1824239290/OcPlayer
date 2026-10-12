import AppDesignKit
import CoreModel
import DiagnosticsKit
import Foundation

/// 氛围池：会话级的一批随机 backdrop，首页轮播与所有"自垫背景"的页面共用同一张。
///
/// **为什么要把它从视图里搬出来**：池子决定 `homeAmbience`，而后者是 iOS 上一堆
/// 页面（四个 Tab 根页、详情页兜底、下载页）的背景源。原先池子住在
/// `AmbientBackdropCarousel` 的 `@State` 里、那个视图只挂在首页 Tab 内——冷启动
/// 直奔别的 Tab / 设置子页时池子从未装载，`homeAmbience` 恒 nil，那些页面整个会话
/// 都停在纯色底。搬到这里后由 `AppShellView` 根节点单点驱动（`.task(id:)`），
/// 与"当前停在哪个分区"解耦。
///
/// 存储属性在 `AppModel.swift`（Swift 扩展不能加存储属性），这里放行为。
enum AmbiencePool {
    /// 池子大小 × 换片间隔 ≈ 一轮 96s：够「随机感」也不浪费带宽。
    static let poolSize = 8
    static let swapInterval: Duration = .seconds(12)
    /// 氛围底图统一 800 宽小图 + 512px 解码——反正要糊掉，别为氛围图拉原画。
    static let imageWidth = 800
    /// 取池的随机查询条数。
    static let queryLimit = 24
}

/// 图片预热入口。
///
/// 抽成可替换的钩子只为一件事：**用例要能断言"预热完成后池子才非空"这条顺序**，
/// 而真预热走 `ImagePipeline.shared`，在测试里会真发网络请求（`stub.local` 的
/// DNS 还可能拖住用例）。生产路径与原来逐字相同。
@MainActor
enum AmbienceImageWarmup {
    static var warm: @MainActor (URL, String?, Int) async -> Void = { url, authHeader, maxPixelSize in
        _ = try? await ImagePipeline.shared.load(url, authHeader: authHeader, maxPixelSize: maxPixelSize)
    }
}

extension AppModel {

    /// 氛围池驱动入口：装载（必要时）→ 预热 → 换片循环。**双端唯一驱动点**。
    ///
    /// 由 `AppShellView` 的 `.task(id: ambienceTrigger)` 调用：触发键一变就重跑，
    /// 池子装好后触发键稳定在会话代次上，不会被首页刷新（isLoading 翻转、下拉
    /// 刷新）反复重启换片循环。
    func runAmbienceCarousel() async {
        await loadAmbiencePoolIfNeeded()
        await warmUpAndRotateAmbience()
    }

    /// 装载池子。三道闸门缺一不可：
    /// ① **同代次 + 同地址** 就跳过（不重拉、不重洗——iOS 上页面重建很频繁，
    ///    每次重洗会让背景闪成新的一批随机图）；
    /// ② 拉失败 / 库里没有带 backdrop 的条目：池子留空且**不记账**，等触发键变化
    ///    （首页数据到位、换服务器）后重试——这正是"冷启动抢跑后整个会话灰着"的修法；
    /// ③ 首图**预热完成**才让池非空，避免首页一进来先闪一块灰占位。
    func loadAmbiencePoolIfNeeded() async {
        let endpoint = serverEndpointURL?.absoluteString
        guard ambienceLoadedGeneration != sessionGeneration || ambienceLoadedEndpoint != endpoint else {
            return
        }

        let source: String
        var fetched = (try? await server?.randomBackdropItems(limit: AmbiencePool.queryLimit)) ?? []
        if fetched.isEmpty {
            // 服务器不支持随机查询 / 拉取失败：回退到首页已经拿到的条目。
            source = "home"
            fetched = home.latest + home.resume + home.nextUp
        } else {
            source = "random"
        }

        var seen = Set<String>()
        let candidates = fetched.filter { $0.backdropImageTag != nil && seen.insert($0.id).inserted }
        guard !candidates.isEmpty else {
            // 关键诊断点：两个来源同时为空 = 冷启动抢跑（或这个库真的一张 backdrop
            // 都没有）。此时不记账，触发键变化后会再试一次。
            AppDiagnostics.logInfo(
                "氛围池为空，等首页数据到位后重试 source=\(source) fetched=\(fetched.count)",
                fields: ["source": .string(source), "fetched": .integer(Int64(fetched.count))])
            return
        }

        let picked = Array(candidates.shuffled().prefix(AmbiencePool.poolSize))
        if let first = picked.first {
            let target = first.imageTarget(server, kind: .backdrop, width: AmbiencePool.imageWidth)
            if let url = target.url {
                await AmbienceImageWarmup.warm(url, target.authHeader, 512)
            }
        }
        if Task.isCancelled { return }

        ambiencePool = picked
        ambienceIndex = 0
        ambienceLoadedGeneration = sessionGeneration
        ambienceLoadedEndpoint = endpoint
        publishCurrentAmbience()
        AppDiagnostics.logInfo(
            "氛围池已装载 count=\(picked.count) source=\(source)",
            fields: ["count": .integer(Int64(picked.count)), "source": .string(source)])
    }

    /// 剩余图片预热进 ImagePipeline（之后每次切换都命中内存缓存），再进入换片循环。
    /// `reduceMotion` 下只保留静态首图，不做轮换。
    func warmUpAndRotateAmbience() async {
        guard server != nil, !ambiencePool.isEmpty else { return }
        for item in ambiencePool.dropFirst() {
            if Task.isCancelled { return }
            let target = item.imageTarget(server, kind: .backdrop, width: AmbiencePool.imageWidth)
            guard let url = target.url else { continue }
            await AmbienceImageWarmup.warm(url, target.authHeader, 512)
        }
        guard ambiencePool.count > 1, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: AmbiencePool.swapInterval)
            if Task.isCancelled { return }
            // 循环里再读一次：`reduceMotion` 由 AppShell 注入，可能与首次进入
            // 这条 task 同帧竞争，读早一拍就会在"减弱动态效果"下悄悄轮换起来。
            guard !reduceMotion else { return }
            ambienceIndex = (ambienceIndex + 1) % ambiencePool.count
            publishCurrentAmbience()
        }
    }

    /// 把当前这张声明给模型：详情页在自身底图就绪前拿它顶底（见 `homeAmbience` 注释）。
    /// 空池时不清空既有声明——上一张仍然可用（URL 未变、缓存命中），清了反而让
    /// 正在看它的页面闪一下纯色底。
    func publishCurrentAmbience() {
        let target = currentAmbienceTarget
        guard let url = target.url else { return }
        homeAmbience = WindowAmbience(url: url, authHeader: target.authHeader, scrim: .home)
    }

    /// 会话边界清空池子（`resetBrowseState` 调用）。
    ///
    /// 池里的图片 URL 带着**旧服务器的 authHeader**，与 `windowAmbienceStack`
    /// 同一个道理：不清掉，新会话首屏会拿旧凭据去请求图片。清完触发键变化，
    /// `AppShellView` 的 `.task(id:)` 会自动为新会话重装。
    func resetAmbiencePool() {
        ambiencePool = []
        ambienceIndex = 0
        ambienceLoadedGeneration = nil
        ambienceLoadedEndpoint = nil
    }
}
