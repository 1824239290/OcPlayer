import Foundation

/// 启动编排的**纯数学**：给定时刻，返回该时刻每一层的精确状态。
///
/// 分镜（毫秒，与方案预览逐帧同一套常量与缓动）：
/// `0` 底色就位 → `80–700` 一笔描出猫头轮廓 → `470–740` 播放三角弹入（spring）
/// → `610–850` 四根胡须依次补笔 → `900` 落定；启动数据未就绪就**呼吸等待**（幅度
/// 1.2%，不是转圈）；数据就绪后**交棒**——标志先淡出（150ms）并轻微放大，启动层
/// 整体再淡出（260ms）露出底下的内容。
///
/// 设计约束（与 `App/Shared/Features/Launch/` 的实现共同遵守）：
/// * **动画与 bootstrap 并行，不垫时长**：就绪早于落定也要等满 `minVisible`
///   （快速机器上冷启动 ≈0.9s，这个下限基本免费）；就绪晚于落定才进入呼吸等待。
/// * **每段画完就地交叉淡入 1:1 填充形**（描边 → 填充，`OcMark` 文档头）：
///   终帧恒为描摹本体，描边只是过程。
/// * 纯函数、无 UI 依赖：`LaunchTimelineTests` 逐帧钉住，改分镜先跑它。
struct LaunchTimeline: Sendable {
    // MARK: - 分镜常量（毫秒）

    static let drawStart: Double = 80
    static let drawEnd: Double = 700
    static let triangleStart: Double = 470
    static let triangleEnd: Double = 740
    /// 四根胡须的描边窗口（左上 / 左下 / 右上 / 右下，依次错 30ms）。
    static let whiskerWindows: [(start: Double, end: Double)] =
        [(610, 760), (640, 790), (670, 820), (700, 850)]
    /// 落定时刻（描边+填充全部完成），也是动画路径的退场下限。
    static let settle: Double = 900
    /// 交棒时长：标志淡出 150ms 后，启动层整体再淡出 260ms。
    static let exitDuration: Double = 260
    /// 数据就绪到开始退场的缓冲（就绪那一帧主线程还有装配活，缓一拍再退）。
    static let readyGrace: Double = 120
    /// 内容就绪早于落定也要等满的最低展示；减弱动态用短得多的下限。
    static func minVisible(reduceMotion: Bool) -> Double {
        reduceMotion ? 600 : settle
    }
    /// 氛围池就绪到退场的缓冲（池子非空 = 首图已预热，再给背景一拍淡入）。
    /// 首页内容就绪沿用同一拍。
    static let ambienceGrace: Double = 120
    /// 交棒门控迟迟不就绪时的**等待上限**（超出就照常退场，宁可短暂素底也不吊着）。
    /// 实测池子装载 ≈2.3s（随机查询 + 首图预热两次网络往返），900 + 1600 = 2.5s 恰好盖住；
    /// 离线 / 库里没有 backdrop 的用户最多多等这一截。首页内容（磁盘缓存 / 网络
    /// 三条 rail）通常更快，与氛围池**共享**这一个上限，不叠加。
    static let ambienceHoldCap: Double = 1600

    // MARK: - 退场判定

    /// 退场开始时刻。数据未就绪 → nil（无限呼吸等待，永不超时自动退）。
    /// 就绪晚于下限时加一拍 `readyGrace`，就绪早于（等于）下限时按下限退。
    ///
    /// 交棒门控（`holdForAmbience` / `holdForHome` = 有会话、预期首页会有对应的
    /// 东西）：**背景没穿好衣服、首页还在骨架期，都不交棒**。信号一到就提前到
    /// 「就绪 + 一拍」；哪个门控还没到，退场就抬到 `下限 + ambienceHoldCap` 封顶
    /// （多个门控共享一个上限，不叠加）——离线 / 空库 / 没有 backdrop 图库的
    /// 用户不陪着吊。等不等于卡——等待期标志在呼吸。
    func exitStart(readyAt: Double?, ambienceReadyAt: Double? = nil, homeReadyAt: Double? = nil, holdForAmbience: Bool = false, holdForHome: Bool = false, reduceMotion: Bool = false) -> Double? {
        guard let readyAt else { return nil }
        let floor = Self.minVisible(reduceMotion: reduceMotion)
        var start = max(floor, readyAt + (readyAt > floor ? Self.readyGrace : 0))
        var waitingOnHold = false
        if holdForAmbience {
            if let ambienceReadyAt {
                start = max(start, ambienceReadyAt + Self.ambienceGrace)
            } else {
                waitingOnHold = true
            }
        }
        if holdForHome {
            if let homeReadyAt {
                start = max(start, homeReadyAt + Self.ambienceGrace)
            } else {
                waitingOnHold = true
            }
        }
        if waitingOnHold {
            start = max(start, floor + Self.ambienceHoldCap)
        }
        return start
    }

    // MARK: - 单帧状态

    struct Frame: Equatable {
        /// 描边进度（0…1）：头部轮廓 / 四根胡须。
        var headProgress: Double = 0
        var whiskerProgress: [Double] = [0, 0, 0, 0]
        /// 描边层透明度（落笔前不可见——圆头端帽在 trim=0 时仍会画一个起点圆点；
        /// 画完后随填充形淡出）。
        var headStrokeOpacity: Double = 0
        var whiskerStrokeOpacity: [Double] = [0, 0, 0, 0]
        /// 填充形透明度（每段画完就地交叉淡入 1:1 本体）。
        var headFillOpacity: Double = 0
        var whiskerFillOpacity: [Double] = [0, 0, 0, 0]
        /// 播放三角（scale 从 0.55 弹到 1，带过冲）。
        var triangleScale: Double = 0.55
        var triangleOpacity: Double = 0
        /// 中心光晕。
        var glowOpacity: Double = 0
        /// 标志整组：减弱动态的淡入 × 交棒淡出。
        var markOpacity: Double = 1
        /// 标志整组缩放：呼吸等待 × 交棒放大。
        var markScale: Double = 1
        /// 启动层整体（底色 + 标志）透明度 = 交棒。
        var overlayOpacity: Double = 1
        /// 交棒完成 → 撤除启动层。
        var isFinished: Bool = false
    }

