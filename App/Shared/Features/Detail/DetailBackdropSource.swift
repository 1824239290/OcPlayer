import CoreModel
import Foundation
import MetadataKit
import JellyfinKit

/// 点击预取和详情解析共享的来源策略。合集成员兜底仍由详情模型在成员落地后处理。
enum DetailBackdropSource {
    static func resolve(item: MediaItem, server: (any MediaServer)?, overlay: TMDbOverlay?,
                        policy: TMDbImagePolicy, width: Int) -> BackdropSourceLatch.Target {
        let serverTarget = item.imageTarget(server, kind: .backdrop, width: width)
        let url = DisplayMetadata.backdropURL(serverURL: serverTarget.url, overlay: overlay,
                                             requestedWidth: width, policy: policy)
        return BackdropSourceLatch.Target(
            url: url, authHeader: url.map { DisplayMetadata.isTMDbImage($0) } == true ? nil : serverTarget.authHeader,
            cacheScope: url.map { DisplayMetadata.isTMDbImage($0) } == true ? nil : server?.profile.imageCacheScope
        )
    }
}
