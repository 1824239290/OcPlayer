import AppDesignKit
import CoreModel
import DiagnosticsKit
import Foundation

/// 氛围池：会话级的一批随机 backdrop，首页轮播与所有"自垫背景"的页面共用同一张。
///
/// **为什么要把它从视图里搬出来**：池子决定 `currentAmbienceTarget`，而后者是 iOS 上一堆
/// 页面（四个 Tab 根页、详情页兜底、下载页）的背景源。原先池子住在
/// `AmbientBackdropCarousel` 的 `@State` 里、那个视图只挂在首页 Tab 内——冷启动
/// 直奔别的 Tab / 设置子页时池子从未装载，取图三元组恒 nil，那些页面整个会话
/// 都停在纯色底。搬到这里后由 `AppShellView` 根节点单点驱动（`.task(id:)`），
/// 与"当前停在哪个分区"解耦。
///
/// 存储属性在 `AppModel.swift`（Swift 扩展不能加存储属性），这里放行为。
@MainActor
enum AmbiencePool {
    /// 池子大小 × 换片间隔 ≈ 一轮 96s：够「随机感」也不浪费带宽。
    static let poolSize = 8
    static let swapInterval: Duration = .seconds(12)
    /// 换片间隔的**容差**（`P2-36` 的可采纳部分）。
    ///
    /// 这个循环 12 秒醒一次、只为了把 `ambienceIndex` 加一 —— 精确到毫秒唤醒毫无收益，
    /// 却是**一次真实的 timer 唤醒**。给容差让系统把唤醒攒进别的唤醒里
    /// （macOS / iOS 都做 timer coalescing），省电。
    ///
    /// ## 语义（实测，不是推测）
    ///
    /// `Task.sleep(for:tolerance:)` 的 tolerance 是**绝对时长、单边**——
    /// **只会晚、不会早**。实测 `12 s + 容差 3 s` 实际睡 **14.87 s**；
    /// `200 ms + 容差 3 s` 跑 20 次，min 2.91 / avg 3.00 / max 3.10 s，无一次早醒。
    ///
    /// 所以**不存在「容差太大导致两次唤醒被攒成一次、观感跳片」这回事**
    /// （我第一版注释这么写过，是错的）。真实代价只是「同一张图最多停 ~15 s」，
    /// 一轮从 96 s 变成 96–120 s。
    ///
    /// ## 为什么取 3 s（= 间隔的 25%）
    ///
    /// Apple 的口径是 timer tolerance **至少取间隔 10%**，但那是下限不是上限。
    /// 这里取 25% 的理由：背景是 1.6 s 交叉淡入、且轮播纯粹是氛围，
    /// 「这张停 12 s 还是 15 s」用户分辨不出；而容差越大、系统把这次唤醒并进
    /// 别人的机会越多。若将来有人觉得停留上限太长，改成 1–1.2 s（10%）也完全合理。
    static let swapTolerance: Duration = .seconds(3)
    /// 氛围底图统一 800 宽小图 + 512px 解码——反正要糊掉，别为氛围图拉原画。
    static let imageWidth = 800
    /// 取池的随机查询条数。
    static let queryLimit = 24

    /// **可注入的等待**（`P2-36` 的测试接缝，与 `AmbienceImageWarmup.warm` 同款理由）。
    ///
    /// 换片循环里那次 `Task.sleep` 若不可注入，任何用例都**跑不到那一行**
    /// （要跑进去得先装好池、过 `reduceMotion` 闸、再等 12 秒）——
    /// 于是「tolerance 有没有真的传下去」永远守不住（审查实测：删掉 `tolerance:`
    /// 参数没有任何断言会红）。测试把它换成"立刻返回并记录参数"，即可断言。
    ///
    /// 生产实现就是带容差的 sleep 本身。
    static var sleepForSwap: @MainActor (Duration, Duration) async -> Void = { interval, tolerance in
        try? await Task.sleep(for: interval, tolerance: tolerance)
    }
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

    /// 池子是否就绪（非空 = 随机查询已返回、首图已预热，首页背景随时可显示）。
    /// 启动动画用它做交棒信号：池子没就绪就多等一拍，别让首页裸着见人。
    var ambiencePoolReady: Bool {
        !ambiencePool.isEmpty
    }

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
        // ## 为什么**不**按清单原建议「只在首页栈根可见时推进」
        //
        // `P2-36` 原文还建议「只在首页栈根可见时推进 index」。**这个建议不采纳**，
        // 但理由**不是**「页面背景会冻住」那种想当然的说法（我第一版就这么写错了，
        // 审查实测指出：`homeAmbience` 在生产里根本没有读方，那是个死属性，已删）。
        // 真实理由有两条，都读得到：
        //
        // **① iOS 上收益接近零。** 前台时恒有一个 Tab 可见，而那四个 Tab 根页
        // 各自的背景读的就是 `currentAmbienceTarget`。所以「只在首页可见才推进」
        // 在 iOS 上等于「几乎总是推进」，省不下什么；唯一能省的是「首页**栈根**
        // 可见」，可那恰恰会让**当前正在看的**设置子页 / 下载页 / 详情兜底背景停住。
        //
        // **② macOS 上会直接冻住整窗背景。** `AmbientBackdropCarousel` 挂在
        // `AppShell` 根节点的整窗层，任何分区都可见；按 `selectedSection == .home`
        // 门控会让 macOS 用户切到别的分区时全窗口背景静止 —— 那是明确的可见回退。
        //
        // 清单方案 (b)（让 `sessionPool` 读池内固定一张）也有真代价：
        // `Docs/AMBIENCE.md` §三.1 的「push 时背景连续」正是靠同 URL 命中缓存实现的。
        //
        // 真正可采纳的是清单的后半句 —— 给 `Task.sleep` 补 tolerance（见下）。
        while !Task.isCancelled {
            await AmbiencePool.sleepForSwap(
                AmbiencePool.swapInterval,
                AmbiencePool.swapTolerance
            )
            if Task.isCancelled { return }
            // 循环里再读一次：`reduceMotion` 由 AppShell 注入，可能与首次进入
            // 这条 task 同帧竞争，读早一拍就会在"减弱动态效果"下悄悄轮换起来。
            guard !reduceMotion else { return }
            ambienceIndex = (ambienceIndex + 1) % ambiencePool.count
            publishCurrentAmbience()
        }
    }

    /// 轮播推进一格后同步「当前这张」的声明。
    ///
    /// ⚠️ 这里原先还会写一个 `homeAmbience: WindowAmbience?` 属性 —— 那是**死属性**
    /// （生产零读点，已删除）。真正的传播路径是 `ambienceIndex` → `currentAmbienceTarget`，
    /// 由 `PageAmbience.sessionPool` / `DetailView.homeAmbienceTarget` /
    /// `AmbientBackdropCarousel` 读。
    ///
    /// 保留这个函数（而不是把它删掉）是因为**它是「推进后同步」这个动作的语义锚点**，
    /// 且已有用例通过它驱动（`AmbiencePoolTests` / `RouteAmbienceCoverageTests`）。
    /// 现在的实现是空操作 —— 但把「这里曾经有过一次发布」留在代码里比删干净更有用：
    /// 若将来真的要一个「当前氛围」快照属性，接线点就在这里。
    func publishCurrentAmbience() {
        // 无操作：见上面的说明。留着是为了保住调用点的语义与用例的驱动入口。
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
