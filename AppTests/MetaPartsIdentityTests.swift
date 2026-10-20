import XCTest

@testable import OcPlayer

/// `P2-18`：详情页 `metaRow` 的 `ForEach` 身份必须**稳定且唯一**。
///
/// ## 为什么需要这组用例
///
/// 原实现用 `\.offset`（数组下标）当身份。`metaParts` 是动态拼的
/// （年份 / 类型 / 时长 / 季数），**任一字段缺失会让后面元素整体前移** ——
/// 用位置当身份时，前移等于「身份全变」，SwiftUI 会重建而不是复用。
///
/// 改用内容当身份后要保证两件事：
/// 1. **稳定**：前面少一项时，后面各项的身份**不变**；
/// 2. **唯一**：内容重复时不能喂给 `ForEach` 重复 id（那是未定义行为）。
final class MetaPartsIdentityTests: XCTestCase {

    private func ids(_ parts: [String]) -> [String] {
        DetailView.identified(parts).map(\.id)
    }

    /// 正常情况：身份就是内容本身。
    func testIDsEqualContentWhenUnique() {
        let parts = ["2024", "科幻 / 剧情", "1小时23分", "2 季"]
        XCTAssertEqual(ids(parts), parts)
    }

    /// **核心判据：前面缺一项时，后面各项的身份不变。**
    ///
    /// 这是 `.offset` 版本必然失败的地方 —— 位置变了身份就变了。
    func testIDsAreStableWhenEarlierPartIsMissing() {
        let full = ["2024", "科幻 / 剧情", "1小时23分", "2 季"]
        let withoutYear = ["科幻 / 剧情", "1小时23分", "2 季"]

        let fullIDs = Set(ids(full))
        let reducedIDs = Set(ids(withoutYear))

        XCTAssertTrue(
            reducedIDs.isSubset(of: fullIDs),
            "少了「年份」之后，其余三项的身份必须与原来相同 —— 否则 SwiftUI 会把它们当成新元素重建")
    }

    /// 缺中间的项也一样：后面的身份不该变。
    func testIDsAreStableWhenMiddlePartIsMissing() {
        let full = ["2024", "科幻 / 剧情", "1小时23分", "2 季"]
        let withoutGenre = ["2024", "1小时23分", "2 季"]
        XCTAssertTrue(Set(ids(withoutGenre)).isSubset(of: Set(ids(full))))
    }

    /// **内容重复时必须仍唯一**（否则 `ForEach` 收到重复 id）。
    func testIDsAreUniqueEvenWithDuplicateContent() {
        // 构造真会撞车的情况：两个完全相同的串。
        let parts = ["2024", "2024", "科幻"]
        let result = ids(parts)

        XCTAssertEqual(result.count, parts.count)
        XCTAssertEqual(Set(result).count, parts.count, "id 必须唯一，收到重复 id 是未定义行为")
    }

    /// 重复内容的首个出现保持「无后缀」身份 —— 这样首次出现不受位置影响。
    func testFirstOccurrenceKeepsBareIdentity() {
        let parts = ["A", "A", "B"]
        let result = ids(parts)
        XCTAssertEqual(result[0], "A", "首个出现应是无后缀的内容")
        XCTAssertEqual(result[1], "A#1")
        XCTAssertEqual(result[2], "B")
    }

    /// 三项全部相同也要唯一。
    func testAllDuplicatesAreUnique() {
        let parts = ["X", "X", "X"]
        let result = ids(parts)
        XCTAssertEqual(Set(result).count, 3)
    }

    /// `index` 仍按位置给出（分隔符要用它），与 id 解耦。
    func testIndexIsPreservedAlongsideID() {
        let entries = DetailView.identified(["A", "B", "C"])
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(entries.map(\.text), ["A", "B", "C"])
    }

    /// 空数组不该崩。
    func testEmptyInput() {
        XCTAssertTrue(DetailView.identified([]).isEmpty)
    }
}
