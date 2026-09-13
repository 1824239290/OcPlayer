import XCTest
@testable import DanmakuKit

/// 片头提示的持久化与 payload 带出链路。
final class DanmakuIntroHintFlowTests: XCTestCase {

    // MARK: 缓存层

    func testIntroHintPersistsAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-intro-hint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DanmakuCache(directory: directory)
        let absent = await cache.introHint(for: 7)
        XCTAssertNil(absent)
        let hint = DanmakuIntroHint(startSeconds: 98, endSeconds: 198, evidenceCount: 12)
        await cache.setIntroHint(hint, for: 7)

        let reopened = DanmakuCache(directory: directory)
        let stored = await reopened.introHint(for: 7)
        XCTAssertEqual(stored, hint)
        // 其它 episode 不受影响。
        let other = await reopened.introHint(for: 8)
        XCTAssertNil(other)
    }

    func testCorruptIntroHintFileIsRegenerated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-intro-hint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DanmakuCache(directory: directory)
        await cache.setIntroHint(
            DanmakuIntroHint(startSeconds: nil, endSeconds: 95, evidenceCount: 4), for: 9)
        try "not-json".write(
            to: directory.appendingPathComponent("intro-hints.json"), atomically: true, encoding: .utf8)

        // 提示可由弹幕正文随时重算：损坏文件按空处理并允许覆盖，不抛错不卡死。
        let recovered = DanmakuCache(directory: directory)
        let afterCorruption = await recovered.introHint(for: 9)
        XCTAssertNil(afterCorruption)
        let hint = DanmakuIntroHint(startSeconds: nil, endSeconds: 95, evidenceCount: 4)
        await recovered.setIntroHint(hint, for: 9)
        let regenerated = await recovered.introHint(for: 9)
        XCTAssertEqual(regenerated, hint)
    }

    // MARK: Service 链路

    func testPayloadDetectsAndPersistsIntroHint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-intro-hint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = DanmakuGatewayClient(
            configuration: DandanplayConfiguration(
                baseURL: URL(string: "https://gateway.example.com")!,
                apiKey: "key",
                userAgent: "OcPlay/0.1.3 (macOS; arm64)"
            ),
            session: TestSupport.mockedSession()
        )
        let service = DanmakuService(cache: DanmakuCache(directory: directory))
        let commentsJSON = """
        {"count":3,"comments":[
          {"cid":1,"p":"40.5,1,16777215,u","m":"跳伞02:12"},
          {"cid":2,"p":"44.2,1,16777215,u","m":"跳伞02:13"},
          {"cid":3,"p":"131.5,1,16777215,u","m":"空降成功"}
        ]}
        """

        try await TestSupport.withMock({ request in
            guard request.url?.path == "/v1/comments/7" else {
                throw URLError(.unsupportedURL)
            }
            return TestSupport.response(commentsJSON, url: request.url!)
        }) {
            let match = DanmakuEpisodeMatch(episodeID: 7)
            let payload = try await service.payload(for: match, client: client)
            XCTAssertEqual(payload.introHint?.endSeconds, 133)
        }

        // 提示已永久落盘；正文 TTL 未过期时连网关都不用回源，提示照常带出
        // （正文过期重拉后同理，提示不随正文失效）。
        let reopened = DanmakuService(cache: DanmakuCache(directory: directory))
        let cached = await reopened.cachedIntroHint(for: 7)
        XCTAssertEqual(cached?.endSeconds, 133)
        try await TestSupport.withMock({ request in
            guard request.url?.path == "/v1/comments/7" else {
                throw URLError(.unsupportedURL)
            }
            return TestSupport.response(#"{"count":0,"comments":[]}"#, url: request.url!)
        }) {
            let payload = try await reopened.payload(
                for: DanmakuEpisodeMatch(episodeID: 7), client: client)
            XCTAssertEqual(payload.commentCount, 3)
            XCTAssertEqual(payload.introHint?.endSeconds, 133)
        }
    }

    func testPayloadWithoutSignalsCarriesNoHint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-intro-hint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = DanmakuGatewayClient(
            configuration: DandanplayConfiguration(
                baseURL: URL(string: "https://gateway.example.com")!,
                apiKey: "key",
                userAgent: "OcPlay/0.1.3 (macOS; arm64)"
            ),
            session: TestSupport.mockedSession()
        )
        let service = DanmakuService(cache: DanmakuCache(directory: directory))

        try await TestSupport.withMock({ request in
            guard request.url?.path == "/v1/comments/8" else {
                throw URLError(.unsupportedURL)
            }
            return TestSupport.response(
                #"{"count":1,"comments":[{"cid":1,"p":"90,1,16777215,u","m":"OP好听"}]}"#,
                url: request.url!)
        }) {
            let payload = try await service.payload(
                for: DanmakuEpisodeMatch(episodeID: 8), client: client)
            XCTAssertNil(payload.introHint)
        }
        let nonePersisted = await service.cachedIntroHint(for: 8)
        XCTAssertNil(nonePersisted)
    }
}
