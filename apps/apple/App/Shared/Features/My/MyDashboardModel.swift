import BangumiKit
import DiagnosticsKit
import Foundation
import JellyfinKit
import MoviePilotKit
import Observation

/// Each source publishes independently, retaining its last successful snapshot on refresh failure.
/// Scope and generation checks prevent a signed-out account or old server from publishing late data.
@MainActor
@Observable
final class MyDashboardSource<Value: Equatable & Sendable> {
    private(set) var value: Value?
    private(set) var scope: String?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation: UInt64 = 0

    func reset() {
        generation &+= 1
        value = nil
        scope = nil
        isLoading = false
        error = nil
    }

    func snapshot(for requestedScope: String?) -> Value? {
        guard let requestedScope, requestedScope == scope else { return nil }
        return value
    }

    func load(
        scope requestedScope: String?,
        currentScope: @MainActor () -> String?,
        fetch: @MainActor () async throws -> Value
    ) async {
        guard let requestedScope else { reset(); return }
        guard !Task.isCancelled, currentScope() == requestedScope else { return }
        if scope != requestedScope {
            reset()
            scope = requestedScope
        }
        guard !isLoading else { return }
        generation &+= 1
        let requestGeneration = generation
        isLoading = true
        error = nil
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let result = try await fetch()
            guard generation == requestGeneration, currentScope() == requestedScope,
                  !Task.isCancelled else { return }
            value = result
        } catch {
            guard generation == requestGeneration, currentScope() == requestedScope,
                  !Task.isCancelled, !CancellationClassifier.isCancellation(error) else { return }
            self.error = (error as? BangumiError)?.userMessage
                ?? (error as? MoviePilotError).map { MoviePilotError.userMessage(of: $0) }
                ?? error.localizedDescription
        }
    }

    #if OCPLAYER_SELFTEST
    func seed(_ value: Value, scope: String) {
        reset()
        self.scope = scope
        self.value = value
    }
    #endif
}

struct MyBangumiOverview: Equatable, Sendable {
    var counts: [BangumiCollectionType: Int] = [:]
    var watching: [BangumiProgressSubject] = []
    var wish: [BangumiSubjectDTO] = []
    var broadcastWatching: [BangumiSubjectDTO] = []

    @MainActor
    static func read(from context: BangumiContext) async throws -> Self {
        let counts = try await context.fetchCollectionCounts(subjectType: .anime)
        let watching = try await context.fetchProgressSubjects(
            tab: .anime, episodeWindowSize: 5, limit: 12)
        let wish = try await context.fetchCollectionSubjects(
            subjectType: .anime, collectionType: .wish, limit: 12)
        // The dashboard poster previews are bounded; broadcast filtering needs all doing subjects.
        var broadcastWatching: [BangumiSubjectDTO] = []
        while true {
            let page = try await context.fetchCollectionSubjects(
                subjectType: .anime, collectionType: .doing, limit: 100, offset: broadcastWatching.count)
            broadcastWatching += page
            if page.count < 100 { break }
            try Task.checkCancellation()
        }
        return Self(counts: counts, watching: watching.data, wish: wish, broadcastWatching: broadcastWatching)
    }
}

/// Resource acquisition and watched status stay separate. Only explicit IDs establish a link.
enum MyResourceLink {
    static func subscriptions(subjectID: Int, in items: [MPSubscribe]) -> [MPSubscribe] {
        items.filter { $0.bangumiId == subjectID }
    }

    static func summary(subjectID: Int, in items: [MPSubscribe]) -> String? {
        let matches = subscriptions(subjectID: subjectID, in: items)
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let item = matches.first else {
            return "已关联 \(matches.count) 个订阅"
        }
        return item.progressText ?? "已订阅 · \(item.stateText)"
    }

    static func missingEpisodes(in items: [MPSubscribe]) -> Int {
        items.reduce(0) { $0 + max($1.lackEpisode ?? 0, 0) }
    }
}

@MainActor
@Observable
final class MyDashboardModel {
    let bangumi = MyDashboardSource<MyBangumiOverview>()
    let calendar = MyDashboardSource<[MyBroadcastEntry]>()
    let subscriptions = MyDashboardSource<[MPSubscribe]>()
    let downloads = MyDashboardSource<[MPDownloadTask]>()
    let history = MyDashboardSource<ServerViewingHistory>()
    let localHistory = MyDashboardSource<[AppPlaybackRecord]>()

    var isLoading: Bool {
        bangumi.isLoading || calendar.isLoading || subscriptions.isLoading || downloads.isLoading || history.isLoading || localHistory.isLoading
    }
}
