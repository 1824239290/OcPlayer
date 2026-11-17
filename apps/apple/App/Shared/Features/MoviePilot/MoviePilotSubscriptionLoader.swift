import DiagnosticsKit
import MoviePilotKit
import Observation

/// Owns subscription request state across retained tabs and server changes.
@MainActor
@Observable
final class MoviePilotSubscriptionLoader {
    var items: [MPSubscribe] = []
    private(set) var isLoading = false
    private(set) var error: MoviePilotError?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var configurationRevision: UInt64?

    func reset() {
        generation &+= 1
        configurationRevision = nil
        items = []
        error = nil
        isLoading = false
    }

    func load(
        revision: UInt64,
        currentRevision: @MainActor () -> UInt64,
        fetch: @MainActor () async throws -> [MPSubscribe]
    ) async {
        guard !Task.isCancelled, currentRevision() == revision else { return }
        if configurationRevision != revision {
            reset()
            configurationRevision = revision
        }
        guard !isLoading else { return }
        generation &+= 1
        let requestGeneration = generation
        isLoading = true
        error = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }
        do {
            let list = try await fetch()
            guard generation == requestGeneration,
                  currentRevision() == revision, !Task.isCancelled else { return }
            items = list
        } catch {
            guard generation == requestGeneration,
                  currentRevision() == revision, !Task.isCancelled,
                  !CancellationClassifier.isCancellation(error) else { return }
            self.error = (error as? MoviePilotError) ?? .generic("\(error)")
        }
    }
}
