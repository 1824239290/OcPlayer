import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit

/// 合集（Jellyfin / Emby 的 Collection / BoxSet）与**媒体库卡**的封面。
///
/// ## 为什么需要这一层
///
/// 合集与合集库在服务端**一张图都没有**：实测 `ImageTags` / `BackdropImageTags` 都是空，
/// 7 种图片类型（Primary / Backdrop / Thumb / Logo / Art / Banner / Disc）**全部 404**。
/// 官方 web 端对此的兜底是一个 Material 图标（`video_library`），也就是一块灰底 ——
/// 但用户的信息诉求是「这里该有几张电影海报」。
///
/// 两条互补的路：
/// 1. **合集条目**：借 TMDb 合集的海报（`refreshTMDbCollection` 定位）。
/// 2. **合集库本身**（首页「媒体库」那一排的库卡）：服务端与 TMDb 都没有「一个库」的封面，
///    所以用**库里内容的海报拼一张** —— 列合集 → 取成员电影的海报 → 2×2 拼图。
///    只依赖服务端，**不需要 TMDb key**。
///
/// 两条路都按条目 / 库 id 做会话级缓存，并在换会话时清空（id 只在那台服务器上有意义）。
extension AppModel {

    /// 网格卡上该用的 TMDb 合集海报 URL。nil = 还没解析出来 / TMDb 上没有这个合集。
    ///
    /// **只补缺**：条目自己有服务端图（`primaryImageTag`）时返回 nil，照旧用服务端的图——
    /// 与详情页「TMDb 只补服务端缺的」同一条策略。合集的常态是服务端没图，所以这里
    /// 基本都会走到 TMDb 那条。
    func collectionPosterURL(for item: MediaItem, width: Int) -> URL? {
        guard item.kind == .boxSet, item.primaryImageTag == nil else { return nil }
        guard let path = collectionArtwork[item.id] else { return nil }
        // TMDb 的图**免鉴权**（CDN 不校验），调用方传 nil authHeader。
        return TMDbImageSize.url(path: path, requestedWidth: width)
    }

    /// 记下某合集的 TMDb 海报路径（详情页读到 overlay 后同步给网格，省掉一次解析）。
    func noteCollectionArtwork(itemID: MediaItem.ID, posterPath: String?) {
        guard let posterPath, !posterPath.isEmpty else { return }
        collectionArtwork[itemID] = posterPath
    }

    /// 卡片进入可视区时解析一次该合集的海报。**有界、失败不重试**。
    ///
    /// 成本：一次成员列表（走缓存装饰器、会写库）+ 最多 `collectionMemberLookupLimit`
    /// 次电影详情 + 一次合集详情；命中缓存时**一个请求都不发**（见
    /// `TMDbEnricher.refreshCollection` 的早退）。之所以按「卡片出现」触发而不是
    /// 进库时全量跑：可见即需要，滚动扫过几十个合集也不会一次打上百个请求。
    func resolveCollectionArtworkIfNeeded(for item: MediaItem) async {
        guard item.kind == .boxSet, item.primaryImageTag == nil else { return }
        guard collectionArtwork[item.id] == nil,
              !collectionArtworkAttempted.contains(item.id),
              !collectionArtworkInFlight.contains(item.id),
              collectionArtworkInFlight.count < Self.collectionArtworkConcurrency,
              tmdb.isReady,
              let server, let tenant = currentTenant
        else { return }
        let generation = sessionGeneration
        collectionArtworkInFlight.insert(item.id)
        defer { collectionArtworkInFlight.remove(item.id) }

        do {
            // 成员：1 个请求（`collectionMembers` 里那三条硬约束是唯一一份）。
            let page = try await server.collectionMembers(of: item.id)
            guard sessionIsCurrent(generation, server: server) else { return }
            _ = await tmdb.refreshCollection(item: item, members: page.items, tenant: tenant)
            guard sessionIsCurrent(generation, server: server) else { return }
            let overlay = await tmdb.overlay(for: item, tenant: tenant)
            guard sessionIsCurrent(generation, server: server) else { return }
            noteCollectionArtwork(itemID: item.id, posterPath: overlay?.posterPath)
            // 记账分两种：**拉到一轮 = 确定结论**（成功，或「TMDb 上没有这个合集」这种
            // 不会自己变好的结果）；**成员列表就失败**（断网 / 服务端出错）走下面的
            // catch，不记账——否则一次断网会让这些卡片此后永远空白。
            collectionArtworkAttempted.insert(item.id)
        } catch is CancellationError {
            return
        } catch {
            // 成员列表都拉不到（离线 / 服务端出错）：不记账，下次再试。
            AppDiagnostics.logWarning("合集封面解析失败", fields: [
                "item": .string(item.name),
                "error": .string("\(error)"),
            ])
        }
    }

