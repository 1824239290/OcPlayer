import AppDesignKit
import CoreModel
import JellyfinKit
import SwiftUI

/// 观看记录与继续观看共用封面尺寸、取图顺序和无图占位。
struct MyViewingPoster: View {
    let item: MediaItem
    @Environment(AppModel.self) private var app
    @ScaledMetric private var posterWidth: CGFloat = 44

    private var target: (url: URL?, authHeader: String?) {
        if item.kind == .episode, let seriesID = item.seriesID {
            let series = app.home.latest.first { $0.id == seriesID && $0.kind == .series }
            if let tag = item.seriesPrimaryImageTag ?? series?.primaryImageTag {
                if let url = FileLibraryArtwork.imageURL(forTag: tag, width: 200) {
                    return (url, nil)
                }
                if let server = app.server {
                    let url = try? server.imageURL(itemID: seriesID, type: .primary, maxWidth: 200, tag: tag)
                    return (url, server.authorizationHeader)
                }
            }
        }
        return item.imageTarget(app.server, kind: .primary, width: 200)
    }

    var body: some View {
        let target = target
        MediaArtwork(url: target.url, authHeader: target.authHeader,
                     cacheScope: app.activeImageCacheScope,
                     shape: .poster, width: posterWidth, cornerRadius: 7,
                     emptyIcon: "film", aspectRatio: 2.0 / 3.0, scaling: .fill)
            .accessibilityHidden(true)
    }
}
