import Foundation
import XCTest

import DiagnosticsKit
@testable import AppDesignKit

/// 图片缓存从 `Application Support` 搬到 `Caches` 时的一次性旧目录清理。
///
/// 这里是整个搬迁里唯一危险的一段：一条 `removeItem`。判据写错就是删掉用户真正的
/// 缓存目录，所以四道闸门逐条正反向钉死；另外「只做一次」也要钉 —— 每次启动都清
/// 等于没有缓存（与同文件另两个迁移同一条理由）。
final class ImagePipelineLegacyCacheTests: XCTestCase {

    private var sandbox: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        suiteName = "dev.jumusu.OcPlayer.legacyCacheTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 旧布局：`<sandbox>/OcPlayer/ImageCache`（等价于生产里的
    /// `Application Support/OcPlayer/ImageCache`）。
    private func makeLegacyLayout() -> (root: URL, legacy: URL, current: URL) {
        let root = sandbox.appendingPathComponent("OcPlayer", isDirectory: true)
        let legacy = root.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let current = sandbox.appendingPathComponent("Caches/OcPlayer/ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        return (root, legacy, current)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 判据：该删

    func testRemovesLegacyDirectoryUnderDataRoot() {
        let (root, legacy, current) = makeLegacyLayout()
        XCTAssertTrue(ImagePipeline.shouldRemoveLegacyImageCache(
            legacy: legacy, current: current, root: root))
    }

    // MARK: - 判据：不该删（四道闸门逐条反证）

    /// 闸门 1：末段不是 `ImageCache` —— 防别的路径被误传进来。
    func testRefusesWhenLastComponentIsNotImageCache() {
        let (root, _, current) = makeLegacyLayout()
        let other = root.appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertFalse(ImagePipeline.shouldRemoveLegacyImageCache(
            legacy: other, current: current, root: root))
    }

    /// 闸门 2：父目录不是数据根 —— 限定删除范围，不许伸到别处。
    func testRefusesWhenParentIsNotTheDataRoot() {
        let (_, legacy, current) = makeLegacyLayout()
        let wrongRoot = sandbox.appendingPathComponent("SomewhereElse", isDirectory: true)
        XCTAssertFalse(ImagePipeline.shouldRemoveLegacyImageCache(
            legacy: legacy, current: current, root: wrongRoot))
    }

    /// 闸门 3：`legacy == current` —— 参数写反时**不能把新目录删掉**。
    /// 这是最要命的一种写错，单列一条。
    func testRefusesWhenLegacyEqualsCurrent() {
        let (root, legacy, _) = makeLegacyLayout()
        XCTAssertFalse(ImagePipeline.shouldRemoveLegacyImageCache(
            legacy: legacy, current: legacy, root: root))
    }

    /// 闸门 4：目标不存在（= 新装用户）—— 不动，也让「跑两次」天然幂等。
    func testRefusesWhenTargetMissing() {
        let (root, legacy, current) = makeLegacyLayout()
        try? FileManager.default.removeItem(at: legacy)
        XCTAssertFalse(ImagePipeline.shouldRemoveLegacyImageCache(
            legacy: legacy, current: current, root: root))
    }

    // MARK: - 端到端：真的删，且只删一次，且不碰新目录

    func testPurgeRemovesLegacyAndLeavesCurrentAlone() {
        let (root, legacy, current) = makeLegacyLayout()
        // 旧目录里放点东西，确认是连内容一起清掉
        try? Data("stale".utf8).write(to: legacy.appendingPathComponent("Cache.db"))
        try? Data("fresh".utf8).write(to: current.appendingPathComponent("Cache.db"))

        ImagePipeline.purgeLegacyImageCacheIfNeeded(
            legacy: legacy, current: current, defaults: defaults, root: root)

        XCTAssertFalse(exists(legacy), "旧目录该被删掉")
        XCTAssertTrue(exists(current.appendingPathComponent("Cache.db")), "新目录必须原封不动")
    }

    /// 标记已置位 ⇒ 第二次不再动手。用「重建同名旧目录」来观察，否则第二次本来也没得删。
    func testPurgeRunsOnlyOnce() {
        let (root, legacy, current) = makeLegacyLayout()
        ImagePipeline.purgeLegacyImageCacheIfNeeded(
            legacy: legacy, current: current, defaults: defaults, root: root)
        XCTAssertFalse(exists(legacy))

        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        ImagePipeline.purgeLegacyImageCacheIfNeeded(
            legacy: legacy, current: current, defaults: defaults, root: root)
        XCTAssertTrue(exists(legacy), "标记已置位，第二次不该再删")
    }

    /// 判据拒绝时，标记照样落 —— 与同文件另两个迁移同口径（只尝试一次）。
    func testRefusedPurgeStillMarksSoItDoesNotRetryEveryLaunch() {
        let (root, legacy, current) = makeLegacyLayout()
        let wrongRoot = sandbox.appendingPathComponent("SomewhereElse", isDirectory: true)
        ImagePipeline.purgeLegacyImageCacheIfNeeded(
            legacy: legacy, current: current, defaults: defaults, root: wrongRoot)
        XCTAssertTrue(exists(legacy), "父目录不对 ⇒ 不该删")
        XCTAssertTrue(defaults.bool(forKey: "dev.jumusu.ocplayer.imageCache.cachesRootV1"))
    }

    // MARK: - 绝不在测试进程里跑（真实事故的回护）

    /// 本进程就是测试进程。`ImageDecoderTests` 会读 `ImagePipeline.shared`
    /// （= 默认目录），如果迁移在测试里跑，`removeItem` 打的就是开发机真实的
    /// `Application Support/OcPlayer/ImageCache` —— 实测已经发生过一次（370 MB）。
    /// 这条用例把「测试进程一律不跑迁移」钉死，两个入参都必须是 false。
    func testOneTimeMigrationsNeverRunInsideTestProcesses() {
        XCTAssertTrue(RuntimeEnvironment.isRunningTests, "前提：本进程是测试进程")
        XCTAssertFalse(ImagePipeline.shouldRunOneTimeMigrations(cacheDirectory: nil),
                       "默认目录 + 测试进程 ⇒ 不许跑迁移")
        XCTAssertFalse(
            ImagePipeline.shouldRunOneTimeMigrations(
                cacheDirectory: sandbox.appendingPathComponent("injected", isDirectory: true)),
            "注入目录（测试用法）⇒ 不许跑迁移")
    }
}
