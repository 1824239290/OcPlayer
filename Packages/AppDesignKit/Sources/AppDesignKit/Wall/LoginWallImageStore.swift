import Foundation

/// 墙上真实海报的取图口：**只读本机缓存文件，绝不发网络请求**。
///
/// ## 为什么需要一层
///
/// 因为墙会**重复**引用同一张海报。登录页只拿得到本机缓存里那几十张，一面 60 格的
/// 墙里同一张出现两三次是常态，而它们会**同时**开始加载——每个都各自读一遍磁盘、
/// 各自解码一遍。这里用一个在途表把它们收敛成一次，后来的订阅者直接等同一个任务。
///
/// 不做成 `@Observable`：每张 tile 在 `.task` 里取一次图、存在自己的 `@State` 里。
/// 共享的可观察缓存会让每一张到图都作废整面墙。
@MainActor
public final class LoginWallImageStore {
    public static let shared = LoginWallImageStore()

    /// 解码预算。tile 在 2× 屏上最宽约 356px，400 足够且不浪费内存。
    private static let maxPixelSize = 400

    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    public init() {}

    /// 取一张海报的位图。`nil` = 本机没有这张（或读不出来），调用方退程序化封面。
    public func image(for poster: LoginWallPoster) async -> PlatformImage? {
        guard let file = poster.imageFile else { return nil }

        let key = file.path
        if let existing = inFlight[key] {
            return await existing.value
        }

        // `Task.detached` 而不是 `Task`：本类在 `@MainActor` 上，`Task {}` 会**继承**
        // 主 actor，于是 `decodeCachedFile` 里那次同步的 `Data(contentsOf:)` 读盘
        // 会落在主线程上——一面墙几十张图就是几十次主线程读盘，正好卡在首帧。
        let task = Task.detached(priority: .userInitiated) {
            await ImagePipeline.shared.decodeCachedFile(file, maxPixelSize: Self.maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}