    /// - Parameters:
    ///   - elapsed: 自启动动画起点（首帧）的毫秒数。
    ///   - readyAt: 启动数据就绪的时刻（同口径毫秒）；nil = 仍在等（呼吸等待）。
    ///   - ambienceReadyAt / homeReadyAt: 氛围池 / 首页内容就绪时刻；nil = 还在等。
    ///   - reduceMotion: 减弱动态 → 静态标志 + 淡入淡出，无描边 / 呼吸 / 光晕脉冲。
    func evaluate(elapsed: Double, readyAt: Double?, ambienceReadyAt: Double? = nil, homeReadyAt: Double? = nil, holdForAmbience: Bool = false, holdForHome: Bool = false, reduceMotion: Bool) -> Frame {
        var frame = Frame()
        let exitStart = exitStart(
            readyAt: readyAt,
            ambienceReadyAt: ambienceReadyAt,
            homeReadyAt: homeReadyAt,
            holdForAmbience: holdForAmbience,
            holdForHome: holdForHome,
            reduceMotion: reduceMotion)
        let exitProgress = exitStart.map { easeInOut(segment(elapsed, $0, $0 + Self.exitDuration)) } ?? 0
        frame.overlayOpacity = 1 - exitProgress
        frame.isFinished = exitProgress >= 1
        // 标志在退场时轻微放大（zoom-through），并整组淡出。
        let markExit = 1 - easeOut(segment(elapsed, exitStart ?? .infinity, (exitStart ?? .infinity) + 150))

        if reduceMotion {
            // 静态标志：无描边 / 无呼吸 / 光晕定常；整组 180ms 淡入。
            frame.headFillOpacity = 1
            frame.whiskerFillOpacity = [1, 1, 1, 1]
            frame.triangleScale = 1
            frame.triangleOpacity = 1
            frame.glowOpacity = 0.3
            frame.markOpacity = easeOut(segment(elapsed, 0, 180)) * markExit
            frame.markScale = 1
            return frame
        }

        // 描边：头部一笔（下颌起笔朝左），四根胡须依次补笔；落笔前不可见。
        frame.headProgress = easeInOut(segment(elapsed, Self.drawStart, Self.drawEnd))
        frame.headStrokeOpacity =
            segment(elapsed, Self.drawStart - 20, Self.drawStart + 40)
            * (1 - segment(elapsed, Self.drawEnd + 80, Self.drawEnd + 230))
        for (index, window) in Self.whiskerWindows.enumerated() {
            frame.whiskerProgress[index] = easeOut(segment(elapsed, window.start, window.end))
            frame.whiskerStrokeOpacity[index] =
                segment(elapsed, window.start - 20, window.start + 40)
                * (1 - segment(elapsed, window.end + 80, window.end + 230))
            // 每段画完就地交叉淡入填充形（与该段描边重叠 100ms，同色无感）。
            frame.whiskerFillOpacity[index] = segment(elapsed, window.end - 40, window.end + 60)
        }
        frame.headFillOpacity = segment(elapsed, Self.drawEnd - 40, Self.drawEnd + 60)

        // 播放三角：spring 弹入（0.55 → 1 带过冲），光晕同步起。
        let triangleProgress = segment(elapsed, Self.triangleStart, Self.triangleEnd)
        frame.triangleScale = 0.55 + 0.45 * easeOutBack(triangleProgress)
        frame.triangleOpacity = segment(elapsed, Self.triangleStart, Self.triangleStart + 140)
        var glow = 0.52
            * easeOut(segment(elapsed, 300, 780))
            * (1 - 0.30 * easeInOut(segment(elapsed, 700, Self.settle)))
        if let exitStart, elapsed > Self.settle, elapsed < exitStart {
            // 呼吸等待期：光晕慢脉冲（2.4s 一轮），退场时随呼吸一起收。
            glow *= 0.76 + 0.16 * sin((elapsed - Self.settle) / 1800 * 2 * .pi)
        }
        frame.glowOpacity = glow

        // 呼吸等待（仅落定后、退场前）：幅度 1.2%、2.6s 一轮；退场时幅度归零衔接放大。
        var breathe = 1.0
        if elapsed > Self.settle {
            let idleAmplitude = exitStart.map { 1 - segment(elapsed, $0, $0 + 150) } ?? 1
            breathe = 1 + 0.012 * idleAmplitude * sin((elapsed - Self.settle) / 2600 * 2 * .pi)
        }
        frame.markScale = breathe * (1 + 0.05 * exitProgress)
        frame.markOpacity = markExit
        return frame
    }

    // MARK: - 缓动（与预览同一套）

    private func segment(_ value: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(1, max(0, (value - start) / (end - start)))
    }

    private func easeInOut(_ p: Double) -> Double {
        p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    private func easeOut(_ p: Double) -> Double {
        1 - pow(1 - p, 3)
    }

    /// 轻过冲弹入（c1 = 1.35，与预览一致）。
    private func easeOutBack(_ p: Double) -> Double {
        let c1 = 1.35
        let c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
