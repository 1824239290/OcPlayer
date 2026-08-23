import PlaybackKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PlayerHUDDanmakuMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackController.self) private var controller

    @Binding var isSelectingDanmaku: Bool
    let controlSide: CGFloat
    let onUserInteraction: () -> Void

    private let opacities = [0.25, 0.5, 0.75, 1.0]
    private let displayAreas = [0.25, 0.5, 0.75, 1.0]
    private let fontSizes: [(String, Double)] = [
        ("小", 18),
        ("标准", 22),
        ("大", 26),
        ("特大", 30),
    ]

    var body: some View {
        Menu {
            Toggle("显示弹幕", isOn: Binding(
                get: { controller.danmakuEnabled },
                set: {
                    controller.setDanmakuEnabled($0)
                    onUserInteraction()
                }
            ))

            DanmakuStatusText()

            Divider()
            Button {
                isSelectingDanmaku = true
                onUserInteraction()
            } label: {
                Label("选择弹幕…", systemImage: "magnifyingglass")
            }
            Button {
                app.danmaku.retryAutomaticMatch()
                onUserInteraction()
            } label: {
                Label("重新自动匹配", systemImage: "arrow.clockwise")
            }

            if !controller.danmakuTracks.isEmpty {
                Divider()
                Menu {
                    Button("提前 0.5 秒", systemImage: "backward.end") {
                        controller.adjustDanmakuOffset(by: -0.5)
                        onUserInteraction()
                    }
                    Button("重置时间", systemImage: "arrow.counterclockwise") {
                        controller.resetDanmakuOffset()
                        onUserInteraction()
                    }
                    Button("延后 0.5 秒", systemImage: "forward.end") {
                        controller.adjustDanmakuOffset(by: 0.5)
                        onUserInteraction()
                    }
                } label: {
                    Label("时间偏移：\(offsetLabel)", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }

            Picker("不透明度", selection: Binding(
                get: { controller.danmakuOpacity },
                set: {
                    controller.setDanmakuOpacity($0)
                    onUserInteraction()
                }
            )) {
                ForEach(opacities, id: \.self) { value in
                    Text("\(Int(value * 100))%").tag(value)
                }
            }
            .pickerStyle(.inline)

            Picker("显示区域", selection: Binding(
                get: { controller.danmakuDisplayArea },
                set: {
                    controller.setDanmakuDisplayArea($0)
                    onUserInteraction()
                }
            )) {
                ForEach(displayAreas, id: \.self) { value in
                    Text("顶部 \(Int(value * 100))%").tag(value)
                }
            }
            .pickerStyle(.inline)

            Picker("字号大小", selection: Binding(
                get: { controller.danmakuFontSize },
                set: {
                    controller.setDanmakuFontSize($0)
                    onUserInteraction()
                }
            )) {
                ForEach(fontSizes, id: \.1) { item in
                    Text(item.0).tag(item.1)
                }
            }
            .pickerStyle(.inline)

            Menu("弹幕类型") {
                Toggle("滚动", isOn: Binding(
                    get: { !controller.danmakuBlockScroll },
                    set: {
                        controller.setDanmakuBlocked(scroll: !$0)
                        onUserInteraction()
                    }
                ))
                Toggle("顶部", isOn: Binding(
                    get: { !controller.danmakuBlockTop },
                    set: {
                        controller.setDanmakuBlocked(top: !$0)
                        onUserInteraction()
                    }
                ))
                Toggle("底部", isOn: Binding(
                    get: { !controller.danmakuBlockBottom },
                    set: {
                        controller.setDanmakuBlocked(bottom: !$0)
                        onUserInteraction()
                    }
                ))
            }

            Divider()
            Toggle("合并重复弹幕", isOn: Binding(
                get: { controller.danmakuMergeDuplicates },
                set: {
                    controller.setDanmakuMergeDuplicates($0)
                    onUserInteraction()
                }
            ))
            Toggle("允许堆叠", isOn: Binding(
                get: { controller.danmakuAllowStacking },
                set: {
                    controller.setDanmakuAllowStacking($0)
                    onUserInteraction()
                }
            ))
        } label: {
            PlayerHUDActionIcon(
                systemImage: "text.alignleft",
                side: controlSide,
                isActive: controller.danmakuEnabled
            )
        }
        .menuIndicator(.hidden)
        .modifier(PlayerHUDMenuStyle())
        .frame(width: controlSide, height: controlSide)
        .help("弹幕")
        .accessibilityLabel("弹幕")
        .accessibilityValue(accessibilityValue)
    }

    private var offsetLabel: String {
        let value = controller.danmakuGlobalOffsetSeconds
        if abs(value) < 0.001 { return "0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private var accessibilityValue: String {
        controller.danmakuEnabled ? "已开启" : "已关闭"
    }
}

/// 弹幕装载状态文案。拆成独立子视图，隔离 `DanmakuCoordinator.status` 的观察：
/// 播放开始后 status 会经历 idle→matching→loadingComments→loaded 一路变化，
/// 若在 Menu content 里直接读，会让整个菜单随 status 重算，嵌套子菜单（弹幕类型等）
/// 展开时被重建而闪烁。独立成叶子视图后，只有这一行文本随 status 刷新。
private struct DanmakuStatusText: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Text(app.danmaku.status.label)
    }
}

