import Foundation
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
    func productionTabTask() async {
            // iOS 上 tab 保活：换绑另一台 MP 服务器后本页 @State 不销毁，
            // 旧服务器的订阅/搜索残留。绑定标识变化（登出后重绑、换一台）即整体作废；
            // 回到同一台服务器则保留数据，避免每次切回 tab 都重拉。
            if loadedForServerID != moviepilot.boundServerID {
                resetServerScopedState()
                loadedForServerID = moviepilot.boundServerID
            }
            // Bangumi / Jellyfin 详情页「在 MoviePilot 找资源」带过来的搜索词。
            consumePendingQuery(app.pendingMoviePilotQuery)
            if subscribes.isEmpty {
                await loadSubscribes()
            }
        
    }
    func retry() async { await loadSubscribes() }
private func loadSubscribes() async {
        guard !isLoadingSubscribes else { return }
        isLoadingSubscribes = true
        subscribesError = nil
        do {
            let list = try await MoviePilotAPIClient.shared.subscribes()
            subscribes = list
        } catch {
            subscribesError = (error as? MoviePilotError) ?? .generic("\(error)")
        }
        isLoadingSubscribes = false
    }
private func resetServerScopedState() {
        searchTask?.cancel()
        searchGeneration += 1
        subscribes = []
        subscribingMediaIDs = []
        localSubscribedMediaIDs = []
        results = []
        submittedKeyword = ""
        keyword = ""
        isSearching = false
        searchError = nil
        subscribesError = nil
        notice = nil
        pendingDeleteSubscribe = nil
    }
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
        print("inflight-switch: expected list=[2], error=nil; actual list=\(home.subscribes), error=\(String(describing: home.subscribesError)), calls=\(client.calls); \(home.subscribes == [2] && home.subscribesError == nil ? "PASS" : "FAIL")")
        await home.retry()
        print("manual-retry-control: \(home.subscribes == [2] ? "PASS" : "FAIL")")
        client.server = "A"
        let settled = HomeHarness()
        await settled.productionTabTask()
        client.server = "B"
        settled.moviepilot.boundServerID = "B"
        await settled.productionTabTask()
        print("settled-switch-control: \(settled.subscribes == [2] && settled.subscribesError == nil ? "PASS" : "FAIL")")
    }
}
