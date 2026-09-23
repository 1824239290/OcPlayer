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
        let value = Float(min(max(volume, 0), 1))
        guard abs(slider.value - value) > 0.005 else { return }
        slider.setValue(value, animated: false)
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
