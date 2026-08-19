import XCTest
@testable import DanmakuKit

final class GatewayClientTests: XCTestCase {

    private let baseURL = URL(string: "https://gateway.example.com")!
    private let apiKey = "test-key-123"
    private let userAgent = "OcPlay/0.1.1 (macOS; arm64)"
    private let validHash = "900150983cd24fb0d6963f7d28e17f72"

    private func makeClient(
        session: URLSession,
        baseURL: URL = URL(string: "https://gateway.example.com")!
    ) -> DanmakuGatewayClient {
        DanmakuGatewayClient(
            configuration: DandanplayConfiguration(baseURL: baseURL, apiKey: apiKey, userAgent: userAgent),
            session: session
        )
    }

    // MARK: match

    func testMatchSentAndDecoded() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":true,
         "matches":[{"episodeId":123456789,"animeTitle":"葬送的芙莉莲","episodeTitle":"第1话"}]}
        """
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/match")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), self.apiKey)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), self.userAgent)
            let data = TestSupport.body(of: request)
            let json = try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            XCTAssertEqual(json?["fileName"] as? String, "葬送的芙莉莲 01")
            XCTAssertEqual(json?["fileHash"] as? String, self.validHash)
            return TestSupport.response(body, url: request.url!, cache: "MISS")
        }) {
            let result = try await client.match(MatchRequest(
                fileName: "葬送的芙莉莲 01",
                fileHash: validHash,
                fileSize: 734003200,
                videoDuration: 1440,
                matchMode: .fileNameOnly
            ))
            XCTAssertEqual(result.cacheStatus, "MISS")
            XCTAssertTrue(result.payload.success)
            XCTAssertEqual(result.payload.matches.first?.episodeId, 123456789)
        }
    }

    func testMatchBusinessError() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":false,"errorCode":1001,"errorMessage":"internal error"}
        """
        try await TestSupport.withMock({ request in
            return TestSupport.response(body, url: request.url!)
        }) {
            do {
                _ = try await client.match(MatchRequest(
                    fileHash: validHash,
                    matchMode: .hashOnly
                ))
                XCTFail("should throw")
            } catch let DandanplayError.businessError(code, msg) {
                XCTAssertEqual(code, 1001)
                XCTAssertEqual(msg, "internal error")
            }
        }
    }

    func testMatchRejectsInvalidInputsBeforeNetwork() async {
        let client = makeClient(session: TestSupport.mockedSession())
        let invalid: [MatchRequest] = [
            MatchRequest(),
            MatchRequest(fileHash: "not-md5", matchMode: .hashOnly),
            MatchRequest(fileHash: String(repeating: "ａ", count: 32), matchMode: .hashOnly),
            MatchRequest(fileHash: validHash, fileSize: -1, matchMode: .hashOnly),
            MatchRequest(fileHash: validHash, videoDuration: 0, matchMode: .hashOnly),
            MatchRequest(fileName: "x", matchMode: .hashAndFileName),
            MatchRequest(fileHash: validHash, matchMode: .hashAndFileName),
            MatchRequest(fileHash: validHash, matchMode: .fileNameOnly),
        ]
        for request in invalid {
            do {
                _ = try await client.match(request)
                XCTFail("should reject \(request)")
            } catch DandanplayError.invalidRequest {
                // expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMatchWithoutHashIsRejectedBeforeNetwork() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ request in
            XCTFail("network should not be reached: \(request)")
            throw URLError(.unsupportedURL)
        }) {
            do {
                _ = try await client.match(MatchRequest(
                    fileName: "episode",
                    matchMode: .fileNameOnly
                ))
                XCTFail("should reject before network")
            } catch DandanplayError.invalidRequest {
                // expected
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: searchAnime

    func testSearchAnimeQueryAndDecoded() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":true,"errorCode":0,
         "animes":[{"animeId":1,"animeTitle":"葬送的芙莉莲","type":"tvseries"}]}
        """
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/search/anime")
            XCTAssertEqual(TestSupport.queryItems(of: request)["keyword"], "芙莉莲")
            return TestSupport.response(body, url: request.url!, cache: "HIT")
        }) {
            let result = try await client.searchAnime(keyword: "芙莉莲")
            XCTAssertEqual(result.cacheStatus, "HIT")
            XCTAssertEqual(result.payload.animes.first?.animeTitle, "葬送的芙莉莲")
        }
    }

    // MARK: searchEpisodes

    func testSearchEpisodesQueryAndDecoded() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":true,"errorCode":0,
         "animes":[{"animeId":1,"animeTitle":"芙莉莲",
         "episodes":[{"episodeId":42,"episodeTitle":"第1话"}]}]}
        """
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.url?.path, "/v1/search/episodes")
            let q = TestSupport.queryItems(of: request)
            XCTAssertEqual(q["anime"], "芙莉莲")
            XCTAssertEqual(q["episode"], "1")
            return TestSupport.response(body, url: request.url!)
        }) {
            let result = try await client.searchEpisodes(anime: "芙莉莲", episode: "1")
            XCTAssertEqual(result.payload.animes.first?.episodes.first?.episodeId, 42)
        }
    }

    func testSearchEpisodesRequiresParams() async {
        let client = makeClient(session: TestSupport.mockedSession())
        do {
            _ = try await client.searchEpisodes(anime: nil, tmdbId: nil)
            XCTFail("should throw")
        } catch DandanplayError.invalidRequest {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSearchEpisodesSupportsTMDBQuery() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":true,"errorCode":0,"animes":[]}
        """
        try await TestSupport.withMock({ request in
            let q = TestSupport.queryItems(of: request)
            XCTAssertEqual(q["tmdbId"], "123")
            XCTAssertEqual(q["tmdbIdType"], "1")
            XCTAssertEqual(q["episode"], "2")
            return TestSupport.response(body, url: request.url!)
        }) {
            _ = try await client.searchEpisodes(tmdbId: 123, tmdbIdType: 1, episode: "2")
        }
    }

    func testBaseURLWithQueryIsRejected() async {
        let client = makeClient(
            session: TestSupport.mockedSession(),
            baseURL: URL(string: "https://gateway.example.com/?api_key=secret")!
        )
        do {
            _ = try await client.comments(episodeId: 1)
            XCTFail("should throw")
        } catch DandanplayError.invalidRequest {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: comments

    func testCommentsPathAndDefaults() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"count":2,"comments":[
          {"cid":1,"p":"0.5,1,16777215,u","m":"first"},
          {"cid":2,"p":"1.0,5,16711680,u","m":"second"}]}
        """
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.url?.path, "/v1/comments/100")
            let q = TestSupport.queryItems(of: request)
            XCTAssertEqual(q["withRelated"], "true")
            XCTAssertEqual(q["chConvert"], "0")
            return TestSupport.response(body, url: request.url!, cache: "HIT")
        }) {
            let result = try await client.comments(episodeId: 100)
            XCTAssertEqual(result.payload.count, 2)
            XCTAssertEqual(result.payload.comments?.count, 2)
            XCTAssertEqual(result.payload.comments?.first?.m, "first")
        }
    }

    func testCommentsNullArrayAllowed() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"count":0,"comments":null}
        """
        try await TestSupport.withMock({ request in
            return TestSupport.response(body, url: request.url!)
        }) {
            let result = try await client.comments(episodeId: 999)
            XCTAssertEqual(result.payload.count, 0)
            XCTAssertNil(result.payload.comments)
        }
    }

    func testCommentsCountDefaultsFromArray() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"comments":[{"cid":1,"p":"0.5,1,16777215,u","m":"first"}]}
        """
        try await TestSupport.withMock({ request in
            return TestSupport.response(body, url: request.url!)
        }) {
            let result = try await client.comments(episodeId: 100)
            XCTAssertEqual(result.payload.count, 1)
        }
    }

    // MARK: HTTP 错误

    func testUnauthorized() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ request in
            return TestSupport.response("{\"errorCode\":401}", status: 401, url: request.url!)
        }) {
            do {
                _ = try await client.comments(episodeId: 1)
                XCTFail("should throw")
            } catch DandanplayError.unauthorized {
                // expected
            }
        }
    }

    func testRateLimited() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ request in
            return TestSupport.response("{\"errorCode\":429}", status: 429, url: request.url!)
        }) {
            do {
                _ = try await client.comments(episodeId: 1)
                XCTFail("should throw")
            } catch DandanplayError.rateLimited {
                // expected
            }
        }
    }

    func testOtherHTTPStatus() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ request in
            return TestSupport.response("{}", status: 502, url: request.url!)
        }) {
            do {
                _ = try await client.comments(episodeId: 1)
                XCTFail("should throw")
            } catch DandanplayError.httpStatus(let code) {
                XCTAssertEqual(code, 502)
            }
        }
    }

    func testDecodingFailure() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ request in
            return TestSupport.response("{\"success\":true,\"errorCode\":0,\"garbage\":true}", url: request.url!)
        }) {
            do {
                _ = try await client.searchAnime(keyword: "x")
                XCTFail("should throw")
            } catch DandanplayError.decodingFailed {
                // expected
            }
        }
    }

    // MARK: 超时与用户文案

    func testTimedOutRequestMapsToNetworkUserMessage() async throws {
        // 回归：慢网关必须尽快失败（会话超时注入），且落到稳定的用户文案。
        let client = makeClient(session: TestSupport.mockedSession())
        try await TestSupport.withMock({ _ in
            throw URLError(.timedOut)
        }) {
            do {
                _ = try await client.searchAnime(keyword: "x")
                XCTFail("should throw")
            } catch let error as DandanplayError {
                guard case .network = error else {
                    return XCTFail("expected network error, got \(error)")
                }
                XCTAssertEqual(error.userMessage, "弹幕网络请求失败")
            }
        }
    }

    func testBusinessErrorUserMessagePassesServerTextThrough() async throws {
        let client = makeClient(session: TestSupport.mockedSession())
        let body = """
        {"success":false,"errorCode":1002,"errorMessage":"参数缺失"}
        """
        try await TestSupport.withMock({ request in
            return TestSupport.response(body, url: request.url!)
        }) {
            do {
                _ = try await client.match(MatchRequest(
                    fileName: "x",
                    fileHash: self.validHash,
                    matchMode: .fileNameOnly
                ))
                XCTFail("should throw")
            } catch let error as DandanplayError {
                guard case .businessError(_, let message) = error else {
                    return XCTFail("expected businessError, got \(error)")
                }
                XCTAssertEqual(message, "参数缺失")
                XCTAssertEqual(error.userMessage, "参数缺失")
            }
        }
    }
}
