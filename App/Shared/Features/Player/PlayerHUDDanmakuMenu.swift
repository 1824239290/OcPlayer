import ErikaKit
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
    let onMenuPresented: () -> Void

    private let opacities = [0.25, 0.5, 0.75, 1.0]
    private let displayAreas = [0.25, 0.5, 0.75, 1.0]

    var body: some View {
        Menu {
            Toggle("显示弹幕", isOn: Binding(
                get: { controller.danmakuEnabled },
                set: {
                    controller.setDanmakuEnabled($0)
                    onUserInteraction()
                }
            ))

            Text(app.danmaku.status.label)

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

            Menu("不透明度") {
                ForEach(opacities, id: \.self) { value in
                    Button {
                        controller.setDanmakuOpacity(value)
                        onUserInteraction()
                    } label: {
                        optionLabel(
                            "\(Int(value * 100))%",
                            selected: abs(controller.danmakuOpacity - value) < 0.001
                        )
                    }
                }
            }

            Menu("显示区域") {
                ForEach(displayAreas, id: \.self) { value in
                    Button {
                        controller.setDanmakuDisplayArea(value)
                        onUserInteraction()
                    } label: {
                        optionLabel(
                            "顶部 \(Int(value * 100))%",
                            selected: abs(controller.danmakuDisplayArea - value) < 0.001
                        )
                    }
                }
            }

            Menu("弹幕类型") {
                Toggle("滚动", isOn: Binding(
                    get: { !controller.danmakuBlockScroll },
                    set: { controller.setDanmakuBlocked(scroll: !$0) }
                ))
                Toggle("顶部", isOn: Binding(
                    get: { !controller.danmakuBlockTop },
                    set: { controller.setDanmakuBlocked(top: !$0) }
                ))
                Toggle("底部", isOn: Binding(
                    get: { !controller.danmakuBlockBottom },
                    set: { controller.setDanmakuBlocked(bottom: !$0) }
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
        .simultaneousGesture(TapGesture().onEnded { onMenuPresented() })
    }

    @ViewBuilder
    private func optionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var offsetLabel: String {
        let value = controller.danmakuGlobalOffsetSeconds
        if abs(value) < 0.001 { return "0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private var accessibilityValue: String {
        let enabled = controller.danmakuEnabled ? "已开启" : "已关闭"
        return "\(enabled)，\(app.danmaku.status.label)"
    }
}

