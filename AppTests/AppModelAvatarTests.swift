import AppDesignKit
import CoreModel
import ImageIO
import JellyfinKit
@testable import OcPlayer
import XCTest
#if os(macOS)
import AppKit
#endif

/// 首页 Tab 头像的装载与生命周期（`AppModel+Avatar.swift`）。
///
/// 这些用例全部离线：取图走注入的 `ImagePipeline`（挂 `MockURLProtocol`），
/// 服务器走 `StubMediaServer`。真实实现里那条 `ImagePipeline.shared` 的调用与
/// 这里注入的管道**同一个方法**，所以「头像真的落进了模型」这条断言走的是完整
/// 加载链（含 `maxPixelSize` 下采样），不是替身。
@MainActor
final class AppModelAvatarTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ServerStore!
    private var pipelineDirectory: URL!
    /// 记下取图请求（断言「换了头像会拿新 tag 再取一次」）。
    private let requestedURLs = RequestLog()

    // `async` 版本（不是同步的 `setUp()`）：本类是 `@MainActor`，同步的 setUp 是
    // nonisolated，碰这些 main actor 隔离的属性会报并发警告。与 `TMDbCoordinatorTests`
    // / `MetadataCacheIntegrationTests` 同一条既有写法。
    override func setUp() async throws {
        try await super.setUp()
        let suite = "AppModelAvatarTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
        pipelineDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        if let pipelineDirectory { try? FileManager.default.removeItem(at: pipelineDirectory) }
        try await super.tearDown()
    }

    // MARK: - 装配

    /// 造一个「会话已落地」的 AppModel。
    ///
    /// `app.server` 必须赋值：`loadUserAvatar` 的每处落点都过
    /// `sessionIsCurrent(generation:server:)`（换会话 / 登出后旧账号的结果不能落到
    /// 新会话上），而它比对的就是 `self.server?.profile.id`。生产路径里这个前提由
    /// `activate(server:)` 保证（先 `self.server = cached` 再起头像任务），这里手工
    /// 复现同一条前提。
    private func makeApp(stub: StubMediaServer, avatarBytes: Data? = nil) -> AppModel {
        let app = AppModel(store: store, preferences: defaults)
        app.server = stub
        MockURLProtocol.handler = { [requestedURLs] request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: avatarBytes == nil ? 404 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "image/png"]
            )!
            return (response, avatarBytes ?? Data())
        }
        app.avatarImagePipeline = ImagePipeline(
            cacheDirectory: pipelineDirectory,
            protocolClasses: [MockURLProtocol.self]
        )
        return app
    }

    /// 一张纯色 PNG（尺寸可控，用来验证下采样真的发生了）。
    private static func syntheticPNG(size: CGSize) -> Data {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: - 装载

    /// 有头像：位图落进模型，且**已经是标签栏要的样子**（28pt + alwaysOriginal）。
    ///
    /// 这两条不是美观问题，是标签栏的硬要求：实测（iOS 26.3 模拟器）标签栏按位图的
    /// **自然尺寸**画、按**模板**渲染 —— 直接塞原始位图会得到一块 84pt 的纯黑圆角块。
    func testAvatarBitmapLandsInModelTabReady() async throws {
        let stub = StubMediaServer(primaryImageTag: "av-1")
        stub.userAvatarTagResult = .success("av-1")
        let app = makeApp(stub: stub, avatarBytes: Self.syntheticPNG(size: CGSize(width: 600, height: 600)))

        await app.loadUserAvatar(server: stub, generation: app.sessionGeneration)

        let image = try XCTUnwrap(app.userAvatarImage, "服务端有头像时必须出图")
        #if canImport(UIKit)
        // 标签栏版本的三条硬要求。macOS 没有标签栏（分区入口是工具栏药丸），
        // `tabIcon(from:)` 在那里原样返回，所以这几条只在 iOS 断言。
        XCTAssertEqual(image.size.width, AppModel.userAvatarPointSize, accuracy: 0.5)
        XCTAssertEqual(image.size.height, AppModel.userAvatarPointSize, accuracy: 0.5)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal,
                       "模板渲染会把整张头像变成一坨纯色")
        #endif
    }

    /// `tabIcon(from:)` 的三件事：**裁圆**（四角透明、中心不透明）、**按点尺寸栅格化**、
    /// **钉 alwaysOriginal**。少任何一条，实拍出来的标签栏图标都是错的。
    #if canImport(UIKit)
    func testTabIconBakesCircleSizeAndRenderingMode() throws {
        let source = Self.syntheticPNGImage(size: CGSize(width: 200, height: 200))
        let icon = AppModel.tabIcon(from: source)

        XCTAssertEqual(icon.size.width, AppModel.userAvatarPointSize, accuracy: 0.5)
        XCTAssertEqual(icon.renderingMode, .alwaysOriginal)
        let cg = try XCTUnwrap(icon.cgImage)
        // **别把像素数写成常量**：烤图密度跟**屏幕 scale** 走 —— @3x 机是 84px、iPad 那种
        // @2x 机是 56px，两种都对（位图的自然尺寸都是 28pt，标签栏按点画）。此前这里钉的是
        // `userAvatarPixelSize`（＝按 @3x 估的解码预算 84），于是**只有 @3x 机型能过**：
        // destination 换成 iPad 模拟器当场红，而 CI 一直跑 iPhone 所以没暴露。
        XCTAssertEqual(icon.scale, UIGraphicsImageRendererFormat.default().scale,
                       "烤图密度必须跟屏幕一致，不能钉死某一档")
        XCTAssertEqual(cg.width, Int((AppModel.userAvatarPointSize * icon.scale).rounded()),
                       "像素数 = 点尺寸 × 屏幕 scale（@2x 56 / @3x 84）")

        // 裁圆：四角透明、中心不透明。
        XCTAssertEqual(Self.alpha(of: cg, x: 1, y: 1), 0, accuracy: 0.02, "左上角必须被裁掉")
        XCTAssertEqual(Self.alpha(of: cg, x: cg.width - 2, y: cg.height - 2), 0, accuracy: 0.02,
                       "右下角必须被裁掉")
        XCTAssertEqual(Self.alpha(of: cg, x: cg.width / 2, y: cg.height / 2), 1, accuracy: 0.02,
                       "中心必须还是那张图")
    }

    /// 读某个像素的 alpha（0…1）。`y` 从**上往下**数（与截图直觉一致）。
    private static func alpha(of image: CGImage, x: Int, y: Int) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 原点在左下角，把 y 翻过来。
        let row = height - 1 - y
        return Double(pixels[(row * width + x) * 4 + 3]) / 255
    }
    #endif

    /// 服务端上这个账号**没有**头像（多数账号如此）：不发取图请求，模型留空，
    /// 标签栏回落 `house.fill`。
    func testAccountWithoutAvatarFetchesNoImage() async {
        let stub = StubMediaServer()          // profile 里也没有 tag
        stub.userAvatarTagResult = .success(nil)
        let app = makeApp(stub: stub, avatarBytes: Self.syntheticPNG(size: CGSize(width: 64, height: 64)))

        await app.loadUserAvatar(server: stub, generation: app.sessionGeneration)

        XCTAssertNil(app.userAvatarImage)
        XCTAssertEqual(stub.callCount("currentUserAvatarTag"), 1, "校准查询本身要发")
        XCTAssertEqual(requestedURLs.count, 0, "没有 tag 就不该发取图请求（那是一次必然 404 的白打）")
    }

    /// 用户在服务端换过头像：新 tag 要落进档案（下次冷启动直接出新的那张），
    /// 并且按**新** tag 重新取图。
    func testChangedAvatarTagIsPersistedAndRefetched() async {
        store.activate(profileWithAvatarTag("av-old"), token: "tok")
        let stub = StubMediaServer(primaryImageTag: "av-old")
        stub.userAvatarTagResult = .success("av-new")
        let app = makeApp(stub: stub, avatarBytes: Self.syntheticPNG(size: CGSize(width: 120, height: 120)))

        await app.loadUserAvatar(server: stub, generation: app.sessionGeneration)

        XCTAssertEqual(store.currentProfile?.primaryImageTag, "av-new", "新 tag 必须落盘")
        XCTAssertTrue(requestedURLs.snapshot().contains { $0.contains("tag=av-new") },
                      "换了头像必须按新 tag 再取一次，实际请求：\(requestedURLs.snapshot())")
        XCTAssertNotNil(app.userAvatarImage)
    }

    /// 用户把头像删了：服务端报 nil，档案里那份是旧的 —— 内存里那张要清掉，
    /// 否则 Tab 上会永远挂着一张服务端已经没有的脸。
    func testDeletedAvatarClearsStaleImage() async {
        store.activate(profileWithAvatarTag("av-old"), token: "tok")
        let stub = StubMediaServer(primaryImageTag: "av-old")
        stub.userAvatarTagResult = .success(nil)
        let app = makeApp(stub: stub, avatarBytes: Self.syntheticPNG(size: CGSize(width: 120, height: 120)))
        // 先按档案里那份出一张（模拟上一轮的落点）。
        app.userAvatarImage = Self.syntheticPNGImage(size: CGSize(width: 28, height: 28))

        await app.loadUserAvatar(server: stub, generation: app.sessionGeneration)

        XCTAssertNil(app.userAvatarImage)
        XCTAssertNil(store.currentProfile?.primaryImageTag, "服务端说没有头像 → 档案也要跟着清")
    }

    /// 校准失败（离线 / 老服务器没有 `/Users/Me`）时保留档案里那张：变回房子图标
    /// 比留一张旧头像更糟，这与「断网重启后海报还在」是同一条口径。
    func testCalibrationFailureKeepsProfileAvatar() async throws {
        store.activate(profileWithAvatarTag("av-old"), token: "tok")
        let stub = StubMediaServer(primaryImageTag: "av-old")
        stub.userAvatarTagResult = .failure(URLError(.notConnectedToInternet))
        let app = makeApp(stub: stub, avatarBytes: Self.syntheticPNG(size: CGSize(width: 120, height: 120)))

        await app.loadUserAvatar(server: stub, generation: app.sessionGeneration)

        XCTAssertNotNil(app.userAvatarImage, "档案里有 tag，取图成功后不该被校准失败清掉")
    }

    /// 换会话 / 登出（`resetBrowseState` 是唯一的会话边界）：头像位图与在途任务
    /// 都要清 —— 头像是「你是谁」，挂着上一个账号的脸比挂旧海报刺眼得多。
    func testResetBrowseStateClearsAvatar() {
        let app = makeApp(stub: StubMediaServer())
        app.userAvatarImage = Self.syntheticPNGImage(size: CGSize(width: 28, height: 28))

        app.resetBrowseState()

        XCTAssertNil(app.userAvatarImage)
        XCTAssertNil(app.userAvatarTask)
    }

    // MARK: - 辅助

    /// 档案 id 必须与 `StubMediaServer` 的默认 id（`srv:user`）一致：校准结果按
    /// `server.profile.id` 落进 store，对不上就是一次静默的空操作。
    private func profileWithAvatarTag(_ tag: String) -> ServerProfile {
        ServerProfile(id: "srv:user", serverName: "nas",
                      baseURL: URL(string: "http://stub.local:8096")!,
                      userID: "user", primaryImageTag: tag)
    }

    private static func syntheticPNGImage(size: CGSize) -> PlatformImage {
        let data = syntheticPNG(size: size)
        #if canImport(UIKit)
        return UIImage(data: data)!
        #else
        return NSImage(data: data)!
        #endif
    }
}

/// 取图请求的记录（`MockURLProtocol.handler` 跑在 URLSession 的后台线程上）。
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    func append(_ url: String) {
        lock.lock(); urls.append(url); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return urls.count
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}
