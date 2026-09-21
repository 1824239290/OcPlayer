import CoreModel
import XCTest
@testable import JellyfinKit

/// 登录入口的离线测试：地址归一化、探活定产品、宽松解析登录响应。
/// 网络全走 `MockURLProtocol`。
///
/// 这一层是两家唯一的汇聚点 —— 探活与登录响应解析走**裸传输**，所以这里同时
/// 覆盖 Jellyfin 与 Emby 两条路径。
final class MediaServerLoginTests: XCTestCase {

    private var store: ServerStore!

    override func setUp() {
        super.setUp()
        let suiteName = "MediaServerLoginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
    }

    // MARK: - 地址归一化

    func testNormalizeServerURL() throws {
        XCTAssertEqual(try MediaServerLogin.normalizeServerURL("192.168.1.10:8096").absoluteString,
                       "http://192.168.1.10:8096")
        XCTAssertEqual(try MediaServerLogin.normalizeServerURL(" https://nas.local/jellyfin/ ").absoluteString,
                       "https://nas.local/jellyfin")
        // 「localhost」这种不带端口的也行
        XCTAssertEqual(try MediaServerLogin.normalizeServerURL("localhost").absoluteString,
                       "http://localhost")
    }

    func testNormalizeServerURLRespectsPreferredScheme() throws {
        // 没手写前缀:用 preferredScheme 补。
        XCTAssertEqual(
            try MediaServerLogin.normalizeServerURL("nas.local:8096", preferredScheme: .https).absoluteString,
            "https://nas.local:8096")
        XCTAssertEqual(
            try MediaServerLogin.normalizeServerURL("192.168.1.10:8096", preferredScheme: .http).absoluteString,
            "http://192.168.1.10:8096")
        // 手写前缀始终优先,preferredScheme 不能覆盖。
        XCTAssertEqual(
            try MediaServerLogin.normalizeServerURL("http://nas.local", preferredScheme: .https).absoluteString,
            "http://nas.local")
        XCTAssertEqual(
            try MediaServerLogin.normalizeServerURL("https://nas.local", preferredScheme: .http).absoluteString,
            "https://nas.local")
        // nil 回退原本的 http 默认,保证旧行为不变。
        XCTAssertEqual(
            try MediaServerLogin.normalizeServerURL("192.168.1.10:8096", preferredScheme: nil).absoluteString,
            "http://192.168.1.10:8096")
    }

    func testNormalizeServerURLRejectsGarbage() {
        XCTAssertThrowsError(try MediaServerLogin.normalizeServerURL("not a url"))
        XCTAssertThrowsError(try MediaServerLogin.normalizeServerURL("ftp://x/"))
        XCTAssertThrowsError(try MediaServerLogin.normalizeServerURL(""))
    }

    // MARK: - 探活

