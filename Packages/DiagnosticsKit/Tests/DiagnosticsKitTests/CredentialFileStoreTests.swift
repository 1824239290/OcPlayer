import Foundation
import XCTest
@testable import DiagnosticsKit

/// `CredentialFileStore` 的离线测试：文件形态、base64 双向、权限与备份排除、
/// 以及 string / Data 两种 API 共用一份文件不互相踩。
final class CredentialFileStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func makeStore() -> CredentialFileStore {
        CredentialFileStore(directory: directory)
    }

    func testStoresAndReadsBackString() {
        let store = makeStore()
        XCTAssertNil(store.string(forKey: "jellyfin.token"), "未写入时应为 nil，而不是空串")

        store.setString("tok-123", forKey: "jellyfin.token")
        XCTAssertEqual(store.string(forKey: "jellyfin.token"), "tok-123")

        store.setString(nil, forKey: "jellyfin.token")
        XCTAssertNil(store.string(forKey: "jellyfin.token"), "写 nil 应删除键")
    }

    func testStoresAndReadsBackData() {
        let store = makeStore()
        let payload = Data(#"{"accessToken":"a","refreshToken":"r"}"#.utf8)

        store.setData(payload, forKey: "bangumi.auth")
        XCTAssertEqual(store.data(forKey: "bangumi.auth"), payload)
    }

    /// 两种 API 共用一个文件：写入 string 后 Data 读同一键应拿到同样的字节。
    func testStringAndDataAPIShareOneFile() {
        let store = makeStore()
        store.setString("hello-凭据", forKey: "k")

        XCTAssertEqual(store.data(forKey: "k"), Data("hello-凭据".utf8))
        XCTAssertEqual(store.string(forKey: "k")?.isEmpty, false)
        XCTAssertEqual(
            String(decoding: store.data(forKey: "k") ?? Data(), as: UTF8.self),
            "hello-凭据",
            "非 ASCII 值必须原样往返")
    }

    /// 换一个实例读同一目录，应看到彼此写入的值（证明真的落盘了，而不是只在内存）。
    func testPersistsAcrossInstances() {
        makeStore().setString("persisted", forKey: "k")
        XCTAssertEqual(makeStore().string(forKey: "k"), "persisted")
    }

    /// 落盘的是 JSON 字典，且值不是明文——这是「凭据不该以明文躺在文件里」的最低要求
    /// （base64 不是加密，但至少不会被 `grep 密码` 直接命中；真正的保护是权限 + 排除备份）。
    func testFileIsJSONAndDoesNotContainPlaintext() throws {
        let store = makeStore()
        store.setString("hunter2-secret", forKey: "moviepilot.password")

        let raw = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2-secret"), "值不应以明文出现：\(raw)")
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.count, 1)
    }

    /// 相对 UserDefaults 的**核心改进**：凭据不进备份。
    func testFileIsExcludedFromBackup() throws {
        let store = makeStore()
        store.setString("tok", forKey: "k")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))

        let values = try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "凭据文件必须排除备份")
    }

    /// 权限收紧到 0600（不回退到 UserDefaults 的保护水平）。
    func testFilePermissionsAreOwnerOnly() throws {
        let store = makeStore()
        store.setString("tok", forKey: "k")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o777, 0o600,
                       "实际权限：\(String(permissions.int16Value & 0o777, radix: 8))")
    }

    func testRemoveAllClearsEverything() {
        let store = makeStore()
        store.setString("a", forKey: "k1")
        store.setData(Data([1, 2, 3]), forKey: "k2")

        store.removeAll()

        XCTAssertNil(store.string(forKey: "k1"))
        XCTAssertNil(store.data(forKey: "k2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path),
                       "全清后文件本身也该消失")
    }

    /// 文件被外部破坏（截断 / 手改）时不该崩，读到空即可——下次写入会自愈。
    func testCorruptFileDegradesToEmpty() throws {
        let store = makeStore()
        store.setString("tok", forKey: "k")
        try Data("not json".utf8).write(to: store.url)

        XCTAssertNil(CredentialFileStore(directory: directory).string(forKey: "k"))
    }
}
