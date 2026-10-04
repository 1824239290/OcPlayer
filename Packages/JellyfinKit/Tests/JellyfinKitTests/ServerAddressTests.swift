import XCTest
@testable import JellyfinKit

/// 服务器地址模型：分类、归一化去重、落盘格式。
final class ServerAddressTests: XCTestCase {

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: - 分类

    func testClassifiesPrivateIPv4AsLAN() {
        for text in ["http://192.168.5.107:8096", "http://10.0.0.4:8096",
                     "http://172.16.3.9:8096", "http://172.31.255.1:8096",
                     "http://127.0.0.1:8096", "http://169.254.1.1:8096"] {
            XCTAssertEqual(ServerAddress.classify(url(text)), .lan, "\(text) 应是局域网")
        }
    }

    func testClassifiesTailscaleCGNATRangeAndMagicDNS() {
        // Tailscale 用 100.64.0.0/10：100.64.x ~ 100.127.x。
        for text in ["http://100.64.0.1:8096", "http://100.101.102.103:8096",
                     "http://100.127.255.254:8096", "https://nas.tailnet-abc.ts.net"] {
            XCTAssertEqual(ServerAddress.classify(url(text)), .tailscale, "\(text) 应是 Tailscale")
        }
    }

    func testCGNATBoundariesAreNotTailscale() {
        // 边界外不是 Tailscale 网段（100.63 / 100.128 都不是 100.64.0.0/10）。
        XCTAssertEqual(ServerAddress.classify(url("http://100.63.255.255:8096")), .remote)
        XCTAssertEqual(ServerAddress.classify(url("http://100.128.0.1:8096")), .remote)
    }

    func testClassifiesHostnames() {
        XCTAssertEqual(ServerAddress.classify(url("http://nas.local:8096")), .lan, "mDNS 名字")
        XCTAssertEqual(ServerAddress.classify(url("http://nas:8096")), .lan, "单标签主机名只可能靠局域网解析")
        XCTAssertEqual(ServerAddress.classify(url("http://media.example.com")), .remote)
        XCTAssertEqual(ServerAddress.classify(url("http://8.8.8.8:8096")), .remote)
    }

    // MARK: - 归一化（判等用，不改发请求的地址）

    func testNormalizationIgnoresCaseTrailingSlashAndDefaultPort() {
        XCTAssertTrue(ServerAddress.isSame(url("http://NAS.local:8096/"), url("http://nas.local:8096")))
        XCTAssertTrue(ServerAddress.isSame(url("http://nas.local:80"), url("http://nas.local")))
        XCTAssertTrue(ServerAddress.isSame(url("HTTPS://nas.local:443/x/"), url("https://nas.local/x")))
        XCTAssertFalse(ServerAddress.isSame(url("http://nas.local:8096"), url("http://nas.local:8097")))
    }

    func testEmbyPathPrefixIsPartOfIdentity() {
        // Emby 档案的 baseURL 带 /emby 前缀，归一化不能把它吃掉。
        XCTAssertFalse(ServerAddress.isSame(url("http://nas.local:8096/emby"), url("http://nas.local:8096")))
        XCTAssertTrue(ServerAddress.isSame(url("http://nas.local:8096/emby/"), url("http://nas.local:8096/emby")))
    }

    func testListDeduplicatesAndExcludesPrimary() {
        let primary = url("http://nas.local:8096")
        let list = ServerAddress.list(from: [
            url("http://NAS.local:8096/"),      // 与 primary 同一个入口 → 排除
            url("http://100.64.1.20:8096"),
            url("http://100.64.1.20:8096/"),    // 重复 → 去重
            url("http://media.example.com"),
        ], excluding: primary)
        XCTAssertEqual(list.map(\.url.absoluteString),
                       ["http://100.64.1.20:8096", "http://media.example.com"])
    }

    // MARK: - 落盘格式

    func testCodableRoundTripUsesPlainString() throws {
        let address = ServerAddress(url: url("http://100.64.1.20:8096"))
        let data = try JSONEncoder().encode([address])
        // 落盘就是一条地址字符串（可读、能手工改），不是带分类字段的对象。
        // 用 JSONSerialization 比对而不是比字符串：Foundation 对 `/` 是否转义
        // 在不同版本上不一致，比字符串会把无关差异当成失败。
        let object = try JSONSerialization.jsonObject(with: data) as? [String]
        XCTAssertEqual(object, ["http://100.64.1.20:8096"])

        let decoded = try JSONDecoder().decode([ServerAddress].self, from: data)
        XCTAssertEqual(decoded, [address])
    }

    func testClassificationIsComputedNotStored() throws {
        // 落盘只有地址字符串：分类跟着代码走，不会被旧数据的分类字段带偏。
        let data = Data("[\"http://100.64.0.9:8096\"]".utf8)
        let decoded = try JSONDecoder().decode([ServerAddress].self, from: data)
        XCTAssertEqual(decoded[0].kind, .tailscale)
    }
}

/// 地址拼装：路径拼在 base 的路径**之后**（Emby 的 /emby 前缀靠这条活着）。
final class ServerURLTests: XCTestCase {

    func testAppendsPathAfterBasePrefix() throws {
        let url = try ServerURL.absolute(base: URL(string: "http://nas.local:8096/emby/")!,
                                         path: "/System/Info/Public")
        XCTAssertEqual(url.absoluteString, "http://nas.local:8096/emby/System/Info/Public")
    }

    func testKeepsQueryOrder() throws {
        let url = try ServerURL.absolute(
            base: URL(string: "http://nas.local:8096")!,
            path: "/Videos/v1/stream",
            query: [("Static", "true"), ("mediaSourceId", "ms-1")])
        XCTAssertEqual(url.absoluteString,
                       "http://nas.local:8096/Videos/v1/stream?Static=true&mediaSourceId=ms-1")
    }
}
