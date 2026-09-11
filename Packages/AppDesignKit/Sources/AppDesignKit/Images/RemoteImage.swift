import CryptoKit
import Foundation
import SwiftUI

/// 远程图视图：加载中 / 失败都有落点，占位色跟主题走。
public struct RemoteImage: View {
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var loadedKey: String?

    public let url: URL?
    public var authHeader: String?
    /// 解码目标最大长边像素数；指定后通过 ImageIO 进行下采样，大幅降低大图内存开销。
    public var maxPixelSize: Int? = nil

    public init(url: URL?, authHeader: String? = nil, maxPixelSize: Int? = nil) {
        self.url = url
        self.authHeader = authHeader
        self.maxPixelSize = maxPixelSize
    }

    /// 与 .task(id:) 一致的复合加载键：URL + 凭证指纹 + 目标尺寸。
    ///
    /// 凭证指纹用 SHA256 截断，不用 `String.hashValue`：hashValue 只保证同进程内
    /// 同一字符串稳定，且这里比较的是「头字符串是否逐字节一致」——历史教训是
    /// authHeader 由 Dictionary 拼接、键序会抖，同语义头产生多种字节串、hash
    /// 随之漂移，.task(id:) 每次漂移都当作「新任务」清图重载，表现为图片反复闪。
    private static func credentialFingerprint(_ header: String?) -> String {
        guard let header else { return "none" }
        let digest = SHA256.hash(data: Data(header.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private var loadKey: String {
        "\(url?.absoluteString ?? "")#\(Self.credentialFingerprint(authHeader))#\(maxPixelSize ?? 0)"
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            // 常驻底层：加载中就是它在当占位，图片到位后从它上面淡入。
            // 灰度取 `Metrics.placeholderFill`，和骨架块同一个值——否则骨架撤掉、
            // 真实卡片上位而图还没下载完的那一瞬间，整墙灰会「变深一档」。
            Rectangle().fill(Metrics.placeholderFill)
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFill()
                    // 加载完成在占位层上淡入，不再硬弹出；换 URL 清空旧图时沿同一过渡淡出。
                    .transition(.section)
            } else if failed || url == nil {
                // 没有地址（该条目本来就没有这种图）和加载失败共用落点：
                // 显示静态占位图标。否则 url 为 nil 时会永远转圈（task 里被 guard 挡掉）。
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            // 加载中不需要额外分支：底层那块灰就是占位（原来这里又画了一块
            // 一模一样的 Rectangle，视觉上是 no-op，只多一层合成）。
        }
        .clipped()
        .animation(imageFade, value: image != nil)
        .task(id: loadKey) {
            // A row can keep its SwiftUI identity while its media value changes
            // (season switching / refresh). Clear the previous bitmap before
            // loading the new URL, otherwise the old poster can sit beside the
            // new title until another redraw.
            guard let url else {
                image = nil
                loadedKey = nil
                failed = false
                return
            }
            // 只有成功过的组合才跳过重载：失败的不记 loadedKey，
            // 视图再次出现时还能重试（瞬时断网不该让这张图永远 404 下去）。
            // 复合键（URL+凭证+目标尺寸）一致才跳过：同 URL 换尺寸/凭证要重载，
            // 否则会一直显示错误尺寸的旧位图。
            guard loadedKey != loadKey else { return }
            image = nil
            loadedKey = nil
            failed = false
            do {
                let loaded = try await ImagePipeline.shared.load(url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }   // 换 URL / 消失：新任务会接手，别写旧图
                if let loaded {
                    image = loaded
                    loadedKey = loadKey
                } else {
                    failed = true
                }
            } catch {
                // 只把真正的失败当失败：任务取消（视图消失 / 换 URL）不算，
                // 下次出现时 `.task(id:)` 会重新走一遍。
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    /// 图片出现/消失的淡入淡出；减弱动态效果时直接切换，不播动画。
    private var imageFade: Animation? {
        reduceMotion ? nil : Motion.standard
    }
}
