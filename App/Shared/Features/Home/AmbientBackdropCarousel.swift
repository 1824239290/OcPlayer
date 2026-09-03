import CoreModel
import SwiftUI

/// 首页氛围背景：从库里随机取一批带 backdrop 的电影 / 剧集（`randomBackdropItems`），
/// 复用 `BackdropAmbienceView` 铺成模糊+雾化的固定底，每 12 秒淡入淡出换一张。
/// 纯装饰：查询失败或库里没有带 backdrop 的条目就整体不出现，页面回退纯色底。
struct AmbientBackdropCarousel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 海报氛围背景开关：与设置页 / DetailView 同一 key。关时整体不渲染、
    /// 不发起随机查询（task id 含开关状态，切回开时重新拉池子）。
    @AppStorage("dev.jumusu.ocplayer.interface.ambientBackdrop")
    private var ambientBackdropEnabled = true

    /// 池子大小 × 换片间隔 ≈ 一轮 96s：够「随机感」也不浪费带宽。
    private static let poolSize = 8
    private static let swapInterval: Duration = .seconds(12)
    /// 氛围底图统一 800 宽小图 + 512px 解码下采样——反正要糊掉，不拉原画。
    private static let imageWidth = 800

    @State private var pool: [MediaItem] = []
    @State private var index = 0

    var body: some View {
        ZStack {
            if ambientBackdropEnabled, !pool.isEmpty {
                BackdropAmbienceView(
                    target: pool[index % pool.count]
                        .imageTarget(app.server, kind: .backdrop, width: Self.imageWidth),
                    scrim: .home
                )
                .id(index)
                .transition(.section)
            }
        }
        .animation(Motion.ambient, value: index)
        // 开关并进 task id：停留首页时切开关，关→清空退场，开→重新拉池子。
        .task(id: "\(app.sessionGeneration)#\(ambientBackdropEnabled)") {
            await loadPool()
            await warmUpAndRotate()
        }
    }

    /// 查询 → 去重洗牌 → 首图进缓存后才亮相，避免首页一进来先闪一块灰占位。
    private func loadPool() async {
        pool = []
        index = 0
        guard ambientBackdropEnabled, let server = app.server else { return }

        var fetched = (try? await server.randomBackdropItems(limit: 24)) ?? []
        if fetched.isEmpty {
            // 服务器不支持随机查询 / 拉取失败：回退到首页已经拿到的条目。
            fetched = app.home.latest + app.home.resume + app.home.nextUp
        }
        var seen = Set<String>()
        let candidates = fetched.filter { $0.backdropImageTag != nil && seen.insert($0.id).inserted }
        guard !candidates.isEmpty else { return }

        let picked = Array(candidates.shuffled().prefix(Self.poolSize))
        if let first = picked.first {
            let target = first.imageTarget(server, kind: .backdrop, width: Self.imageWidth)
            if let url = target.url {
                _ = try? await ImagePipeline.shared.load(
                    url, authHeader: target.authHeader, maxPixelSize: 512
                )
            }
        }
        if Task.isCancelled { return }
        pool = picked
    }

    /// 剩余图片预热进 ImagePipeline（之后每次切换都命中内存缓存），再进入换片循环。
    /// `reduceMotion` 下只保留静态首图，不做轮换。
    private func warmUpAndRotate() async {
        guard let server = app.server, !pool.isEmpty else { return }
        for item in pool.dropFirst() {
            if Task.isCancelled { return }
            let target = item.imageTarget(server, kind: .backdrop, width: Self.imageWidth)
            guard let url = target.url else { continue }
            _ = try? await ImagePipeline.shared.load(
                url, authHeader: target.authHeader, maxPixelSize: 512
            )
        }
        guard pool.count > 1, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.swapInterval)
            if Task.isCancelled { return }
            index = (index + 1) % pool.count
        }
    }
}
