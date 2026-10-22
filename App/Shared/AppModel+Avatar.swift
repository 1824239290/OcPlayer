import AppDesignKit
import Foundation
import JellyfinKit
#if canImport(UIKit)
import CoreImage
import UIKit

/// 头像「去饱和」那一张图共用的 Core Image 上下文。
///
/// 建一次就够（每次新建是毫秒级开销），而这条路只在头像变化时跑一次；放文件作用域
/// 而不是 `AppModel` 的静态属性，是因为它是纯粹的渲染细节、没有理由挂到模型上。
private let avatarGrayContext: CIContext = {
    CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
}()
#endif

/// 当前账号头像的装载。
///
/// ## 为什么头像要「先出位图、再进标签栏」
///
/// 首页 Tab 的图标想用服务端上这个账号的头像（对照产品 Rex 的「发现」栏位就是这个
/// 形态）。但标签栏项是**宿主**渲染的：异步图加载完**不会**回填进去，把
/// `RemoteImage` 挂在那儿只会永远停在占位。所以这条路只能是——把头像先取成一张
/// 位图放进模型，标签栏同步读一个值。
///
/// ## 位图还必须**先烤成标签栏要的样子**
///
/// 实拍（iOS 26.3 / iPhone 17 Pro 模拟器）量出来三条硬约束，任何一条不满足标签栏
/// 就画不对——细节见 `AppShell.swift` 首页 Tab 的注释：
///
/// * 标签栏按位图的**自然尺寸**画（`.frame` / `.resizable()` / `.clipShape()` 全被
///   忽略）：84px 的位图会被画成 84pt，比邻居胖三倍。→ 得按点尺寸栅格化。
/// * 标签栏把位图当**模板图**渲染，SwiftUI 的 `.renderingMode(.original)` 不管用。
///   → 得在 `UIImage` 上钉 `alwaysOriginal`。
/// * 裁圆只能在位图里做（`clipShape` 同样被忽略）。
///
/// 三件事都收在 `tabIcon(from:)` 一处，装载完成时就烤好。
///
/// ## 两级来源，各司其职
///
/// 1. **档案里的 tag**（`ServerProfile.primaryImageTag`，登录响应白拿的）：
///    冷启动 / 离线时唯一的来源。没有它，首帧会先亮一个「首页」房子图标再被头像
///    顶掉——那正是我们要避免的闪烁。
/// 2. **服务端的 `/Users/Me`**：校准。用户在服务端换过头像之后，档案里那份 tag 就
///    过期了；tag 变则 URL 变，图片缓存自然不命中（不需要手工失效任何缓存）。
///
/// 头像在服务端是**可选**的：多数账号没设，`primaryImageTag` 为 nil，此时不发任何
/// 请求（那是一次必然 404 的白打），标签栏回落 `house.fill`。
extension AppModel {

    /// 标签栏图标槽里的头像边长（pt）。iOS 标签栏图标是 ~25–28pt 的槽位，
    /// 取 28 让圆形头像贴满它。
    static let userAvatarPointSize: CGFloat = 28

    /// 取图时的下采样目标（像素）。按 3× 屏取够用，同时保证标签栏那格不会抱着一张
    /// 服务端原图（用户可能上传了 2000×2000）。
    ///
    /// ⚠️ **不是烤出来那张位图的尺寸**：`tabIcon(from:)` 按屏幕 scale 栅格化
    /// （@3x 屏 84px / iPad 的 @2x 屏 56px，两者自然尺寸都是 28pt）。这里只是
    /// 「取图时最多要这么多像素」的上限。
    static let userAvatarPixelSize = Int(userAvatarPointSize * 3)

    /// 把取到的位图做成**标签栏能直接用**的样子：裁圆、按点尺寸栅格化、
    /// 钉上 `alwaysOriginal`。
    ///
    /// macOS 不做（那边没有标签栏：分区入口是窗口工具栏里的玻璃药丸），原样返回。
    static func tabIcon(from image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        let pointSize = userAvatarPointSize
        let rect = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        // `UIGraphicsImageRendererFormat.default()` 自带屏幕 scale：@3x 屏得到
        // 28pt = 84px 的位图，iPad 那种 @2x 屏得到 56px —— 两者**自然尺寸都是 28pt**，
        // 标签栏按 28pt 画，与其它 glyph 槽位同高（所以别把像素数当常量钉）。
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            // 等比填满（与 SwiftUI `.scaledToFill()` 同语义）：头像多半是方的，
            // 非方图也不该被拉变形。
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: rect.midX - drawn.width / 2,
                                  y: rect.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return rendered.withRenderingMode(.alwaysOriginal)
        #else
        return image
        #endif
    }

