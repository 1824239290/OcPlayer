#if os(iOS)
import AVFAudio
import MediaPlayer
import Observation
import SwiftUI

@MainActor
@Observable
final class SystemVolumeState {
    var volume: Double

    init() {
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
    }
}

struct SystemVolumeControl: View {
    @Bindable var state: SystemVolumeState

    var body: some View {
        SystemVolumeControlRepresentable(volume: $state.volume)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SystemVolumeControlRepresentable: UIViewRepresentable {
    @Binding var volume: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(volume: $volume)
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.observeSystemVolume()
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        context.coordinator.volume = $volume
        guard let slider = Self.volumeSlider(in: view) else { return }

        // ## `P1-14`：先把目标**量化到硬件步长**，再比较
        //
        // `MPVolumeView` 的音量是 1/16 量化的（`volumeStep`），而拖动手势给的是
        // 连续 `0...1`。原先的守卫是「差 > 0.005 就写」，**0.005 远小于 1/16（0.0625）**
        // —— 于是几乎每个触摸事件都通过守卫、都 `setValue` + `sendActions(.valueChanged)`：
        // 一次 1 秒纵滑就是**数百次跨进程系统音量写入**，再经 KVO + 主 actor Task 回写。
        //
        // 量化后：同一档内的连续拖动**一次都不写**，只有跨档才写。写入次数从
        // O(事件数) 降到 O(跨越的档数)。
        //
        // 注意仍要**比较而不是直接写**：`updateUIView` 也会因其它状态变化被调用，
        // 目标与当前值同档时不该惊动系统。
        let raw = Float(min(max(volume, 0), 1))
        let target = PlayerPanGestureModel.quantizedVolume(raw)
        guard PlayerPanGestureModel.shouldWriteVolume(current: slider.value, target: target) else { return }
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    private static func volumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let slider = volumeSlider(in: child) { return slider }
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var volume: Binding<Double>
        private var observation: NSKeyValueObservation?

        init(volume: Binding<Double>) {
            self.volume = volume
        }

        func observeSystemVolume() {
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) {
                [weak self] session, _ in
                let value = Double(session.outputVolume)
                Task { @MainActor [weak self] in
                    self?.volume.wrappedValue = value
                }
            }
        }
    }
}
#endif
