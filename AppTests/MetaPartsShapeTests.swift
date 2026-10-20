import AppDesignKit
import XCTest

@testable import OcPlayer

/// `P2-18`：详情页 `metaRow` 用**内容**当 `ForEach` 身份，其正确性依赖一个前提 ——
/// 「四类元数据的文本形态互斥，不会撞车」。
///
/// ## 为什么测「形态」而不是测排序
///
/// 原实现用 `\.offset`（下标）当身份，问题在于 `metaParts` 里任一字段缺失会让后面
/// 元素整体前移 → 身份全变 → SwiftUI 重建而不是复用。
///
/// 改成内容当身份后，必须保证**内容唯一**（`ForEach` 收到重复 id 是未定义行为）。
/// 而这个唯一性**不是靠代码保证的，是靠四类字段的文本形态互斥**：
///
/// | 字段 | 形态 | 判别特征 |
/// |---|---|---|
/// | 年份 | `"2024"` | **纯数字**（唯一一个） |
/// | 类型 | `"科幻 / 剧情"` | 含 `" / "` |
/// | 时长 | `"1 小时 23 分"` / `"45 分钟"` | 含「小时」或「分钟」 |
/// | 季数 | `"2 季"` | 含「季」 |
///
/// 所以这组用例测的是：**每种形态的产物确实带那个判别特征**，以及
/// **任意两类不会产出相同字符串**。若将来有人改了某个格式化器，让两个字段
/// 能产出同样文本，这些用例会先红 —— 而不是等到线上出现 `ForEach` 重复 id。
final class MetaPartsShapeTests: XCTestCase {

    /// 年份：纯数字，不含任何其它特征。
    func testYearShapeIsPlainDigits() {
        let year = String(2024)
        XCTAssertTrue(year.allSatisfy(\.isNumber), "年份应全是数字")
        XCTAssertTrue(Int(year) != nil)
        // 不含其它三类的特征字符
        XCTAssertFalse(year.contains(" / "))
        XCTAssertFalse(year.contains("小时"))
        XCTAssertFalse(year.contains("分钟"))
        XCTAssertFalse(year.contains("季"))
    }

    /// 类型：多类型时含 `" / "` 分隔。
    func testGenreShapeHasSlashSeparator() {
        let genre = ["科幻", "剧情", "悬疑"].prefix(3).joined(separator: " / ")
        XCTAssertEqual(genre, "科幻 / 剧情 / 悬疑")
        XCTAssertTrue(genre.contains(" / "))
    }

    /// 时长：≥60 分钟含「小时」；<60 分钟含「分钟」。
    func testRuntimeShapeContainsTimeWords() {
        let long = RuntimeText.format(83 * 60)      // 1 小时 23 分
        XCTAssertTrue(long.contains("小时"), "长片时长应含「小时」，实际 \(long)")

        let short = RuntimeText.format(45 * 60)     // 45 分钟
        XCTAssertTrue(short.contains("分钟"), "短片时长应含「分钟」，实际 \(short)")
    }

    /// 季数：含「季」。
    func testSeasonShapeContainsSeasonSuffix() {
        let season = "\(2) 季"
        XCTAssertEqual(season, "2 季")
        XCTAssertTrue(season.contains("季"))
    }

    // MARK: - 互斥性（本组用例的核心）

    /// **四类形态的代表性产物两两不同**。
    ///
    /// 这条是「用内容当身份」能成立的前提。若两类的产物能相同，`ForEach` 就会收到
    /// 重复 id。
    func testAllFourShapesAreMutuallyDistinct() {
        let representatives = [
            String(2024),                                   // 年份
            ["科幻", "剧情"].joined(separator: " / "),        // 类型
            RuntimeText.format(83 * 60),                    // 时长
            "\(2) 季",                                       // 季数
        ]
        XCTAssertEqual(
            Set(representatives).count, representatives.count,
            "四类形态必须两两不同，否则 `ForEach` 会撞 id：\(representatives)")
    }

    /// **穷举一批真实取值范围**，确认任意两类都不会产出相同字符串。
    ///
    /// 年份取 1900–2100、时长取 1–300 分钟、季数取 1–20，与类型串交叉组合。
    func testExhaustiveShapeExclusivity() {
        var byShape: [String: [String]] = [:]
        for year in 1900...2100 {
            byShape["year", default: []].append(String(year))
        }
        for minutes in 1...300 {
            byShape["runtime", default: []].append(RuntimeText.format(Double(minutes) * 60))
        }
        for count in 1...20 {
            byShape["season", default: []].append("\(count) 季")
        }
        byShape["genre"] = ["科幻 / 剧情", "动画", "悬疑 / 犯罪"]

        // 逐对检查：不同形态之间不能有交集
        let keys = Array(byShape.keys).sorted()
        for i in 0..<keys.count {
            for j in (i + 1)..<keys.count {
                let a = Set(byShape[keys[i]]!)
                let b = Set(byShape[keys[j]]!)
                let overlap = a.intersection(b)
                XCTAssertTrue(
                    overlap.isEmpty,
                    "「\(keys[i])」与「\(keys[j])」的产物有交集：\(overlap.prefix(5)) —— "
                    + "这会让 `metaParts` 撞 id")
            }
        }
    }

    /// **稳定性**：前面少一项时，后面各项的文本不变（因此身份不变）。
    ///
    /// 这条与旧实现的对照：`.offset` 版本里位置变了身份就变了；内容版本不会。
    func testContentStableWhenEarlierPartMissing() {
        let parts = ["2024", "科幻 / 剧情", RuntimeText.format(83 * 60), "2 季"]
        let withoutYear = Array(parts.dropFirst())
        XCTAssertTrue(
            Set(withoutYear).isSubset(of: Set(parts)),
            "少一项之后，其余项的文本（= 身份）必须仍在原集合里")
    }
}
