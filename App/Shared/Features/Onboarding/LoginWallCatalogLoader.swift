import AppDesignKit
import JellyfinKit
import MetadataKit
import SwiftUI

/// 装配登录页海报墙的素材。
///
/// ## 图从哪来，以及为什么不能用「缓存里像海报的文件」
///
/// 主来源是**本机媒体库里带主图的电影 / 剧集**：条目身份来自元数据缓存
/// （`MetadataStore.posterCandidates`），字节来自本机图片缓存。两者都**不需要会话**。
///
/// 一开始试过「直接扫缓存目录、挑竖版文件」，实测**行不通**：缓存里同时存着演员头像
/// （`/Items/{personId}/Images/Primary`）与条目海报，两者都是 2:3 竖图，按宽高比分不开
/// ——本机 429 张竖图里最大的两档尺寸（342×513 共 101 张、240×360 共 65 张）**几乎全是
/// 演员头像**，扫出来的墙是「一墙陌生人的脸」。所以摆哪些图必须由**条目身份**决定。
///
/// ## 没有 token 也能命中缓存
///
/// 图片缓存键里含一个由 `DeviceId + Token` 派生的身份哈希，而登录页出现时 token 已经
/// 被删了。会话还在时把那个哈希记进 `ImageCacheIdentityStore`，这里接着用即可——
/// 登出不会让磁盘上的字节消失。
///
/// ## 兜底
///
/// 首次安装、没有元数据缓存、或从没记过缓存身份时，退到程序化封面
/// （`LoginWallArt`，种子决定、离线可用、无版权问题）。墙永远不会是空的。
@MainActor
enum LoginWallCatalogLoader {

    /// 一次装几张。
    ///
    /// 下界由「常见窗口里**最大**的那面墙」定：2560×1440 实测要 91 张 tile
    /// （1320×840 只要 60 张）。素材少于这个数，同一张海报就会在一屏里出现两次
    /// ——那是看得出来的。取 96 留一点余量。
    static let catalogSize = 96

    /// 本机一张海报都装配不出来时的兜底张数。与 `catalogSize` **同口径**：
    /// 兜底墙同样不该出现重复（程序化封面只是没有图，不是可以随便糊弄）。
    static let fallbackSize = 96

    /// 装配整面墙。`app` 只用来读元数据缓存与服务器档案，**不发任何网络请求**。
    static func load(app: AppModel) async -> [LoginWallPoster] {
        let posters = await libraryPosters(app: app)
        return posters.isEmpty ? proceduralCatalog(count: fallbackSize) : posters
    }

    /// 主来源：本机媒体库里带主图的电影 / 剧集，且字节确实在图片缓存里。
    ///
    /// ## 重活都在 `nonisolated` 里
    ///
    /// 「这张海报的字节在不在本机」要试 `ladder(3) × identities(≤20)` 个组合，每个
    /// 组合一次 `cachedFileURL`（内部 `URLComponents` 重排 + FNV1a + 一次 `fileExists`）。
    /// 实测单次 **21.74 µs**，96 张候选全落空时 = **5 760 次 / 125.2 ms**。
    /// 改前这一整段跑在 `@MainActor` 上，而登录页正是用户点完「退出登录」马上看到的
    /// 页面 —— 卡在这儿最刺眼。
    ///
    /// 这里只保留必须主 actor 的部分（读 `app.store.profiles` / 拿 `activeStore`），
    /// 逐候选的判定与组装都交给 `resolvePosters`（`nonisolated async`，在全局并发
    /// 执行器上跑，且沿用结构化并发、离页即取消）。
    static func libraryPosters(app: AppModel) async -> [LoginWallPoster] {
        guard await app.metadata.waitUntilReady(), let store = app.metadata.activeStore else { return [] }

        let pipeline = ImagePipeline.shared
        var posters: [LoginWallPoster] = []

        // 多台服务器：按档案顺序取，谁先凑满算谁。跨服务器的条目 id 互不相干，
        // 所以每台都用自己的档案拼 URL、用自己的缓存身份算键。
        for profile in app.store.profiles {
            guard posters.count < catalogSize else { break }
            let identities = await ImageCacheIdentityStore.identities(for: profile.id)
            guard !identities.isEmpty else { continue }
            guard let candidates = try? await store.posterCandidates(
                tenant: TenantID(profile: profile), limit: catalogSize
            ) else { continue }

            let resolved = await resolvePosters(
                candidates: candidates,
                profile: profile,
                identities: identities,
                pipeline: pipeline,
                limit: catalogSize - posters.count
            )
            posters.append(contentsOf: resolved)
        }
        return posters
    }

