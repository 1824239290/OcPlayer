import AppDesignKit
import SwiftUI

/// 详情背景的唯一合成入口：固定过渡底图 → 已就绪条目图。两种版式共享生命周期。
struct DetailBackdropView: View {
    let artwork: DetailBackdropArtwork
    let viewport: CGSize
    /// nil 为全页氛围版式；翻页版式只动画模糊遮罩的扩张。
    var expanded: Bool? = nil
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.pageBackground
            if let entry = artwork.entry {
                // 进页借来的图只作模糊过渡，不能成为其他作品的清晰封面。
                BackdropAmbienceView(
                    target: (entry.target.url, entry.target.authHeader),
                    scrim: .home, fade: nil, image: entry.image
                )
            }
            if let content = artwork.content {
                Group {
                    if let expanded {
                        DetailPageArt(viewport: viewport, image: content.image, expanded: expanded, vertical: vertical)
                    } else {
                        BackdropAmbienceView(
                            target: (content.target.url, content.target.authHeader),
                            scrim: .detail, fade: nil, image: content.image
                        )
                    }
                }
                .compositingGroup()
                .id(content.target.url)
                .transition(.opacity)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: artwork.content?.target.url)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
