import AVFoundation
import Foundation
@MainActor final class AudioHarness {
    enum State { case playing, paused }
    var state: State = .playing
    var resumeCount = 0
    let interruptions = PlaybackAudioInterruptions()
    func togglePlayPause() {
        interruptions.noteUserIntent()
        state = state == .playing ? .paused : .playing
    }
    var remotePause: () -> Void { { [weak self] in

                guard let self, self.state == .playing else { return }
                self.togglePlayPause()
            
    } }
    func begin() {
        interruptions.install(handlers: .init(
            isPlaying: { [weak self] in self?.state == .playing },
            pause: { [weak self] in self?.state = .paused },
            play: { [weak self] in self?.state = .playing; self?.resumeCount += 1 }))
        interruptions.start()
        post(type: .began)
    }
    func end() { post(type: .ended); interruptions.stop() }
    func post(type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
    }
}
@main struct Probe {
    @MainActor static func main() {
        let automatic = AudioHarness()
        automatic.begin(); automatic.end()
        print("automatic-resume-control: \(automatic.state == .playing && automatic.resumeCount == 1 ? "PASS" : "FAIL")")
        let intent = AudioHarness()
        intent.begin(); intent.interruptions.noteUserIntent(); intent.end()
        print("explicit-intent-control: \(intent.state == .paused && intent.resumeCount == 0 ? "PASS" : "FAIL")")
        let remote = AudioHarness()
        remote.begin(); remote.remotePause(); remote.end()
        print("remote-pause-during-interruption: expected paused,resumes=0; actual playing=\(remote.state == .playing), resumes=\(remote.resumeCount); \(remote.state == .paused && remote.resumeCount == 0 ? "PASS" : "FAIL")")
    }
}
