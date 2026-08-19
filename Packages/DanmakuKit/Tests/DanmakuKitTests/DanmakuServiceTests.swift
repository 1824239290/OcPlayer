import XCTest
@testable import DanmakuKit

final class DanmakuServiceTests: XCTestCase {
    private let validHash = "900150983cd24fb0d6963f7d28e17f72"

    func testAutomaticMatchPersistsShiftAndCachesComments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TestSupport.mockedSession()
        let client = DanmakuGatewayClient(
            configuration: DandanplayConfiguration(
                baseURL: URL(string: "https://gateway.example.com")!,
                apiKey: "key",
                userAgent: "OcPlay/0.1.1 (macOS; arm64)"
            ),
            session: session
        )
        let service = DanmakuService(cache: DanmakuCache(directory: directory))

        try await TestSupport.withMock({ request in
            switch request.url?.path {
            case "/v1/match":
                return TestSupport.response(
                    #"{"success":true,"isMatched":true,"matches":[{"episodeId":7,"animeTitle":"作品","episodeTitle":"第 1 话","shift":-2}]}"#,
                    url: request.url!
                )
            case "/v1/comments/7":
                return TestSupport.response(
                    #"{"count":1,"comments":[{"cid":1,"p":"1,1,16777215,u","m":"hi"}]}"#,
                    url: request.url!
                )
            default:
                throw URLError(.unsupportedURL)
            }
        }) {
            let match = try await service.automaticMatch(
                cacheKey: "server:item:source",
                request: MatchRequest(
                    fileName: "episode",
                    fileHash: validHash,
                    matchMode: .fileNameOnly
                ),
                client: client
            )
            XCTAssertEqual(match?.shiftSeconds, -2)
            let payload = try await service.payload(for: XCTUnwrap(match), client: client)
            XCTAssertEqual(payload.commentCount, 1)
            XCTAssertNotNil(payload.json)
        }

        let reopened = DanmakuCache(directory: directory)
        let storedMatch = await reopened.episodeMatch(for: "server:item:source")
        let storedComments = await reopened.comments(for: 7)
        XCTAssertEqual(storedMatch?.shiftSeconds, -2)
        XCTAssertEqual(storedComments?.first?.m, "hi")
    }

    func testAutomaticMatchCanDeferPersistenceUntilCallerConfirmsGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = DanmakuGatewayClient(
            configuration: DandanplayConfiguration(
                baseURL: URL(string: "https://gateway.example.com")!,
                apiKey: "key",
                userAgent: "OcPlay/0.1.1 (macOS; arm64)"
            ),
            session: TestSupport.mockedSession()
        )
        let cache = DanmakuCache(directory: directory)
        let service = DanmakuService(cache: cache)

        try await TestSupport.withMock({ request in
            TestSupport.response(
                #"{"success":true,"isMatched":true,"matches":[{"episodeId":8,"shift":3}]}"#,
                url: request.url!
            )
        }) {
            let match = try await service.automaticMatch(
                cacheKey: "media",
                request: MatchRequest(
                    fileName: "episode",
                    fileHash: validHash,
                    matchMode: .fileNameOnly
                ),
                client: client,
                persistingResult: false
            )
            XCTAssertEqual(match?.episodeID, 8)
            let deferredValue = await cache.episodeMatch(for: "media")
            XCTAssertNil(deferredValue)

            let confirmed = try XCTUnwrap(match)
            await service.remember(match: confirmed, cacheKey: "media")
            let committedValue = await cache.episodeMatch(for: "media")
            XCTAssertEqual(committedValue?.shiftSeconds, 3)
        }
    }

    func testCachedMatchReturnsPersistedMappingWithoutGatewayWork() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = DanmakuService(cache: DanmakuCache(directory: directory))
        let expected = DanmakuEpisodeMatch(
            episodeID: 42,
            shiftSeconds: -1,
            animeTitle: "作品",
            episodeTitle: "第 1 话"
        )
        await service.remember(match: expected, cacheKey: "server:item:source")

        let cached = await service.cachedMatch(for: "server:item:source")
        let missing = await service.cachedMatch(for: "missing")

        XCTAssertEqual(cached, expected)
        XCTAssertNil(missing)
    }
}
