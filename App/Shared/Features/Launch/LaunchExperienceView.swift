import AppDesignKit
import SwiftUI

// MARK: - 启动体验（冷启动第一秒）

/// 启动动画层：底色 + 光晕 + 标志（描边层 → 填充层交叉）→ 交棒淡出。
///
/// 分镜与缓动全部在 `LaunchTimeline`（纯数学，逐帧可测）；本视图只负责
/// 「按帧状态渲染」。驱动按平台分两条：iOS 用 `TimelineView(.animation)`；
/// macOS 覆盖窗口不是 key window，`TimelineView` 在那里不会推进（只出首帧），
/// 因此改用 RunLoop 定时器。两边的帧状态都来自同一个 `evaluate`。
///
/// 渲染成本：所有 `Path` 都是 `OcMark` 的静态预构建值，每帧只改
/// trim / opacity / scale，没有逐帧几何重建。
struct LaunchExperienceView: View {
    let presenter: LaunchPresenter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            #if os(macOS)
            // macOS 的启动层挂在独立覆盖窗口里：`TimelineView(.animation)` 在这种
            // 非 key 的子窗口里**只渲染首帧、不驱动后续帧**（实测：整段只剩底色，
            // 收尾时主窗口直接闪出）。这里改用 RunLoop 定时器自驱，窗口是否 key
            // 都不影响；iOS 仍用 TimelineView。
            MacLaunchTicker(presenter: presenter, colorScheme: colorScheme)
            #else
            TimelineView(.animation) { context in
                let frame = timeline.evaluate(
                    elapsed: presenter.elapsed(at: context.date),
                    readyAt: presenter.readyAtMs,
                    ambienceReadyAt: presenter.ambienceReadyAtMs,
                    homeReadyAt: presenter.homeReadyAtMs,
                    holdForAmbience: presenter.holdForAmbience,
                    holdForHome: presenter.holdForHome,
                    reduceMotion: presenter.reduceMotion)
                LaunchLayer(frame: frame, colorScheme: colorScheme)
            }
            #endif
        }
        // 启动层纯展示：底下 bootstrap 照常跑，永远不拦点击。
        .allowsHitTesting(false)
        // <1s 的装饰层，VoiceOver 直接略过；内容出现后自然获得焦点。
        .accessibilityHidden(true)
    }

    private let timeline = LaunchTimeline()
}

#if os(macOS)
/// 定时器驱动的启动层（macOS）。60Hz 足够：启动层只改 trim / opacity / scale，
/// 每帧成本就是一次纯数学求值 + 一次 SwiftUI diff。
private struct MacLaunchTicker: View {
    let presenter: LaunchPresenter
    let colorScheme: ColorScheme

    @State private var now = Date.now
    // 存在结构体属性上意味着父级（LaunchExperienceView.body）每次求值都会生成
    // 一个新 timer：旧值随旧结构体丢弃、订阅被 onReceive 换到新值上，旧的随之
    // 失效——无泄漏，但会重排一拍。当前父级只依赖 colorScheme 与 presenter
    // 引用、几乎不求值，可以这么写；若日后给它加了会变化的依赖，把 timer 挪进
    // onAppear 里显式管理。
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let timeline = LaunchTimeline()

    var body: some View {
        var frame = timeline.evaluate(
            elapsed: presenter.elapsed(at: now),
            readyAt: presenter.readyAtMs,
            ambienceReadyAt: presenter.ambienceReadyAtMs,
            homeReadyAt: presenter.homeReadyAtMs,
            holdForAmbience: presenter.holdForAmbience,
            holdForHome: presenter.holdForHome,
            reduceMotion: presenter.reduceMotion)
        // 整层淡出交给**窗口 alpha**（LaunchOverlayWindow.beginHandoff）：主线程在
        // deadline 前后正忙着装配首页，SwiftUI 按 elapsed 把自己淡成 0 之后，如果
        // 撤窗任务被堵住，覆盖窗口就只剩一块平色底晃半拍再跳首页（实机看到的
        // 「闪一下」）。窗口 alpha 由窗口服务器执行，主线程堵不堵都照常淡。
        frame.overlayOpacity = 1
        return LaunchLayer(frame: frame, colorScheme: colorScheme)
            .onReceive(timer) { now = $0 }
    }
}
#endif

// MARK: - 底色（启动层与 .boot 占位共用）

/// 启动底色 = 登录墙底色 + 中心提亮。**系统启动屏（iOS `LaunchBackground`）、
/// `.boot` 占位、启动动画层三处同一块底**，首帧与交棒全程无跳色。
struct LaunchBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LaunchStyle.backdrop(for: colorScheme)
                RadialGradient(
                    colors: [LaunchStyle.backdropLift(for: colorScheme), LaunchStyle.backdropLift(for: colorScheme).opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.75
                )
            }
        }
    }
}

