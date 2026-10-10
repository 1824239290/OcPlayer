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

    /// 画质增强档位。与 `PlaybackPreferences` 同一 key，存 `PlaybackUpscalerMode.rawValue`；
    /// 坏值按「关闭」显示（与 `PlaybackPreferences` 的读取校验一致）。
    @AppStorage(SettingsKeys.lumaUpscaler)
    private var storedUpscaler = PlaybackUpscalerMode.off.rawValue
    private var upscaler: PlaybackUpscalerMode {
        PlaybackUpscalerMode(rawValue: storedUpscaler) ?? .off
    }

    private var upscalerBinding: Binding<PlaybackUpscalerMode> {
        Binding(
            get: { upscaler },
            set: { storedUpscaler = $0.rawValue }
        )
    }

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

            Picker("画质增强", selection: upscalerBinding) {
                ForEach(PlaybackUpscalerMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text("用神经网络对亮度做 2 倍重建（色度保持原生），低清动画与老片在大屏上更锐利。会增加 GPU 与显存占用；后端不支持时自动回落原生亮度采样。改动从下一次播放开始生效。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // 「开着却没变化」要能自证：内核在不支持的后端上会明确报 inactive。
            //
            // ⚠️ 加「已出过帧」这道闸是因为 **inactive 还有一个来源**：画面管线还没跑起来
            // （打开中、暂停在首帧之前）时它也会报 inactive。实测（本机 macOS / Metal）：
            // 挂上 surface 并 tick 之后三档都跑在 simdgroupMatrix 上、帧数在涨；而没挂
            // surface 时同一个档位读回来就是 inactive。少了这道闸，用户一进设置页就会
            // 看到一条假警告。
            if upscaler != .off,
               (controller.engine?.latestStats.renderedVideoFrames ?? 0) > 0,
               let state = controller.engine?.lumaUpscalerState,
               state.isFallingBackNatively {
                notice(
                    "当前内核后端不支持亮度上采样，画面已回落原生采样。",
                    icon: "exclamationmark.triangle.fill",
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
        }
        .settingsRowBackground()
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
