import XCTest
import OcPlayerCore
@testable import MoviePilotKit

#if os(macOS)
/// Inject the real credential commit and pause its return while another account
/// operation runs. This covers the actor/MainActor handoff after storage succeeds.
private actor CommitInterruption {
    weak var client: MoviePilotAPIClient?
    let replace: Bool
    let address: String
    var pending = true
    var failure: String?
    init(replace: Bool, address: String) { self.replace = replace; self.address = address }
    func attach(_ client: MoviePilotAPIClient) { self.client = client }
    func run() async {
        guard pending, let client else { return }
        pending = false
        if replace {
            do { _ = try await client.login(serverURLString: address, username: "new-account", password: "fixture") }
            catch { failure = String(describing: error) }
        } else { _ = await client.signOut() }
    }
}

final class MoviePilotAccountLifecycleTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for retained account integration")
        }
        return path
    }

    private static func nativeResponse(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        if url.path.hasSuffix("access-token") {
            var form = URLComponents()
            form.percentEncodedQuery = String(decoding: TestSupport.body(of: request) ?? Data(), as: UTF8.self)
            let username = form.queryItems?.first(where: { $0.name == "username" })?.value ?? "missing"
            return MockURLProtocol.response("{\"access_token\":\"user:\(username)\"}", status: 200, for: url)
        }
        return MockURLProtocol.response("{\"id\":1,\"name\":\"fixture\"}", status: 200, for: url)
    }

    @MainActor
    private static func exerciseCommitRace(corePath: String?, replace: Bool) async throws {
        let server = try NativeServer()
        defer { server.stop(); MockURLProtocol.handler = nil }
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
            credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        store.updateCredentials(serverURLString: server.baseURL, username: "fixture", password: "fixture")
        store.accessToken = "fresh"
        if corePath == nil {
            MockURLProtocol.handler = Self.nativeResponse
        }
        let interruption = CommitInterruption(replace: replace, address: server.baseURL)
        let client = MoviePilotAPIClient(store: store,
            sessionConfiguration: corePath == nil ? TestSupport.mockedSessionConfiguration() : .ephemeral,
            rustCoreLibraryPath: corePath,
            credentialCommit: { address, username, password, token, revision in
                let committed = await store.commitCredentials(serverURLString: address, username: username,
                    password: password, accessToken: token, ifRevision: revision)
                if committed { await interruption.run() }
                return committed
            })
        await interruption.attach(client)
        do {
            _ = try await client.login(serverURLString: server.baseURL, username: "old-account", password: "fixture")
            XCTFail("An old login must not publish success after the commit handoff")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let failure = await interruption.failure
        XCTAssertNil(failure)
        let generation = await client.currentGeneration()
        XCTAssertEqual(generation, replace ? 3 : 2, "The old login must not advance the replacement's generation")
        XCTAssertEqual(store.username, replace ? "new-account" : "old-account")
        XCTAssertEqual(store.accessToken, replace ? "user:new-account" : nil)
        let usesCore = await client.usesCoreTransport
        XCTAssertEqual(usesCore, corePath != nil)
        if corePath != nil {
            let requests = try await server.requests()
            XCTAssertEqual(requests.count, replace ? 4 : 2)
        }
    }

    func testCoreLoginCommitCannotPublishAfterSignOut() async throws {
        try await Self.exerciseCommitRace(corePath: library(), replace: false)
    }
    func testCoreLoginCommitCannotPublishAfterReplacementLogin() async throws {
        try await Self.exerciseCommitRace(corePath: library(), replace: true)
    }
    func testNativeLoginCommitCannotPublishAfterSignOut() async throws {
        try await Self.exerciseCommitRace(corePath: nil, replace: false)
    }
    func testNativeLoginCommitCannotPublishAfterReplacementLogin() async throws {
        try await Self.exerciseCommitRace(corePath: nil, replace: true)
    }
    func testRetainedAccountAdapterPreservesUnsignedGenerations() throws {
        let core = try OcpCoreClient(libraryPath: library())
        let account = RustMoviePilotAccount(core)
        let generation: UInt64 = 9_007_199_254_741_007
        let _: RustMoviePilotAccount.Snapshot = try account.call("seed", [
            "generation": generation, "configurationRevision": UInt64.max, "refreshId": 0,
        ])
        XCTAssertEqual(account.snapshot.generation, generation)
        XCTAssertEqual(account.snapshot.configurationRevision, UInt64.max)
        let current: Bool = try account.call("current", ["generation": generation])
        XCTAssertTrue(current)
    }
}
#endif