    /// 未选中态的标签栏头像：把 `tabIcon(from:)` 烤好的那张**去饱和**，尺寸 / 圆形 /
    /// `alwaysOriginal` 全部沿用。
    ///
    /// 用户口径（2026-10-22）：标签栏里「首页」那一格也要像 macOS 药丸那样
    /// **选中彩色 / 未选中灰**。iOS 没有 SwiftUI 侧的状态感知（`Tab` 只吃一张图，
    /// `.grayscale` / `.saturation` 这些绘制修饰符在交给标签栏前就被丢掉），所以灰色
    /// 那一张必须在**位图阶段**做出来，再由 `UITabBarItem` 的 `image`（未选中）/
    /// `selectedImage`（选中）按状态用（见 `TabBarBrandIconBridge`）。
    ///
    /// 与 macOS 药丸的 `.grayscale(1)` 同口径：**只抽饱和度、不动亮度**（不是压暗，
    /// 也不是调不透明度）——那是量出来的：头像亮度由图片内容决定，压暗在浅色玻璃上
    /// 读不出来（理由见 `SectionAvatarIcon` 的类型注释）。
    ///
    /// 用 Core Image 的 `CIColorControls(saturation: 0)` 而不是 `CIColorMonochrome`：
    /// 后者会再乘一次亮度系数，实测洋红 `#F70098` 被压成 **63/255**（细节全糊掉），
    /// 而 `CIColorControls` 保亮度、只去色相。`CIContext` 复用同一个静态实例
    /// （每次新建是毫秒级开销，而这只在头像变化时跑一次）。
    static func grayscaleTabIcon(from image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let gray = avatarGrayContext.createCGImage(output, from: output.extent)
        else { return nil }
        // 尺寸 / scale 照抄源图（28pt），渲染模式必须还是 `alwaysOriginal`——
        // 否则标签栏会把它当模板图染成一坨纯色。
        return UIImage(cgImage: gray, scale: image.scale, orientation: image.imageOrientation)
            .withRenderingMode(.alwaysOriginal)
        #else
        return image
        #endif
    }

    /// 会话落地后装载头像。由 `activate(server:)` 调用，代次沿用会话代次。
    ///
    /// 刻意**不**在失败时把已有的位图清掉：头像拉不到（离线 / 服务器半死）时，
    /// 保留档案里那张旧图比变回房子图标好——这与「离线重启后海报还在」是同一条口径。
    func loadUserAvatar(server: any MediaServer, generation: Int) async {
        let cachedTag = server.profile.primaryImageTag

        // ① 档案里那份：有就直接出图（冷启动第一帧就有，不必等网络）。
        if let cachedTag, let url = server.userImageURL(tag: cachedTag) {
            await applyUserAvatar(
                from: url,
                authHeader: server.authorizationHeader,
                server: server,
                generation: generation
            )
        }

        // ② 向服务端校准一次。
        //
        // ⚠️ 这里**不能**写成 `guard let freshTag = try? await …`：`try?` 对
        // 「返回 Optional 的 throwing 调用」会拍平一层，于是「调用失败」与
        // 「调用成功但服务端说没有头像」都会走进同一个 else —— 而这两种情况的
        // 处理是相反的（前者保留旧图，后者要清掉）。所以拆开写。
        let freshTag: String?
        do {
            freshTag = try await server.currentUserAvatarTag()
        } catch {
            // 校准失败（离线 / 老服务器没有这个端点）：保持 ① 的结果。
            return
        }
        guard sessionIsCurrent(generation, server: server) else { return }

        if freshTag == cachedTag { return }

        // tag 变了：先把新值落进档案（下次冷启动直接出新的那张），再按它出图。
        persistUserAvatarTag(freshTag, server: server)

        // 服务端上已经没有头像了（用户把它删了）：清掉回落图标。**必须在这里拦住**，
        // 否则会拿一条没有 tag 的 URL 去取图 —— 那是一次必然 404 的白打。
        guard let freshTag, let url = server.userImageURL(tag: freshTag) else {
            userAvatarImage = nil
            return
        }
        await applyUserAvatar(
            from: url,
            authHeader: server.authorizationHeader,
            server: server,
            generation: generation
        )
    }

    /// 取图（磁盘缓存优先，`load` 自带「先读本地再回源」）+ 代次校验后落地。
    private func applyUserAvatar(
        from url: URL,
        authHeader: String?,
        server: any MediaServer,
        generation: Int
    ) async {
        let image = try? await avatarImagePipeline.load(
            url,
            authHeader: authHeader,
            maxPixelSize: Self.userAvatarPixelSize
        )
        // 取图期间可能已经换了服务器 / 登出：旧账号的脸不能落到新会话上。
        guard sessionIsCurrent(generation, server: server) else { return }
        // 落进模型的是**标签栏版本**（裁圆 + 按点尺寸栅格化 + alwaysOriginal），
        // 不是原始位图 —— 理由见本文件头部与 `tabIcon(from:)`。
        userAvatarImage = image.map(Self.tabIcon(from:))
    }

    /// 把校准出来的 tag 写回档案。
    ///
    /// 走 `ServerStore.setPrimaryImageTag`（内部是 `mutate`）而不是 `store.save`：
    /// `save` 会过 `ServerProfile.merged`，那条规则「新档案没带 tag 就沿用旧的」
    /// 会让 `nil` **写不进去** —— 而「服务端上头像已经没了」必须落盘，否则下次冷
    /// 启动又拿旧 tag 出图。理由见那个方法的注释。
    private func persistUserAvatarTag(_ tag: String?, server: any MediaServer) {
        store.setPrimaryImageTag(tag, for: server.profile.id)
    }
}
