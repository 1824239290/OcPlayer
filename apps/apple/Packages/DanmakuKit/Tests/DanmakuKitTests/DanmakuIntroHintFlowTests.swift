import XCTest
@testable import DanmakuKit

/// 片头提示的数据流：弹幕检测（payload）→ 持久化（编排层决策）→ 存量解码兼容。
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

    // MARK: Service 层

    func testPayloadDetectsHintWithoutPersisting() async throws {
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
            // 检测归 payload（纯计算）；持久化时机归编排层。
            let payload = try await service.payload(for: DanmakuEpisodeMatch(episodeID: 7), client: client)
            XCTAssertEqual(payload.detectedIntroHint?.endSeconds, 133)
            XCTAssertEqual(payload.detectedIntroHint?.source, .danmaku)
        }
        let notPersisted = await service.cachedIntroHint(for: 7)
        XCTAssertNil(notPersisted)

        // 编排层显式持久化后可读回。
        let hint = DanmakuIntroHint(startSeconds: nil, endSeconds: 133, evidenceCount: 3)
        await service.persistIntroHint(hint, for: 7)
        let persisted = await service.cachedIntroHint(for: 7)
        XCTAssertEqual(persisted, hint)
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
            XCTAssertNil(payload.detectedIntroHint)
        }
        let nonePersisted = await service.cachedIntroHint(for: 8)
        XCTAssertNil(nonePersisted)
    }

    // MARK: 来源标注与存量兼容

    func testLegacyHintJSONDecodesWithDanmakuSource() throws {
        // 89fb9df 的存量 intro-hints.json 没有 source 字段。
        let legacy = #"{"startSeconds":98,"endSeconds":198,"evidenceCount":12}"#
        let hint = try JSONDecoder().decode(DanmakuIntroHint.self, from: Data(legacy.utf8))
        XCTAssertEqual(hint.source, .danmaku)
        XCTAssertEqual(hint.endSeconds, 198)

        // 新格式往返不丢来源。
        let aniskip = DanmakuIntroHint(startSeconds: 88, endSeconds: 178, evidenceCount: 1, source: .aniskip)
        let data = try JSONEncoder().encode(aniskip)
        let roundtrip = try JSONDecoder().decode(DanmakuIntroHint.self, from: data)
        XCTAssertEqual(roundtrip, aniskip)
    }
}