    // MARK: - 媒体库卡封面（首页「媒体库」那排）

    /// 库卡上该用的封面图（最多 4 张，按 2×2 拼）。空 = 还没解析出来 / 拼不出来。
    ///
    /// **只补缺**：库自己有服务端封面（`primaryImageTag`）时返回空，照旧用服务端那张。
    func libraryCoverURLs(for library: MediaLibrary) -> [URL] {
        libraryCoverArt[library.id] ?? []
    }

    /// 卡片进入可视区时解析一次该库的封面。**有界、失败不重试**（与合集卡同一套规矩）。
    ///
    /// 服务端对合集库一张图都不给（7 种图片类型全部 404），所以这里用**库里内容的海报**
    /// 拼一张：列合集（1 个请求）→ 逐合集取成员（每个 1 个请求，最多
    /// `libraryCoverCollectionLimit` 个）→ 取成员电影的海报。
    ///
    /// 为什么往下钻一层：合集库里装的是**合集**，而合集自身没有图（这正是本文件存在的
    /// 原因）；只有成员电影才有服务端海报。实测成员确实都在（EVA 2 部、中二病 2 部），
    /// 所以 2 个合集正好凑满 2×2。
    ///
    /// 只走服务端，**不需要 TMDb key** —— 库卡在首页一进来就要画，不该被「用户配没配
    /// TMDb」挡住。
    func resolveLibraryCoverIfNeeded(for library: MediaLibrary) async {
        guard library.primaryImageTag == nil else { return }
        guard libraryCoverArt[library.id] == nil,
              !libraryCoverAttempted.contains(library.id),
              !libraryCoverInFlight.contains(library.id),
              libraryCoverInFlight.count < Self.libraryCoverConcurrency,
              let server
        else { return }
        let generation = sessionGeneration
        libraryCoverInFlight.insert(library.id)
        defer { libraryCoverInFlight.remove(library.id) }

        do {
            let top = try await server.itemsPage(
                parentID: library.id,
                kinds: nil,
                recursive: true,
                startIndex: 0,
                limit: Self.libraryCoverItemLimit,
                sort: MediaItemsSort(field: .name, ascending: true),
                watchState: nil,
                searchTerm: nil)
            guard sessionIsCurrent(generation, server: server) else { return }

            var posters = top.items.filter { $0.primaryImageTag != nil }
            // 合集库：库里是「合集」而合集没有图，再往下取一层成员的海报。
            if library.collectionType == .boxsets {
                var perCollection: [[MediaItem]] = []
                for box in top.items.prefix(Self.libraryCoverCollectionLimit) {
                    let members = (try? await server.collectionMembers(of: box.id, limit: 4))?.items ?? []
                    perCollection.append(members.filter { $0.primaryImageTag != nil })
                }
                // **轮转取**：先每个合集各来一张，再回头取第二张——拼出来能同时代表
                // 多个合集，而不是被第一个合集的成员占满。
                posters = []
                var index = 0
                while posters.count < Self.libraryCoverCount,
                      perCollection.contains(where: { $0.count > index }) {
                    for list in perCollection where list.count > index {
                        guard posters.count < Self.libraryCoverCount else { break }
                        posters.append(list[index])
                    }
                    index += 1
                }
            }
            guard sessionIsCurrent(generation, server: server) else { return }

            let urls = posters.prefix(Self.libraryCoverCount).compactMap { item in
                try? server.imageURL(itemID: item.id, type: .primary,
                                     maxWidth: Self.libraryCoverWidth, tag: item.primaryImageTag)
            }
            if !urls.isEmpty { libraryCoverArt[library.id] = urls }
            // 拉到一轮就是确定结论（成功，或「这个库确实没有可用的海报」），记账。
            libraryCoverAttempted.insert(library.id)
        } catch is CancellationError {
            return
        } catch {
            // 列表都拉不到（离线 / 服务端出错）：不记账，下次再试。
            AppDiagnostics.logWarning("媒体库封面解析失败", fields: [
                "library": .string(library.name),
                "error": .string("\(error)"),
            ])
        }
    }

    /// 库卡拼图最多几张。
    static let libraryCoverCount = 4
    /// 一个库最多列多少顶层条目来找海报。
    static let libraryCoverItemLimit = 12
    /// 合集库最多往下钻几个合集（每个一次成员请求）。
    static let libraryCoverCollectionLimit = 4
    /// 库卡封面的取图宽度：与库卡原本请求服务端封面的档位一致（720）。
    static let libraryCoverWidth = 720
    /// 同时解析的库卡封面上限（首页一排库，别一次打满）。
    static let libraryCoverConcurrency = 2
}
