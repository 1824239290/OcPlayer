import CoreModel
import JellyfinAPI
import XCTest
@testable import JellyfinKit

/// 缺 id 兜底派生 id 的映射测试（review-20260914 P3-3）。
///
/// 这条用例的价值就在**固定期望值**：`Hasher()` 每个进程随机播种，根本写不出一个
/// 恒等的 golden——能钉住固定串，才说明派生 id 跨进程 / 跨启动稳定（服务器漏 id 的
/// 兜底条目不会每次冷启动换一次身份）。
final class MappingTests: XCTestCase {

    private func domainItem(_ json: String) throws -> MediaItem {
        let dto = try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
        return dto.domainItem
    }

    func testMissingIDFallsBackToStableDerivedID() throws {
        let item = try domainItem(#"{"Name":"某片","Type":"Movie"}"#)
        XCTAssertEqual(item.id, "missing-9e3e3d30dc18fb24")
    }

    func testDerivedIDDistinguishesNameAndKind() throws {
        let movie = try domainItem(#"{"Name":"某片","Type":"Movie"}"#)
        let series = try domainItem(#"{"Name":"某片","Type":"Series"}"#)
        let otherName = try domainItem(#"{"Name":"某剧","Type":"Movie"}"#)

        XCTAssertNotEqual(movie.id, series.id, "同名不同类型的兜底 id 不能撞")
        XCTAssertNotEqual(movie.id, otherName.id, "不同类型的兜底 id 要能分开")
        XCTAssertEqual(otherName.id, "missing-530cf0ab2ac5eda2")
    }

    func testServerIDWinsOverDerived() throws {
        let item = try domainItem(#"{"Id":"abc-123","Name":"某片","Type":"Movie"}"#)
        XCTAssertEqual(item.id, "abc-123", "服务器给了 id 就用服务器的，不走派生")
    }
}
