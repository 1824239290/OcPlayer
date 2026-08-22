import XCTest
@testable import MoviePilotKit

/// 登录 / 静默重登 / 请求头安全 的离线测试（URLProtocol mock）。
final class MoviePilotClientTests: XCTestCase {

    private var store: MoviePilotStore!
    private var client: MoviePilotAPIClient!
    /// 按序记录收到的请求路径，供断言重登 / 重放顺序。
    private var receivedPaths: [String] = []

    override func setUp() {
        super.setUp()
        receivedPaths = []
        store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        client = MoviePilotAPIClient(
            store: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()
        )
        store.updateCredentials(
            serverURLString: "http://192.168.1.10:3000",
            username: "admin",
            password: "secret"
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func configuredStore() -> MoviePilotStore { store }

    // MARK: - 登录

    func testLoginSendsFormAndFetchesUser() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path)
            switch url.path {
            case "/api/v1/login/access-token":
                let body = String(data: TestSupport.body(of: request) ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("username=admin"), "登录必须是 form 表单：\(body)")
                XCTAssertTrue(body.contains("password=secret"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                             "登录请求不该带旧 token")
                return MockURLProtocol.response(
                    #"{"access_token":"jwt-1","token_type":"bearer"}"#, status: 200, for: url)
            case "/api/v1/user/current":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-1")
                return MockURLProtocol.response(
                    #"{"id":1,"name":"admin","is_superuser":true,"is_active":true}"#,
                    status: 200, for: url)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        let user = try await client.login()
        XCTAssertEqual(user.name, "admin")
        XCTAssertEqual(user.isSuperuser, true)
        XCTAssertEqual(store.accessToken, "jwt-1")
        XCTAssertEqual(receivedPaths, ["/api/v1/login/access-token", "/api/v1/user/current"])
    }

    func testLoginWrongPasswordMapsToRequireLogin() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return MockURLProtocol.response(
                #"{"detail":"用户名或密码不正确"}"#, status: 400, for: url)
        }

        do {
            _ = try await client.login()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            XCTAssertEqual(error.userMessage, "请求参数有误，请检查后重试")
        }
        XCTAssertNil(store.accessToken, "登录失败不该留下 token")
    }

    func testNotConfiguredWithoutServer() async throws {
        let emptyStore = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        let emptyClient = MoviePilotAPIClient(
            store: emptyStore,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()
        )
        do {
            _ = try await emptyClient.login()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            XCTAssertEqual(error.userMessage, MoviePilotError.notConfigured.userMessage)
        }
    }

    // MARK: - 401 静默重登

    func testAuthorized401TriggersSilentReloginAndReplay() async throws {
        store.accessToken = "expired-token"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path + " auth=\(request.value(forHTTPHeaderField: "Authorization") ?? "nil")")
            switch url.path {
            case "/api/v1/user/current":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token" {
                    return MockURLProtocol.response(#"{"detail":"Not authenticated"}"#, status: 401, for: url)
                }
                return MockURLProtocol.response(
                    #"{"id":1,"name":"admin"}"#, status: 200, for: url)
            case "/api/v1/login/access-token":
                return MockURLProtocol.response(
                    #"{"access_token":"jwt-2","token_type":"bearer"}"#, status: 200, for: url)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        let user = try await client.currentUser()
        XCTAssertEqual(user.name, "admin")
        XCTAssertEqual(store.accessToken, "jwt-2")
        XCTAssertEqual(receivedPaths.count, 3, "旧 token 401 → 重登 → 新 token 重放：\(receivedPaths)")
    }

    func testReloginFailureBroadcastsAndClearsToken() async throws {
        store.accessToken = "expired-token"
        let notificationExpectation = expectation(
            forNotification: MoviePilotAPIClient.authenticationRequiredNotification,
            object: nil
        )

        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/user/current":
                return MockURLProtocol.response(#"{"detail":"Not authenticated"}"#, status: 401, for: url)
            case "/api/v1/login/access-token":
                // 密码已被改掉。
                return MockURLProtocol.response(
                    #"{"detail":"用户名或密码不正确"}"#, status: 400, for: url)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        do {
            _ = try await client.currentUser()
            XCTFail("应该抛错")
        } catch is MoviePilotError {
            // 具体是 requireLogin
        } catch {
            XCTFail("应该是 MoviePilotError：\(error)")
        }
        XCTAssertNil(store.accessToken, "重登失败必须清掉死 token")
        await fulfillment(of: [notificationExpectation], timeout: 2)
    }

    func testReloginNetworkErrorKeepsTokenAndThrowsNetwork() async throws {
        store.accessToken = "maybe-still-valid"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/user/current":
                return MockURLProtocol.response(#"{"detail":"Not authenticated"}"#, status: 401, for: url)
            case "/api/v1/login/access-token":
                throw URLError(.cannotConnectToHost)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        do {
            _ = try await client.currentUser()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            guard case .network = error else {
                XCTFail("应该是网络错误：\(error)")
                return
            }
        }
        // 网络故障只是暂时连不上：token 不动，下次请求还能再试。
        XCTAssertEqual(store.accessToken, "maybe-still-valid")
    }

    // MARK: - 安全

    func testTokenNeverAppearsInURL() async throws {
        store.accessToken = "jwt-secret-value"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertFalse(
                url.absoluteString.contains("jwt-secret-value"),
                "token 绝不进 URL：\(url.absoluteString)"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-secret-value")
            return MockURLProtocol.response(
                #"{"id":1,"name":"admin"}"#, status: 200, for: url)
        }
        _ = try await client.currentUser()
    }

    func testSignOutClearsSession() async throws {
        store.accessToken = "jwt-1"
        _ = await client.signOut()
        XCTAssertNil(store.accessToken)
        XCTAssertEqual(store.password, "")
        let generation = await client.currentGeneration()
        let stillCurrent = await client.isCurrentGeneration(generation)
        XCTAssertTrue(stillCurrent)
    }
}
