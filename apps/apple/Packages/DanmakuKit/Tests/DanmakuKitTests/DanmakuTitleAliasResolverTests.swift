import XCTest
@testable import DanmakuKit

/// 标题别名解析：正缓存永久有效、负缓存 7 天过期、失败静默降级。
final class DanmakuTitleAliasResolverTests: XCTestCase {

    /// 可控时钟（`now` 闭包要 Sendable，所以用引用类型包一层）。
    private final class MutableClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// 记录调用次数的假别名来源。
    private actor FakeProvider: DanmakuTitleAliasProviding {
        private(set) var calls: [String] = []
        private var result: [String]

        init(result: [String]) { self.result = result }

        func setResult(_ value: [String]) { result = value }

        func aliases(for title: String) async -> [String] {
            calls.append(title)
            return result
        }
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testResolvesAndCachesPermanently() async {
        let provider = FakeProvider(result: ["败犬女主太多了！", "負けヒロインが多すぎる！"])
        let clock = MutableClock(Date())
        let resolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: makeTempDirectory()),
            provider: provider,
            now: { clock.now }
        )

        let first = await resolver.aliases(for: "Makeine")
        XCTAssertEqual(first, ["败犬女主太多了！", "負けヒロインが多すぎる！"])
        let firstCalls = await provider.calls
        XCTAssertEqual(firstCalls, ["Makeine"])

        // 正缓存永久有效：一年后再问也不重新解析。
        clock.now = clock.now.addingTimeInterval(365 * 24 * 3600)
        let second = await resolver.aliases(for: "Makeine")
        XCTAssertEqual(second, first)
        let callsAfterAYear = await provider.calls
        XCTAssertEqual(callsAfterAYear.count, 1, "正缓存应永久有效")
    }

    func testNegativeCacheExpiresAfterAWeek() async {
        let provider = FakeProvider(result: [])
        let clock = MutableClock(Date())
        let resolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: makeTempDirectory()),
            provider: provider,
            now: { clock.now }
        )

        let missing = await resolver.aliases(for: "某部还没被收录的新番")
        XCTAssertEqual(missing, [])
        let initialCalls = await provider.calls
        XCTAssertEqual(initialCalls.count, 1)

        // 6 天后不重试，8 天后重试（新番可能后来才被收录）。
        clock.now = clock.now.addingTimeInterval(6 * 24 * 3600)
        _ = await resolver.aliases(for: "某部还没被收录的新番")
        let callsWithinWeek = await provider.calls
        XCTAssertEqual(callsWithinWeek.count, 1, "负缓存 7 天内不重试")

        clock.now = clock.now.addingTimeInterval(2 * 24 * 3600)
        await provider.setResult(["新番中文名"])
        let retried = await resolver.aliases(for: "某部还没被收录的新番")
        XCTAssertEqual(retried, ["新番中文名"])
        let callsAfterExpiry = await provider.calls
        XCTAssertEqual(callsAfterExpiry.count, 2, "负缓存过期后应重试")
    }

    func testCacheKeyIgnoresPunctuationAndWidth() async {
        let provider = FakeProvider(result: ["中文名"])
        let resolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: makeTempDirectory()),
            provider: provider
        )

        _ = await resolver.aliases(for: "Re：从零开始的异世界生活")
        _ = await resolver.aliases(for: "re: 从零开始的异世界生活")
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "全角/大小写/标点差异应命中同一缓存键")
    }

    func testEmptyTitleSkipsProvider() async {
        let provider = FakeProvider(result: ["不该被用到"])
        let resolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: makeTempDirectory()),
            provider: provider
        )

        let result = await resolver.aliases(for: "   ")
        XCTAssertEqual(result, [])
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCacheSurvivesStoreReopen() async {
        let directory = makeTempDirectory()
        let provider = FakeProvider(result: ["中文名"])
        let resolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: directory),
            provider: provider
        )
        _ = await resolver.aliases(for: "Makeine")

        // 换一个 store 实例（模拟重启）：应直接从 title-aliases.json 命中。
        let reopened = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: directory),
            provider: provider
        )
        let result = await reopened.aliases(for: "Makeine")
        XCTAssertEqual(result, ["中文名"])
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
    }
}