    /// 逐候选判定 + 组装。**`nonisolated async`**：在全局并发执行器上跑，
    /// 不占主线程；外层取消（离页）会自然传播进来。
    ///
    /// 用 `nonisolated async` 而不是 `Task.detached`：后者脱离结构化并发，
    /// 视图消失后这 5 760 次文件判定仍会跑完。
    ///
    /// ## ⚠️ 「离开主线程」是**当前编译设置**的产物，不是语法保证
    ///
    /// 独立审查实测：本工程（`SWIFT_VERSION=6.0`、无任何 `-enable-upcoming-feature`）
    /// 下从 `@MainActor` 调这里的 `nonisolated async`，`pthread_main_np() == 0`；
    /// 但只要打开 `NonisolatedNonsendingByDefault` 或 `ApproachableConcurrency`，
    /// **同一段代码立刻变回 `pthread_main_np() == 1`**（跑回主 actor）。
    ///
    /// 也就是说：将来谁为了采用 Swift 6.2 的并发默认值打开那个开关，这里会**静默
    /// 退化成主线程执行**，而这批的性能收益（5 760 次 × 21.74 µs）会全部还回去。
    /// `LoginWallOffMainTests` 用「主线程心跳计数」把这条前提钉住了 —— 真退化了会红。
    nonisolated static func resolvePosters(
        candidates: [CachedItem],
        profile: ServerProfile,
        identities: [String],
        pipeline: ImagePipeline,
        limit: Int
    ) async -> [LoginWallPoster] {
        guard limit > 0 else { return [] }
        var posters: [LoginWallPoster] = []
        posters.reserveCapacity(min(candidates.count, limit))

        for candidate in candidates {
            if Task.isCancelled || posters.count >= limit { break }
            let item = candidate.item
            guard let tag = item.primaryImageTag else { continue }
            guard let file = resolvePosterFile(
                pipeline: pipeline, profile: profile, identities: identities,
                itemID: item.id, tag: tag
            ) else { continue }

            posters.append(
                LoginWallPoster(
                    id: item.id,
                    title: item.name,
                    year: item.year,
                    imageFile: file,
                    art: LoginWallArt.make(seedString: item.id)
                ))
        }
        return posters
    }

    /// 这张海报的字节在本机吗？
    ///
    /// 两个维度都要试，缺一个都会静默变空：
    ///
    /// * **参数阶梯**——`maxWidth` 与 `maxPixelSize` 都是缓存键的一部分，而它们当初
    ///   由海报卡的盒子宽度决定，会随布局改动而漂移（见 `LoginWallStyle.cacheParameterLadder`）。
    /// * **身份历史**——身份由 `DeviceId + Token` 派生，而 token 会轮换；轮换一次，
    ///   全部缓存键跟着变，字节却一张没少（见 `ImageCacheIdentityStore`）。
    ///
    /// 每个组合只是一次「文件在不在」的判断，不发网络请求。
    nonisolated static func resolvePosterFile(
        pipeline: ImagePipeline,
        profile: ServerProfile,
        identities: [String],
        itemID: String,
        tag: String
    ) -> URL? {
        for step in LoginWallStyle.cacheParameterLadder {
            guard let url = profile.imageURL(
                itemID: itemID, type: .primary, maxWidth: step.maxWidth, tag: tag
            ) else { continue }
            for identity in identities {
                if let file = pipeline.cachedFileURL(
                    url: url, cacheIdentity: identity, maxPixelSize: step.maxPixelSize
                ) {
                    return file
                }
            }
        }
        return nil
    }

    /// 纯程序化的一整面墙（本机没有可用海报时）。
    static func proceduralCatalog(count: Int) -> [LoginWallPoster] {
        (0..<max(count, 0)).map { index in
            let key = "art-\(index)"
            return LoginWallPoster(id: key, art: LoginWallArt.make(seedString: key))
        }
    }
}
