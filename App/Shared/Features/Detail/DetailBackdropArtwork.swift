import AppDesignKit
import Foundation
import Observation

/// 一次详情访问持有的实际像素。清晰层与模糊层只观察这一份加载结果。
@MainActor @Observable
final class DetailBackdropArtwork {
    struct Snapshot {
        let target: BackdropSourceLatch.Target
        let image: PlatformImage
    }

    typealias Loader = @MainActor (URL, String?, Int) async throws -> PlatformImage?
    typealias CacheReader = @MainActor (URL, String?, Int) -> PlatformImage?

    private(set) var entry: Snapshot?
    private(set) var content: Snapshot?
    @ObservationIgnored private var capturedEntry = false
    @ObservationIgnored private var requested: BackdropSourceLatch.Target?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let cachedImage: CacheReader

    init(cachedImage: @escaping CacheReader = { url, auth, pixels in
        ImagePipeline.shared.memoryCachedImage(url: url, authHeader: auth, maxPixelSize: pixels)
    }, loader: @escaping Loader = { url, auth, pixels in
        try await ImagePipeline.shared.load(url, authHeader: auth, maxPixelSize: pixels)
    }) {
        self.cachedImage = cachedImage
        self.loader = loader
    }

    /// 只借用进页时已在内存里的氛围图，不追随轮播，也不为过渡图另发请求。
    func captureEntry(target: BackdropSourceLatch.Target) {
        guard !capturedEntry else { return }
        capturedEntry = true
        guard let url = target.url,
              let image = cachedImage(url, target.authHeader, DetailAmbienceImage.decodePixels)
        else { return }
        entry = Snapshot(target: target, image: image)
    }

    @discardableResult
    func prepare(target: BackdropSourceLatch.Target) -> Task<Void, Never>? {
        // 离页后，迟到的元数据回调不能从已取消的页面任务重新启动图片加载。
        guard !Task.isCancelled else { return nil }
        guard let url = target.url, content?.target != target else { return nil }
        guard requested != target else { return task }
        cancel()
        requested = target
        if let image = cachedImage(url, target.authHeader, DetailAmbienceImage.artDecodePixels) {
            content = Snapshot(target: target, image: image)
            return nil
        }
        let ticket = generation
        task = Task { [weak self, loader] in
            let image = try? await loader(url, target.authHeader, DetailAmbienceImage.artDecodePixels)
            guard !Task.isCancelled, let self, self.generation == ticket, let image else { return }
            // 一次赋值提交整组像素；视图不再分别发起清晰图/模糊图请求。
            self.content = Snapshot(target: target, image: image)
        }
        return task
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        requested = nil
    }
}