    func testStartLoginProbesPublicSystemInfo() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/System/Info/Public")
            return MockURLProtocol.ok(
                """
                {"ServerName":"home-nas","Version":"10.9.11","Id":"srv-1","OperatingSystem":"Linux"}
                """,
                for: request.url!
            )
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "192.168.1.10:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.serverName, "home-nas")
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096")
        }
    }

    func testStartLoginSurfacesUnreachableServer() async throws {
        try await TestSupport.withMock { _ in
            throw URLError(.cannotConnectToHost)
        } with: {
            do {
                _ = try await MediaServerLogin.start(
                    urlString: "192.168.1.10:8096",
                    sessionConfiguration: TestSupport.mockedSessionConfiguration())
                XCTFail("应该抛错")
            } catch let error as JellyfinError {
                guard case .serverUnreachable = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
            }
        }
    }

    /// 连不上类错误（DNS / 拒绝连接 / 断网）给「检查地址」话术；超时等其它传输错误带细节。
    func testTransportErrorClassification() {
        let unreachable: [URLError.Code] = [
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
        ]
        for code in unreachable {
            guard case .serverUnreachable = JellyfinError.wrap(URLError(code)).kind else {
                return XCTFail("\(code) 应归为 serverUnreachable")
            }
        }
        guard case .transport = JellyfinError.wrap(URLError(.timedOut)).kind else {
            return XCTFail("timedOut 应归为 transport")
        }
        guard case .transport = JellyfinError.wrap(URLError(.networkConnectionLost)).kind else {
            return XCTFail("networkConnectionLost 应归为 transport")
        }
    }

    // MARK: - 账号密码登录

    func testPasswordSignInFinishPersistsProfileAndToken() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(#"{"ServerName":"home-nas","Version":"10.9.11","Id":"srv-1"}"#, for: request.url!)
            case "/Users/AuthenticateByName":
                return MockURLProtocol.ok(
                    """
                    {"AccessToken":"tok-123","ServerId":"srv-1",
                     "User":{"Id":"user-9","Name":"jumusu","ServerId":"srv-1"}}
                    """,
                    for: request.url!
                )
            default:
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "http://nas.local:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-123")

            // Jellyfin 路径的 finish 产出 JellyfinServer —— token 必须已装进 SDK 客户端。
            let server = try XCTUnwrap(try session.finish(result, store: store) as? JellyfinServer)
            XCTAssertEqual(server.profile.id, "srv-1:user-9")
            XCTAssertEqual(server.profile.userID, "user-9")
            XCTAssertEqual(server.profile.userName, "jumusu")
            XCTAssertEqual(server.accessToken, "tok-123")

            // 落盘：档案和 token 通过各自的存储抽象保存
            XCTAssertEqual(store.currentProfile?.id, "srv-1:user-9")
            XCTAssertEqual(store.token(for: server.profile), "tok-123")
        }
    }

    func testSignInWithWrongPasswordMapsToUnauthorized() async throws {
        try await TestSupport.withMock { request in
            if request.url?.path == "/System/Info/Public" {
                return MockURLProtocol.ok(#"{"ServerName":"nas","Version":"10.9.11","Id":"srv-1"}"#, for: request.url!)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        } with: {
            do {
                let session = try await MediaServerLogin.start(
                    urlString: "http://nas.local",
                    sessionConfiguration: TestSupport.mockedSessionConfiguration())
                _ = try await session.signIn(username: "x", password: "bad")
                XCTFail("401 应该抛错")
            } catch let error as JellyfinError {
                guard case .unauthorized = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
                XCTAssertNotNil(error.errorDescription)
            }
        }
    }

    // MARK: - Emby 识别与路由前缀

    /// 探活返回 ProductName="Emby Server" → 识别为 Emby：QC 关闭、baseURL 带 /emby、落盘 kind。
    func testStartLoginDetectsEmbyAndAppendsAPIPrefix() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.8.0.42","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            // 登录请求应打到带 /emby 前缀的地址
            case "/emby/Users/AuthenticateByName":
                return MockURLProtocol.ok(
                    #"{"AccessToken":"tok-emby","ServerId":"emby-1","User":{"Id":"user-e","Name":"jumusu"}}"#,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "192.168.1.10:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.kind, .emby)
            XCTAssertFalse(session.supportsQuickConnect, "Emby 没有 Quick Connect")
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096/emby")

            // 密码登录 → finish 落盘 kind 与带前缀的 baseURL
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-emby")
            let server = try session.finish(result, store: store)
            XCTAssertEqual(server.profile.kind, .emby)
            XCTAssertEqual(server.profile.baseURL.absoluteString, "http://192.168.1.10:8096/emby")
            // Emby 档案产出的必须是 EmbyServer，不是 JellyfinServer。
            XCTAssertTrue(server is EmbyServer, "Emby 档案应造出 EmbyServer")
        }
    }

    func testStartLoginKeepsJellyfinKindAndRawBaseURL() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/System/Info/Public")
            return MockURLProtocol.ok(
                #"{"ServerName":"jf-nas","Version":"10.9.11","Id":"srv-1"}"#,
                for: request.url!
            )
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "192.168.1.10:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.kind, .jellyfin)
            XCTAssertTrue(session.supportsQuickConnect)
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096")
        }
    }

    func testDetectKindByProductNameAndVersion() {
        XCTAssertEqual(MediaServerLogin.detectKind(productName: "Emby Server", version: "4.8.0.42"), .emby)
        XCTAssertEqual(MediaServerLogin.detectKind(productName: nil, version: "4.7.2"), .emby, "无 ProductName 时按 4.x 主版本兜底")
        XCTAssertEqual(MediaServerLogin.detectKind(productName: "Jellyfin Server", version: "10.9.11"), .jellyfin)
        XCTAssertEqual(MediaServerLogin.detectKind(productName: nil, version: nil), .jellyfin)
        // ProductName 优先于版本号：报 Jellyfin 就是 Jellyfin，不看版本怎么写的。
        XCTAssertEqual(MediaServerLogin.detectKind(productName: "Jellyfin Server", version: "4.9"), .jellyfin)
    }

    func testEmbyAPIBaseURLAppendsPrefixOnce() throws {
        XCTAssertEqual(MediaServerLogin.embyAPIBaseURL(from: URL(string: "http://nas.local:8096")!).absoluteString,
                       "http://nas.local:8096/emby")
        // 已带 /emby（用户手写或反代子路径）不重复追加
        XCTAssertEqual(MediaServerLogin.embyAPIBaseURL(from: URL(string: "http://nas.local:8096/emby")!).absoluteString,
                       "http://nas.local:8096/emby")
        XCTAssertEqual(MediaServerLogin.embyAPIBaseURL(from: URL(string: "https://media.example.com/emby/")!).absoluteString,
                       "https://media.example.com/emby")
        // 已有其它子路径时追加到末尾
        XCTAssertEqual(MediaServerLogin.embyAPIBaseURL(from: URL(string: "https://host/media")!).absoluteString,
                       "https://host/media/emby")
    }

    // MARK: - 登录响应的宽松解析

    /// 真实 Emby 4.10 登录成功响应带 SDK 强类型解不了的字段（UserPolicy 变体等），
    /// 曾炸出 "The data couldn't be read because it is missing"。宽松解析只抽
    /// AccessToken / User.Id / User.Name，其余字段无论形状一律忽略。
    func testParseLoginResponseToleratesEmbyExtraFields() throws {
        let embyShaped = """
        {"User":{"Name":"jumusu","ServerName":"BBemby","Id":"e2b1longid",
          "HasPassword":true,"HasConfiguredPassword":true,"EnableAutoLogin":false,
          "LastLoginDate":"2026-08-27T06:00:00Z","LastActivityDate":"2026-08-27T05:59:00Z",
          "Policy":{"IsAdministrator":true,"EnableContentDeletion":true,
            "AuthenticationProviderId":"Emby.Server.Implementations.Library.DefaultAuthenticationProvider",
            "PasswordResetProviderId":"Default","InvalidLoginAttemptCount":3,
            "RemoteClientBitrateLimit":0,"EnableAllFolders":true,"EnabledFolders":[]},
          "Configuration":{"SubtitleMode":"Default","DisplayMissingEpisodes":false}},
         "SessionInfo":{"Id":"sess-1","UserId":"e2b1longid","Client":"Emby Web",
           "LastActivityDate":"2026-08-27T06:00:00Z","Capabilities":{}},
         "AccessToken":"embytoken123","ServerId":"02b4c457"}
        """.data(using: .utf8)!
        let result = try LoginResult.parse(embyShaped)
        XCTAssertEqual(result.token, "embytoken123")
        XCTAssertEqual(result.userID, "e2b1longid")
        XCTAssertEqual(result.userName, "jumusu")
    }

    /// 缺 token / 缺 User.Id 的成功响应不能当作登录成功。
    func testParseLoginResponseRejectsIncompletePayload() {
        XCTAssertThrowsError(try LoginResult.parse(#"{"SessionInfo":{}}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try LoginResult.parse(#"{"AccessToken":"t"}"#.data(using: .utf8)!))
        // 非对象响应（纯文本错误体出现在 2xx 之外的路径上）也不许崩成 other
        XCTAssertThrowsError(try LoginResult.parse("用户名或密码无效".data(using: .utf8)!))
    }

    /// 宽松解析走真实请求链路：mock 返回带 Emby 杂字段的响应，signIn 照样出结果。
    func testSignInWorksWithEmbyShapedSuccessResponse() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.8.0.42","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            case "/emby/Users/AuthenticateByName":
                let body = """
                {"User":{"Name":"jumusu","Id":"user-e","Policy":{"IsAdministrator":true,"Odd":{"nested":[1,2,{"x":null}]}}},
                 "AccessToken":"tok-loose","ServerId":"emby-1"}
                """
                return MockURLProtocol.ok(body, for: request.url!)
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "http://nas.local:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-loose")
            XCTAssertEqual(result.userID, "user-e")
        }
    }

    /// Emby 登录密码错误回 400（老版本）：归成 unauthorized 提示而不是裸 HTTP 400。
    func testEmbyPasswordSignInMaps400ToUnauthorized() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.7.2","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            case "/emby/Users/AuthenticateByName":
                let response = HTTPURLResponse(url: request.url!, statusCode: 400,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"Invalid user or password entered."}"#.utf8))
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "http://nas.local:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            do {
                _ = try await session.signIn(username: "x", password: "bad")
                XCTFail("400 应该抛错")
            } catch let error as JellyfinError {
                guard case .unauthorized = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
            }
        }
    }

    /// Emby 没有 Quick Connect：事件流立刻结束、不支持开关为假。
    func testEmbyLoginSessionHasNoQuickConnect() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                #"{"ServerName":"emby-nas","Version":"4.8.0.42","Id":"emby-1","ProductName":"Emby Server"}"#,
                for: request.url!
            )
        } with: {
            let session = try await MediaServerLogin.start(
                urlString: "http://nas.local:8096",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertFalse(session.supportsQuickConnect)
            var events = 0
            for try await _ in session.quickConnectEvents { events += 1 }
            XCTAssertEqual(events, 0, "Emby 的 QC 事件流应为空且立刻结束")
        }
    }
}
