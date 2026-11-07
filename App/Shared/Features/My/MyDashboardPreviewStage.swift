#if OCPLAYER_SELFTEST
import BangumiKit
import CoreModel
import JellyfinKit
import MoviePilotKit
import SwiftUI

/// Offline fixture preview hosted by the same shell and page as production.
/// No account API or playback statistics are populated by this entry point.
struct MyDashboardPreviewStage: View {
    @Environment(AppModel.self) private var app

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["OCPLAYER_MY_DASHBOARD_PREVIEW"] == "1"
    }

    var body: some View {
        AppShellView()
            .preferredColorScheme(.dark)
            .onAppear {
                app.selectedSection = .my
                app.phase = .ready
            }
    }

    @MainActor
    static func makeModel() -> MyDashboardModel {
        let model = MyDashboardModel()
        let frieren = BangumiSubjectDTO(
            id: 400602, eps: 28,
            images: .init(large: "https://lain.bgm.tv/pic/cover/l/13/c5/400602_ZI8Y9.jpg"),
            nameCN: "葬送的芙莉莲", type: .anime,
            interest: .init(comment: "", epStatus: 8, volStatus: 0, private: false, rate: 0,
                            tags: [], type: .doing, updatedAt: 0))
        let makeine = BangumiSubjectDTO(
            id: 464376, eps: 12,
            images: .init(large: "https://lain.bgm.tv/pic/cover/l/e4/dc/464376_NsZRw.jpg"),
            nameCN: "败犬女主太多了！", type: .anime,
            interest: .init(comment: "", epStatus: 3, volStatus: 0, private: false, rate: 0,
                            tags: [], type: .doing, updatedAt: 0))
        model.bangumi.seed(.init(
            counts: [.wish: 6, .doing: 2, .collect: 17],
            watching: [frieren, makeine].map { .init(subject: $0, episodes: []) },
            wish: [BangumiSubjectDTO(id: 99, eps: 12, images: makeine.images, nameCN: "下一部想看的动画", type: .anime)],
            broadcastWatching: [frieren, makeine]
        ), scope: "preview")
        let today = Calendar.current.startOfDay(for: Date())
        let weekday = (Calendar.current.component(.weekday, from: today) + 5) % 7 + 1
        let formatter = ISO8601DateFormatter()
        model.calendar.seed([frieren, makeine].enumerated().map { index, subject in
            let anchor = Calendar.current.date(byAdding: .hour, value: 20 + index, to: today)!
            return MyBroadcastEntry(subject: subject, mediaID: "preview-media-\(subject.id)", weekday: weekday,
                                    schedule: MyBroadcastSchedule("R/\(formatter.string(from: anchor))/P7D", end: nil))
        }, scope: "preview")
        model.subscriptions.seed([
            MPSubscribe(raw: ["id": .number(1), "bangumiid": .number(400602), "name": .string(frieren.nameCN),
                              "season": .number(1), "total_episode": .number(28), "lack_episode": .number(4),
                              "state": .string("R"), "poster": .string(frieren.images!.large)]),
            MPSubscribe(raw: ["id": .number(2), "bangumiid": .number(464376), "name": .string(makeine.nameCN),
                              "season": .number(1), "total_episode": .number(12), "lack_episode": .number(0),
                              "state": .string("O"), "poster": .string(makeine.images!.large)])
        ], scope: "preview")
        model.downloads.seed([
            MPDownloadTask(raw: ["hash": .string("preview-download"), "title": .string("葬送的芙莉莲 · 第 9 集"),
                                 "progress": .number(64), "state": .string("下载中"),
                                 "dlspeed": .string("12.3 MB/s"), "left_time": .string("约 2 分钟")])
        ], scope: "preview")
        let calendar = Calendar.current
        let records = (0..<24).map { index in
            let movie = index == 5
            let day = calendar.date(byAdding: .day, value: -(index % 22), to: today)!
            let date = calendar.date(byAdding: .hour, value: 20, to: day)!
            return ServerViewingRecord(item: MediaItem(
                id: "preview-history-\(index)", name: movie ? "示例电影" : "第 \(index + 1) 集",
                kind: movie ? .movie : .episode, runtimeSeconds: movie ? 7200 : 1440,
                genres: movie ? ["剧情"] : ["动画", "喜剧"], seriesName: movie ? nil : frieren.nameCN,
                playState: .init(played: true, percentage: 1, positionSeconds: 0)), watchedAt: date)
        }
        model.history.seed(ServerViewingHistory(
            sourceID: "preview", recordedFrom: calendar.date(byAdding: .day, value: -29, to: today)!,
            syncedAt: Date(), records: records.sorted { $0.watchedAt > $1.watchedAt }), scope: "preview")
        return model
    }
}
#endif
