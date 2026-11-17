import XCTest
@testable import JellyfinKit

/// `ServerProfile.imageURL` 的**形状**回归。
///
/// ## 为什么这个测试值得存在
///
/// 这个方法的存在理由只有一个：让登录页在**没有会话**时复原历史图片 URL，从而命中
/// 本机图片缓存（墙上的图全部来自那里）。而图片缓存键里含 URL 的路径与查询
/// （`ImageCacheKey` 抹掉 host、只留 path+query），所以形状必须与在线路径**逐字节
/// 一致**——差一个查询项顺序、差一个尾斜杠，墙就一张图都命中不了，而且**不报错**，
/// 只是悄悄变空。那种失败最难查，所以把它钉成黄金值。
///
/// 下面这些期望值是**实测**出来的：对着本机 746 个图片缓存文件逐个复原键，
/// 47 个有主图的条目全部命中（`maxWidth=400 / maxPixelSize=400` 一档覆盖 45 个）。
final class ServerProfileImageURLTests: XCTestCase {

    private func profile(
        baseURL: String = "http://192.168.1.10:8096",
        kind: ServerKind = .jellyfin
    ) throws -> ServerProfile {
        ServerProfile(
            id: "server-1:user-1",
            serverName: "客厅",
            baseURL: try XCTUnwrap(URL(string: baseURL)),
            userID: "user-1",
            kind: kind
        )
    }

    /// 黄金值：与 `JellyfinServer.imageURL` 在线产出的形状一致。
    func testJellyfinImageURLShape() throws {
        let url = try XCTUnwrap(
            profile().imageURL(itemID: "abc123", type: .primary, maxWidth: 400, tag: "ff0cfa3104bbdf61")
        )
        XCTAssertEqual(
            url.absoluteString,
            "http://192.168.1.10:8096/Items/abc123/Images/Primary?maxWidth=400&tag=ff0cfa3104bbdf61"
        )
    }

    /// 查询项顺序固定：`maxWidth` 在前、`tag` 在后。顺序变了缓存键就变了。
    func testQueryItemOrderIsStable() throws {
        let url = try XCTUnwrap(
            profile().imageURL(itemID: "x", type: .primary, maxWidth: 300, tag: "T")
        )
        XCTAssertEqual(url.query, "maxWidth=300&tag=T")
    }

    /// 省略查询项时不该留下孤零零的 `?`。
    func testOmittingQueryItems() throws {
        let bare = try XCTUnwrap(profile().imageURL(itemID: "x"))
        XCTAssertEqual(bare.absoluteString, "http://192.168.1.10:8096/Items/x/Images/Primary")
        XCTAssertNil(bare.query)

        let widthOnly = try XCTUnwrap(profile().imageURL(itemID: "x", maxWidth: 400))
        XCTAssertEqual(widthOnly.query, "maxWidth=400")
    }

    /// Emby 档案的 `baseURL` 带 `/emby` 前缀：路径必须拼在它**后面**而不是覆盖它，
    /// 否则复原出来的 URL 与真实请求的不是同一条，缓存全 miss。
    func testEmbySubpathIsPreserved() throws {
        let url = try XCTUnwrap(
            profile(baseURL: "http://10.0.0.2:8096/emby", kind: .emby)
                .imageURL(itemID: "abc", type: .primary, maxWidth: 400, tag: "T")
        )
        XCTAssertEqual(
            url.absoluteString,
            "http://10.0.0.2:8096/emby/Items/abc/Images/Primary?maxWidth=400&tag=T"
        )
    }

    /// 尾斜杠不该产生 `//Items`（那是另一条 URL，缓存键也就变了）。
    func testTrailingSlashDoesNotDouble() throws {
        let url = try XCTUnwrap(
            profile(baseURL: "http://10.0.0.2:8096/").imageURL(itemID: "abc")
        )
        XCTAssertEqual(url.absoluteString, "http://10.0.0.2:8096/Items/abc/Images/Primary")
    }

    /// 四种图片类型各自映射到服务端的 `ImageType` 字面量。
    func testAllImageTypesMapToServerLiterals() throws {
        let expected: [(ItemImageType, String)] = [
            (.primary, "Primary"), (.backdrop, "Backdrop"), (.thumb, "Thumb"), (.logo, "Logo")
        ]
        for (type, literal) in expected {
            let url = try XCTUnwrap(profile().imageURL(itemID: "i", type: type))
            XCTAssertTrue(url.path.hasSuffix("/Images/\(literal)"), "\(type) → \(url.path)")
        }
    }
}