// MARK: - 启动层

private struct LaunchLayer: View {
    let frame: LaunchTimeline.Frame
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LaunchBackdrop()
                glow(width: geo.size.width)
                    .opacity(frame.glowOpacity)
                MarkCanvas(frame: frame, colorScheme: colorScheme, containerSize: geo.size)
                    .scaleEffect(frame.markScale)
            }
            // 交棒：整层淡出，露出底下的内容（此时 phase 已切走）。
            .opacity(frame.overlayOpacity)
        }
    }

    /// 中心光晕：预览同款的径向渐变（0.62 → 0.22 → 透明），直径随容器宽。
    private func glow(width: CGFloat) -> some View {
        let diameter = width * 0.66
        let endRadius = diameter * 0.5 / 0.7
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: LaunchStyle.glow.opacity(0.62), location: 0),
                        .init(color: LaunchStyle.glow.opacity(0.22), location: 0.38),
                        .init(color: LaunchStyle.glow.opacity(0), location: 0.7),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: endRadius
                )
            )
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - 标志画布

/// 标志的渲染画布。内部是 1024×1024 的描摹坐标系，整体视觉缩放到目标尺寸
/// （`.scaleEffect` 是纯视觉变换，布局用外层 frame 钉住）——这样所有 `Path`
/// 保持单位坐标，渐变 span 与描边宽度直接用描摹值。
private struct MarkCanvas: View {
    let frame: LaunchTimeline.Frame
    let colorScheme: ColorScheme
    let containerSize: CGSize

    var body: some View {
        let side = markSide
        return ZStack {
            strokeLayer
            fillLayer
        }
        .frame(width: OcMark.canvasSize, height: OcMark.canvasSize)
        // scaleEffect 是纯视觉变换（布局仍是 1024）：末尾的扩张 frame 把整条链
        // 撑满容器并把「画布中心」钉在容器中心，缩放后的标志才真正居中。
        .scaleEffect(side / OcMark.canvasSize)
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(frame.markOpacity)
    }

    /// 标志可见宽度口径：iPhone 约屏宽一半、Mac 约窗宽三分之一，各封顶。
    /// 内容外接框只占画布的 860/1024，画布边长据此反推。
    private var markSide: CGFloat {
        let visibleWidth: CGFloat
        #if os(macOS)
        visibleWidth = min(containerSize.width * 0.32, 240)
        #else
        visibleWidth = min(containerSize.width * 0.5, 200)
        #endif
        return visibleWidth * OcMark.canvasSize / OcMark.contentBBox.width
    }

    private var markGradient: LinearGradient {
        LinearGradient(
            colors: [LaunchStyle.markTop(for: colorScheme), LaunchStyle.markBottom(for: colorScheme)],
            startPoint: UnitPoint(x: 0.5, y: LaunchStyle.markGradientTopY / OcMark.canvasSize),
            endPoint: UnitPoint(x: 0.5, y: LaunchStyle.markGradientBottomY / OcMark.canvasSize)
        )
    }

    /// 描边层：头一笔 + 四根胡须，trim 从颊侧/下颌起笔。
    private var strokeLayer: some View {
        ZStack {
            OcMark.headCenterlinePath
                .trim(from: 0, to: frame.headProgress)
                .stroke(
                    markGradient,
                    style: StrokeStyle(lineWidth: OcMark.headStrokeWidth, lineCap: .round, lineJoin: .round)
                )
                .opacity(frame.headStrokeOpacity)
            ForEach(0..<4, id: \.self) { index in
                OcMark.whiskerCenterlinePaths[index]
                    .trim(from: 0, to: frame.whiskerProgress[index])
                    .stroke(
                        markGradient,
                        style: StrokeStyle(lineWidth: OcMark.whiskerStrokeWidth, lineCap: .round, lineJoin: .round)
                    )
                    .opacity(frame.whiskerStrokeOpacity[index])
            }
        }
    }

    /// 填充层：1:1 本体。头部是「外圈 + 脸洞」，必须 **evenodd**。
    private var fillLayer: some View {
        ZStack {
            OcMark.headFillPath
                .fill(markGradient, style: FillStyle(eoFill: true))
                .opacity(frame.headFillOpacity)
            ForEach(0..<4, id: \.self) { index in
                OcMark.whiskerFillPaths[index]
                    .fill(markGradient)
                    .opacity(frame.whiskerFillOpacity[index])
            }
            OcMark.triangleFillPath
                .fill(markGradient)
                .opacity(frame.triangleOpacity)
                .scaleEffect(
                    frame.triangleScale,
                    anchor: UnitPoint(
                        x: OcMark.triangleAnchor.x / OcMark.canvasSize,
                        y: OcMark.triangleAnchor.y / OcMark.canvasSize
                    )
                )
        }
    }
}
