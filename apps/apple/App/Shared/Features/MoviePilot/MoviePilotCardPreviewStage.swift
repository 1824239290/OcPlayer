import AppDesignKit
import DiagnosticsKit
import MoviePilotKit
import SwiftUI

#if OCPLAYER_SELFTEST

/// 搜索结果卡的**验收台**（Debug-only）：把真实卡片按真实留白摆成搜索结果那一屏。
///
/// ## 为什么需要它
///
/// 卡片的问题只在「真机 + 真实液态玻璃 + 真实 Dynamic Type」下才看得准：
/// - `ImageRenderer` 对 `.glassEffect` 只画占位符（黄底红叉），量得出尺寸、看不出观感；
/// - 离屏窗口的 `drawHierarchy` / `layer.render(in:)` 拿不到 SwiftUI 的合成结果（只有底色）；
/// - 而 App 里的搜索结果要连一台真的 MoviePilot 服务器才出得来。
///
/// 所以给一条自检通道，像 `Scripts/verify-ambience.sh` 那样逐页截图：
///
/// ```bash
/// SIMCTL_CHILD_OCPLAYER_START_SECTION=moviepilot \
/// SIMCTL_CHILD_OCPLAYER_MOVIEPILOT_CARDS=1 \
///   xcrun simctl launch <udid> dev.jumusu.OcPlayer
/// xcrun simctl io <udid> screenshot card.png
/// ```
///
/// `simctl launch` **没有** `--env` 参数；环境变量要用 `SIMCTL_CHILD_` 前缀由 simctl
/// 转发给子进程（`xcodebuild test` 那边则是 `TEST_RUNNER_` 前缀）。
/// ```
///
/// 整段只在 `OCPLAYER_SELFTEST`（Debug 配置定义）下存在，Release 构建里一个字都没有。
struct MoviePilotCardPreviewStage: View {
    @Environment(AppModel.self) private var app

    /// 是否请求了这个验收台（环境变量门控）。
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["OCPLAYER_MOVIEPILOT_CARDS"] == "1"
    }

    /// 复刻截图里那几条结果的字段形态（三源聚合 + 已订阅 + 添加中）。
    private var fixtures: [MPMediaInfo] {
        [
            MPMediaInfo(raw: [
                "media_source": .string("tmdb"),
                "type": .string("电视剧"),
                "title": .string("药屋少女的呢喃"),
                "year": .string("2023"),
                "media_id": .string("tmdb:209867"),
                "vote_average": .number(8.7),
                "overview": .string("花街出身的药师少女猫猫被拐入后宫，凭药学知识破解宫中一桩桩悬案。"),
            ]),
            MPMediaInfo(raw: [
                "media_source": .string("bangumi"),
                "type": .string("动画"),
                "title": .string("药屋少女的呢喃"),
                "year": .string("2023"),
                "media_id": .string("bangumi:400602"),
                "vote_average": .number(8.1),
                "overview": .string("日本 / 动画 古装 / 长沼范裕 / 悠木碧 / 大塚刚央"),
            ]),
            MPMediaInfo(raw: [
                "media_source": .string("douban"),
                "type": .string("动画"),
                "title": .string("药屋少女的呢喃 第二季"),
                "year": .string("2025"),
                "media_id": .string("douban:35600000"),
                "vote_average": .number(7.9),
                "overview": .string("猫猫与壬氏的全新故事线，新作动画正式公开。"),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("媒体结果")
                        .font(.title3.weight(.bold))
                    PillChip("\(fixtures.count)", font: .footnote.weight(.semibold))
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.bottom, 2)

                ForEach(Array(fixtures.enumerated()), id: \.offset) { index, media in
                    MoviePilotMediaGlassCard(
                        media: media,
                        isSubscribed: index == 1,
                        isAdding: index == 2,
                        onQuickSubscribe: {},
                        onConfigureSubscribe: {},
                        onOpenResource: {}
                    )
                }

                Text("验收台 · 同一张卡在紧凑档 / 常规档的真实渲染；调 Dynamic Type 可看 ViewThatFits 降级")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Metrics.compactContentInset)
            .padding(.bottom, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
        // 与搜索结果页同一套氛围底（会话池那张），玻璃材质才有东西可折射。
        .pageAmbience(.sessionPool(app))
        .onAppear {
            AppDiagnostics.logInfo("自检：MoviePilot 结果卡验收台已进场（OCPLAYER_MOVIEPILOT_CARDS=1）")
        }
    }
}

#endif
