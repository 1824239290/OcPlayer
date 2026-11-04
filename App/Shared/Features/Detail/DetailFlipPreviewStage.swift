import CoreModel
import SwiftUI

#if os(iOS)
import UIKit
#endif

#if OCPLAYER_SELFTEST

/// **iPad 详情页翻页版式的验收台**（Debug-only）：用固定条目进入真实导航宿主。
///
/// ## 为什么需要它
///
/// 验收固定视口、先淡出再淡入的转场，以及正文顶部下拉返回封面。
///
/// 这本该在真机上用真实条目验，但正常入口进不去：`OCPLAYER_START_ROUTE=detail*`
/// 要求首页已经载入「带背景图」的条目（见 `AppModel+LaunchRoute.swift`），
/// **不接服务器首页就是空的**，一条都进不去。
///
/// 所以照 `MoviePilotCardPreviewStage` 那套成形做法给一条自检通道：用固定 fixture
/// 经 `AppShellView` 的 TabView / NavigationStack 渲染**同一个 `DetailView`**。
/// 详情模型仍会访问已配置的服务；fixture 的虚拟 ID 可能产生服务端错误，
/// 因此这条通道用于版式和手势验收，真实条目的加载与播放需走正常入口。
///
/// ## 用法
///
/// ```bash
/// # simctl launch 没有 --env，要用 SIMCTL_CHILD_ 前缀转发
/// SIMCTL_CHILD_OCPLAYER_DETAIL_FLIP=1 \
///   xcrun simctl launch 3C73634B-7D76-46EA-A9CB-7BA2D753E62E dev.jumusu.OcPlayer
/// xcrun simctl io 3C73634B-7D76-46EA-A9CB-7BA2D753E62E screenshot 00-page1.png
/// ```
///
/// `OCPLAYER_DETAIL_FLIP=2` 只渲染判定结果（不挂 `DetailView`），用来在不看画面的
/// 情况下核对档位——比如验证「iPad 分屏 = banner」时把窗口压窄再读这一屏。
/// `OCPLAYER_DETAIL_FLIP=3` 从固定卡片进入同一个详情页，用于验收缩放返回与内部翻页的手势竞争。
///
/// 整段只在 `OCPLAYER_SELFTEST`（Debug 配置定义）下存在，Release 构建里一个字都没有。
struct DetailFlipPreviewStage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @State private var gesturePath: [DetailTransitionSource] = []
    #endif

    /// 请求的档位：`nil` = 没请求。
    static var requestedMode: String? {
        let value = ProcessInfo.processInfo.environment["OCPLAYER_DETAIL_FLIP"]
        return (value?.isEmpty == false) ? value : nil
    }

    static var isRequested: Bool { requestedMode != nil }

    /// fixture 条目：**剧集**（选集带与季胶囊只在剧集页出现，那是第一页最重的部分）。
    ///
    /// 字段给全是有意的：标题 / 原名 / 简介 / 年份 / 时长 / 类型 / 评分 / 分级 / 集数
    /// 各自决定第一页左栏的一行，缺一条就少一行 —— 而「第一页是否正好一屏高」
    /// 正是要验的东西，不能靠残缺 fixture 蒙混过去。
    private var fixture: MediaItem {
        MediaItem(
            id: "preview-detail-flip",
            name: "药屋少女的呢喃",
            originalTitle: "薬屋のひとりごと",
            kind: .series,
            overview: """
                花街出身的药师少女猫猫被拐入后宫，凭药学知识破解宫中一桩桩悬案。
                这一行是为了把简介撑到多行——第一页左栏的高度直接决定下半部分的排版，
                而 fixture 只有一行简介时，观感会和真实条目差出一整段的高度。
                """,
            year: 2023,
            runtimeSeconds: 24 * 60,
            genres: ["动画", "古装", "悬疑"],
            communityRating: 8.6,
            officialRating: "TV-14",
            playState: MediaItem.PlayState(played: false, percentage: 0.25, positionSeconds: 360),
            childCount: 2
        )
    }

    var body: some View {
        Group {
            if Self.requestedMode == "2" {
                // 只显示判定结果：不挂详情页，方便核对档位。
                inspector
            } else {
                #if os(iOS)
                if Self.requestedMode == "3" {
                    zoomGestureFixture
                } else {
                    shellFixture
                }
                #else
                shellFixture
                #endif
            }
        }
        // 注入档位（`OCPLAYER_DETAIL_FLIP_HSCLASS=compact|regular`）。
        //
        // **`simctl` 控制不了窗口宽度/分屏**（只支持 appearance / contrast 之类），
        // 而 iPad 分屏验收要的正是「宽度变 compact」。所以这里注入环境值来验
        // **判定链路 + banner 渲染在 iPad 上是否正常**。
        //
        // 它能证明的与不能证明的，必须分开说：
        //   ✅ iPad 拿到 compact 时会渲染成 banner 版式（走对分支、不崩、布局正常）
        //   ❌ 真分屏时系统**确实会给** compact —— 那是系统契约，归判定表用例管
        // 真实拖拽分屏的观感只能人工验。
        .environment(\.horizontalSizeClass, injectedSizeClass ?? horizontalSizeClass)
    }

    private var shellFixture: some View {
        // 走真实 TabView + NavigationStack 宿主，才能复现安全区域留白。
        AppShellView()
            .task {
                app.selectedSection = .home
                #if os(iOS)
                app.setCompact(true)
                app.setNavPath([.detail(fixture)], for: .home)
                #else
                app.handleStackPathChange([.detail(fixture)])
                #endif
            }
    }

    #if os(iOS)
    private var zoomGestureFixture: some View {
        NavigationStack(path: $gesturePath) {
            DetailTransitionCard(list: "detail-gesture-fixture", position: fixture.id) { source in
                if let source { gesturePath.append(source) }
            } card: { action in
                Button(action: action) {
                    Text("打开缩放详情验收")
                        .font(.title2.bold())
                        .frame(width: 300, height: 200)
                        .foregroundStyle(.white)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("详情手势验收")
            .navigationDestination(for: DetailTransitionSource.self) { source in
                DetailView(item: fixture)
                    .detailZoomTransition(source: source)
                    .navigationTitle(fixture.name)
            }
        }
        .detailTransitionScope(section: .home)
    }
    #endif

    /// 注入的尺寸类；`nil` = 用真实值。
    private var injectedSizeClass: UserInterfaceSizeClass? {
        switch ProcessInfo.processInfo.environment["OCPLAYER_DETAIL_FLIP_HSCLASS"] {
        case "compact": .compact
        case "regular": .regular
        default: nil
        }
    }

    /// 档位读数：把判定输入与输出并排写出来。
    ///
    /// 之所以要把**输入**也打出来，是因为「结果是 banner」有两种可能：
    /// 判定对（compact）或者判定完全没跑起来（尺寸类读不到）。只打输出分不清这两者。
    private var inspector: some View {
        let style = DetailLayoutStyle.resolve(
            isPad: Self.isPadDevice,
            hSizeClass: effectiveSizeClass
        )
        return VStack(alignment: .leading, spacing: 16) {
            Text("详情页版式判定").font(.title2.bold())
            metric("设备", Self.isPadDevice ? "iPad" : "iPhone")
            metric("horizontalSizeClass",
                   effectiveSizeClass.map(String.init(describing:)) ?? "nil")
            if injectedSizeClass != nil {
                metric("注入覆盖", "是（真实值 \(horizontalSizeClass.map(String.init(describing:)) ?? "nil")）")
            }
            metric("判定结果", style == .flip ? ".flip（翻页版式）" : ".banner（横幅版式）")
            Text("真分屏只能人工拖：`simctl` 无法改变窗口宽度。这里验的是判定链路。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 判定实际用的尺寸类（注入优先）。
    private var effectiveSizeClass: UserInterfaceSizeClass? {
        injectedSizeClass ?? horizontalSizeClass
    }

    /// 当前是不是 iPad。与 `DetailView.isPadDevice` 同口径（macOS 恒 false）。
    private static var isPadDevice: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced().bold())
        }
        .font(.title3)
    }
}

#endif
