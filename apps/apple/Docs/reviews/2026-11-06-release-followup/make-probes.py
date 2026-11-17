"""Extract production paths into isolated harnesses; no product files are edited."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent

def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end], source[brace + 1:end - 1]

home = root / 'App/Shared/Features/MoviePilot/MoviePilotHomeView.swift'
player = root / 'App/Shared/Features/Player/PlaybackController.swift'
audio = root / 'App/Shared/Features/Player/PlaybackAudioInterruptions.swift'
h = home.read_text()
p = player.read_text()
load, _ = block(h, 'private func loadSubscribes()')
reset, _ = block(h, 'private func resetServerScopedState()')
_, task = block(h, '.task(id: moviepilot.boundServerID)')
_, pause = block(p[p.index('func installRemoteCommandHandlers()'):], 'pause: { [weak self] in')
pause = pause.split(' in', 1)[1]  # Capture list is supplied by the harness closure.

manifest = {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in (home, player, audio)}
(out / 'source-hashes.json').write_text(json.dumps(manifest, indent=2) + '\n')
(out / 'MoviePilotProbe.swift').write_text('''import Foundation
enum MoviePilotError: Error { case generic(String) }
@MainActor final class MoviePilotAPIClient {
    static let shared = MoviePilotAPIClient()
    var hold = false
    var server = "A"
    var calls: [String] = []
    var pending: CheckedContinuation<[Int], Error>?
    func subscribes() async throws -> [Int] {
        let original = server
        calls.append(original)
        let list: [Int]
        if hold {
            list = try await withCheckedThrowingContinuation { pending = $0 }
        } else { list = server == "A" ? [1] : [2] }
        try Task.checkCancellation()
        guard original == server else { throw CancellationError() }
        return list
    }
}
@MainActor final class BindingState { var boundServerID: String? = "A" }
@MainActor final class AppState { var pendingMoviePilotQuery: String? }
@MainActor final class HomeHarness {
    let moviepilot = BindingState()
    let app = AppState()
    var loadedForServerID: String?
    var subscribes: [Int] = []
    var isLoadingSubscribes = false
    var subscribesError: MoviePilotError?
    var searchTask: Task<Void, Never>?
    var searchGeneration = 0
    var subscribingMediaIDs: Set<Int> = []
    var localSubscribedMediaIDs: Set<Int> = []
    var results: [Int] = []
    var submittedKeyword = ""
    var keyword = ""
    var isSearching = false
    var searchError: String?
    var notice: String?
    var pendingDeleteSubscribe: Int?
    func consumePendingQuery(_ query: String?) {}
    func productionTabTask() async {''' + task + '''
    }
    func retry() async { await loadSubscribes() }
''' + load + '\n' + reset + '''
}
@main struct Probe {
    @MainActor static func main() async {
        let client = MoviePilotAPIClient.shared
        let home = HomeHarness()
        client.hold = true
        let old = Task { await home.productionTabTask() }
        while client.pending == nil { await Task.yield() }
        old.cancel() // SwiftUI task(id:) cancellation on A -> B.
        client.server = "B"
        home.moviepilot.boundServerID = "B"
        client.hold = false
        await home.productionTabTask()
        client.pending?.resume(returning: [1])
        client.pending = nil
        await old.value
        print("inflight-switch: expected list=[2], error=nil; actual list=\\(home.subscribes), error=\\(String(describing: home.subscribesError)), calls=\\(client.calls); \\(home.subscribes == [2] && home.subscribesError == nil ? "PASS" : "FAIL")")
        await home.retry()
        print("manual-retry-control: \\(home.subscribes == [2] ? "PASS" : "FAIL")")
        client.server = "A"
        let settled = HomeHarness()
        await settled.productionTabTask()
        client.server = "B"
        settled.moviepilot.boundServerID = "B"
        await settled.productionTabTask()
        print("settled-switch-control: \\(settled.subscribes == [2] && settled.subscribesError == nil ? "PASS" : "FAIL")")
    }
}
''')

(out / 'AudioCore.swift').write_text(audio.read_text().replace('import PlaybackKit\n', ''))
(out / 'AudioProbe.swift').write_text('''import AVFoundation
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
''' + pause.replace('self.state.state', 'self.state') + '''
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
        print("automatic-resume-control: \\(automatic.state == .playing && automatic.resumeCount == 1 ? "PASS" : "FAIL")")
        let intent = AudioHarness()
        intent.begin(); intent.interruptions.noteUserIntent(); intent.end()
        print("explicit-intent-control: \\(intent.state == .paused && intent.resumeCount == 0 ? "PASS" : "FAIL")")
        let remote = AudioHarness()
        remote.begin(); remote.remotePause(); remote.end()
        print("remote-pause-during-interruption: expected paused,resumes=0; actual playing=\\(remote.state == .playing), resumes=\\(remote.resumeCount); \\(remote.state == .paused && remote.resumeCount == 0 ? "PASS" : "FAIL")")
    }
}
''')
