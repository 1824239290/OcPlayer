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
                // v3 的 ResponseAPIRouter 自动信封：用户对象在 data 里。
                return MockURLProtocol.response(
                    #"{"success":true,"message":"","data":{"id":1,"name":"admin","is_superuser":true,"is_active":true}}"#,
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
            XCTAssertEqual(error.userMessage, "用户名或密码不正确")
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

    func testReloginTokenStill401TripsBreakerClearsAndBroadcasts() async throws {
        // 场景 B：重登换到新 token 但仍被 401（JWT secret 被换 / 账号被停）。
        // 第一次失败发生在重放层（熔断未触发，token 保留）；第二次再撞 401 时
        // 入口熔断命中，必须清 token + 广播，且不再发带密码的 login。
        store.accessToken = "expired-token"
        let notificationExpectation = expectation(
            forNotification: MoviePilotAPIClient.authenticationRequiredNotification,
            object: nil
        )

        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path)
            switch url.path {
            case "/api/v1/user/current":
                // 新旧 token 一律 401。
                return MockURLProtocol.response(#"{"detail":"Not authenticated"}"#, status: 401, for: url)
            case "/api/v1/login/access-token":
                return MockURLProtocol.response(
                    #"{"access_token":"jwt-2","token_type":"bearer"}"#, status: 200, for: url)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        do {
            _ = try await client.currentUser()
            XCTFail("第一次调用应该抛 requireLogin")
        } catch let error as MoviePilotError {
            if case .requireLogin = error {} else {
                XCTFail("应该是 requireLogin：\(error)")
            }
        } catch {
            XCTFail("应该是 MoviePilotError：\(error)")
        }
        XCTAssertEqual(store.accessToken, "jwt-2", "第一次失败在重放层，熔断未触发，刚换的 token 应保留")
        XCTAssertEqual(receivedPaths.count, 3, "旧 token 401 → 重登 → 新 token 重放 401：\(receivedPaths)")

        do {
            _ = try await client.currentUser()
            XCTFail("第二次调用应该抛 requireLogin")
        } catch let error as MoviePilotError {
            if case .requireLogin = error {} else {
                XCTFail("应该是 requireLogin：\(error)")
            }
        } catch {
            XCTFail("应该是 MoviePilotError：\(error)")
        }
        XCTAssertNil(store.accessToken, "熔断分支必须清掉作废 token")
        XCTAssertEqual(receivedPaths.count, 4, "第二次只有一次 401，熔断短路不再重登：\(receivedPaths)")
        let loginCount = receivedPaths.filter { $0 == "/api/v1/login/access-token" }.count
        XCTAssertEqual(loginCount, 1, "熔断命中不该再发带密码的 login")
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

    func testReloginRetryableNetworkErrorDoesNotReplayStaleToken() async throws {
        // 重登本身遇到**可重试**网络错（超时/断网）时，旧 token 已经被拒过了：
        // 修复前会把重登失败当成请求瞬态失败 `continue`，下一轮又揣着同一个旧 token
        // 再撞一次 401、再触发一轮带密码的 login。login 的重试预算在 postLogin→send
        // 内部就已经跑完（3 次），外层不该再替它重试。
        store.accessToken = "expired-token"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path)
            switch url.path {
            case "/api/v1/user/current":
                return MockURLProtocol.response(#"{"detail":"Not authenticated"}"#, status: 401, for: url)
            case "/api/v1/login/access-token":
                throw URLError(.timedOut)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        do {
            _ = try await client.currentUser()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            guard case .network(let failure, _) = error, failure == .timedOut else {
                XCTFail("应该是网络超时：\(error)")
                return
            }
        }
        XCTAssertEqual(store.accessToken, "expired-token", "网络故障不是凭据问题，token 照旧保留")
        XCTAssertEqual(
            receivedPaths,
            ["/api/v1/user/current"] + Array(repeating: "/api/v1/login/access-token", count: 3),
            "旧 token 只发一次；login 在自己预算内重试 3 次后直接抛：\(receivedPaths)")
    }

    // MARK: - 403 过期 token（信封错误体）

    func testExpiredToken403WithEnvelopeTriggersSilentReloginAndReplay() async throws {
        // MoviePilot 对过期 JWT 回的是 403 + 自家信封（不是 401，也不是 FastAPI
        // 的 {"detail":...}）：必须与 401 同口径走静默重登自愈，而不是把原始
        // JSON 当 forbidden 抛给 UI 反复无效重试。
        store.accessToken = "expired-token"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path)
            switch url.path {
            case "/api/v1/user/current":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token" {
                    return MockURLProtocol.response(
                        #"{"success":false,"message":"token 校验不通过","data":null}"#, status: 403, for: url)
                }
                return MockURLProtocol.response(#"{"id":1,"name":"admin"}"#, status: 200, for: url)
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
        XCTAssertEqual(
            receivedPaths,
            ["/api/v1/user/current", "/api/v1/login/access-token", "/api/v1/user/current"],
            "403 过期 token → 静默重登 → 新 token 重放：\(receivedPaths)")
    }

    func test403WithoutTokenMessageStaysForbiddenWithoutRelogin() async throws {
        // 站点权限类的普通 403 不能被误伤成 requireLogin 触发重登。
        store.accessToken = "jwt-valid"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.receivedPaths.append(url.path)
            return MockURLProtocol.response(
                #"{"success":false,"message":"没有权限执行此操作","data":null}"#, status: 403, for: url)
        }

        do {
            _ = try await client.currentUser()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            guard case .forbidden(let message) = error else {
                XCTFail("应该是 forbidden：\(error)")
                return
            }
            XCTAssertEqual(message, "没有权限执行此操作")
        }
        XCTAssertEqual(store.accessToken, "jwt-valid", "普通 403 不动 token")
        XCTAssertEqual(receivedPaths.count, 1, "普通 403 不触发重登")
    }

    func testEnvelopeErrorMessageExtractedInsteadOfRawJSON() async throws {
        // 错误文案取信封的 message，不再把整包 JSON 甩给 UI。
        store.accessToken = "jwt-valid"
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return MockURLProtocol.response(
                #"{"success":false,"message":"订阅不存在","data":null}"#, status: 400, for: url)
        }

        do {
            _ = try await client.currentUser()
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            XCTAssertEqual(error.userMessage, "订阅不存在")
        }
    }

    func testTokenFailureClassificationContract() {
        // 分类纯函数的契约：token 措辞命中，权限/密码措辞不命中；裸信封文本
        // （detail 解不出时的 bodyText 兜底路径）也能命中。
        XCTAssertTrue(MoviePilotError.isTokenVerificationMessage("token 校验不通过"))
        XCTAssertTrue(MoviePilotError.isTokenVerificationMessage("token校验不通过"))
        XCTAssertTrue(MoviePilotError.isTokenVerificationMessage("Token 已过期"))
        XCTAssertTrue(
            MoviePilotError.isTokenVerificationMessage(
                #"{"success":false,"message":"token 校验不通过","data":null}"#))
        XCTAssertFalse(MoviePilotError.isTokenVerificationMessage("没有权限执行此操作"))
        XCTAssertFalse(MoviePilotError.isTokenVerificationMessage("用户名或密码不正确"))

        // 403 + token 文案 → requireLogin；普通 403 仍是 forbidden。
        if case .requireLogin = MoviePilotError(code: 403, response: "token 校验不通过") {} else {
            XCTFail("403 + token 文案应该归为 requireLogin")
        }
        if case .forbidden = MoviePilotError(code: 403, response: "没有权限") {} else {
            XCTFail("普通 403 应该是 forbidden")
        }
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

    func testRetryable502RetriesAndSucceeds() async throws {
        store.accessToken = "jwt-valid"
        var attempts = 0
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            attempts += 1
            if attempts == 1 {
                return MockURLProtocol.response(
                    #"{"detail":"Bad Gateway"}"#, status: 502, for: url)
            } else {
                return MockURLProtocol.response(
                    #"{"id":1,"name":"admin","is_superuser":true,"is_active":true}"#, status: 200, for: url)
            }
        }
        let user = try await client.currentUser()
        XCTAssertEqual(user.name, "admin")
        XCTAssertEqual(attempts, 2)
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
