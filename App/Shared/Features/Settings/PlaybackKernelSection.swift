import PlaybackKit
import SwiftUI

/// 设置页的「播放内核」区。
///
/// 现在只注册了一个内核（Erika），所以显示成信息行；`PlaybackEngineAssembly`
/// 里多注册一个之后，这里**自动**变成选择器，不用改 UI。
///
/// 语义要点（footer 里也对用户讲了一遍）：
/// - 换内核和换弹幕渲染路线都在**下一次播放**生效——两者在
///   `PlaybackController.prepareEngine()` 里一起锁定，中途翻转会出双份弹幕 / 半挂的画面。
/// - 播放中改设置时，会显示「当前播放仍在用 X」，避免用户以为没生效。
/// - 所选内核不支持内核弹幕时，弹幕开关直接不出现（overlay 是唯一选择）。
struct PlaybackKernelSection: View {
    @Environment(PlaybackController.self) private var controller

    /// nil = 还没从注册表读过（`onAppear` 里补）。
    @State private var selectedKernelID: String?
    @State private var usesOverlayDanmaku = true

    private var available: [PlaybackEngineDescriptor] { PlaybackEngineRegistry.available }
    private var selected: PlaybackEngineDescriptor? {
        available.first { $0.id == selectedKernelID } ?? PlaybackEngineRegistry.selected
    }

    /// 正在播放的引擎和当前选择不是同一个（说明改了设置但还没换片）。
    private var pendingSwitch: PlaybackEngineDescriptor? {
        guard let active = controller.engine?.descriptor,
              let selected,
              active.id != selected.id
        else { return nil }
        return active
    }

    var body: some View {
        Section {
            if available.count > 1 {
                Picker("内核", selection: kernelBinding) {
                    ForEach(available) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
            } else if let selected {
                row("内核", selected.displayName)
            } else {
                // 装配点漏了才会走到这里；不静默，直接说出来。
                Label("没有可用的播放内核", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let selected {
                row("构成", selected.summary)
            }

            if PlaybackEngineRegistry.selectionIsStale,
               let storedID = PlaybackEngineRegistry.storedSelectionID,
               let selected {
                notice(
                    "上次选择的内核「\(storedID)」在这个版本里已不可用，已回退到 \(selected.displayName)。",
                    icon: "arrow.uturn.backward.circle.fill",
                    tint: .orange
                )
            }

            if let pendingSwitch, let selected {
                notice(
                    "当前播放仍在用 \(pendingSwitch.displayName)，"
                        + "下一次播放会切到 \(selected.displayName)。",
                    icon: "clock.arrow.circlepath",
                    tint: .blue
                )
            }

            // 内核自己没有弹幕渲染器时不给这个开关：那种情况下 overlay 是唯一选择，
            // 摆一个假开关比没有更糟。
            if selected?.supportsKernelDanmaku == true {
                Toggle("用内核渲染弹幕", isOn: overlayDanmakuBinding)
                Text(usesOverlayDanmaku
                     ? "当前用 App 层渲染（DanmakuRenderKit）。内核渲染的滑窗重排会让在屏弹幕跳轨，所以默认关。"
                     : "当前用内核内置渲染器。弹幕与视频、字幕在内核里合成，截图会带上弹幕。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notes = selected?.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("播放内核")
        } footer: {
            Text("内核与弹幕渲染方式在下一次播放时生效，正在播放的内容不受影响。")
        }
        .onAppear {
            selectedKernelID = PlaybackEngineRegistry.selected?.id
            usesOverlayDanmaku = PlaybackPreferences.danmakuUseOverlayRenderer
        }
    }

    private var kernelBinding: Binding<String> {
        Binding(
            get: { selectedKernelID ?? PlaybackEngineRegistry.selected?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                PlaybackEngineRegistry.select(newValue)
                selectedKernelID = newValue
            }
        )
    }

    /// UI 上是「用内核渲染弹幕」，存的是「用 overlay」——两者相反，这里翻一次。
    /// 正着存是历史原因（overlay 曾是影子模式的实验开关），改 key 会丢用户设置。
    private var overlayDanmakuBinding: Binding<Bool> {
        Binding(
            get: { !usesOverlayDanmaku },
            set: { useKernel in
                usesOverlayDanmaku = !useKernel
                PlaybackPreferences.danmakuUseOverlayRenderer = !useKernel
            }
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func notice(_ message: String, icon: String, tint: Color) -> some View {
        Label {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }
}
