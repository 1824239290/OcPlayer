import AppDesignKit
import PlaybackKit
import SwiftUI

/// 设置页的「播放内核」区——现在只注册了一个内核（Erika），显示成一行信息；
/// `PlaybackEngineAssembly` 里多注册一个之后，这里**自动**变成选择器，不用改 UI。
///
/// 仅有的说明行是「改了选择但正在播放的还是旧内核」的下次播放生效提示；
/// 失效选择在装配点自愈清除，不再需要回退告警。
struct PlaybackKernelSection: View {
    @Environment(PlaybackController.self) private var controller

    /// nil = 还没从注册表读过（`onAppear` 里补）。
    @State private var selectedKernelID: String?

    private var available: [PlaybackEngineDescriptor] { PlaybackEngineRegistry.available }
    private var selected: PlaybackEngineDescriptor? {
        available.first { $0.id == selectedKernelID } ?? PlaybackEngineRegistry.selected
    }

    /// 内核标题 = 显示名 + 版本 tag（如「Erika v0.1.9+dolby.1」）；无版本的内核只显名字。
    private func title(_ descriptor: PlaybackEngineDescriptor) -> String {
        guard let version = descriptor.version else { return descriptor.displayName }
        return "\(descriptor.displayName) \(version)"
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
        Section("播放内核") {
            if available.count > 1 {
                Picker("内核", selection: kernelBinding) {
                    ForEach(available) { descriptor in
                        Text(title(descriptor)).tag(descriptor.id)
                    }
                }
            } else if let selected {
                KeyValueRow(label: "内核", value: title(selected))
            } else {
                // 装配点漏了才会走到这里；不静默，直接说出来。
                Label("没有可用的播放内核", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let pendingSwitch, let selected {
                notice(
                    "当前播放仍在用 \(pendingSwitch.displayName)，"
                        + "下一次播放会切到 \(selected.displayName)。",
                    icon: "clock.arrow.circlepath",
                    tint: .blue
                )
            }
        }
        .onAppear {
            selectedKernelID = PlaybackEngineRegistry.selected?.id
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
