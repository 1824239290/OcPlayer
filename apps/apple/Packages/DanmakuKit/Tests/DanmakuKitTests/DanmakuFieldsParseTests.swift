import XCTest
@testable import DanmakuKit

/// `P2-38`：`fields(from:)` 里的 `p` 字段解析。
///
/// ## 为什么改
///
/// 原先用 `p.split(separator: ",", omittingEmptySubsequences: false)` ——
/// 按 **Character**（字素簇）切分并**分配整个 `[Substring]` 数组**，
/// 而 `p` 有 8 段（`userId` / 时间戳 / 校验串…）我们一个都不看。
/// 实测 **1173 ns/条**，是整个 `fields` 里最贵的一步（占 ~80%）；
/// 1 万条弹幕就是 **11.7 ms** 全花在给不看的数据建数组上。
///
/// 现在按 UTF-8 字节扫到第 2 个逗号就停，实测 **30 ns/条**。
/// `fields` 整体从 **1480 ns** 降到 **187.9 ns**（**7.9×**）。
///
/// ## 这组用例守什么
///
/// 优化一定不能改语义。下面把 `split` 版本的所有边界形态逐条钉住 ——
/// 尤其是「不足三段」「空段」「多余段」这三类。
final class DanmakuFieldsParseTests: XCTestCase {

    /// 用 `entries(from:)` 的条数观察「这条被接受还是跳过」。
    private func accepts(_ p: String, _ m: String = "正文") -> Bool {
        let comments = [DanmakuComment(cid: 1, p: p, m: m)]
        return (try? DanmakuJSONConverter.entries(from: comments))??.isEmpty == false
    }

    func testValidFormsAccepted() {
        XCTAssertTrue(accepts("13.0,5,255,0"), "标准 4 段")
        XCTAssertTrue(accepts("13.0,5,255"), "恰好 3 段（原先的 count >= 3 下界）")
        XCTAssertTrue(accepts("13.0,5,255,0,1758297600,0,abc,1"), "8 段（真实弹弹play 形态）")
        XCTAssertTrue(accepts("0,1,0,0"), "时间 0 合法")
        XCTAssertTrue(accepts("1.5,4,16777215"), "颜色上界 0xFFFFFF")
    }

    /// **不足三段一律跳过** —— 这是 `count >= 3` 的等价物。
    func testFewerThanThreeFieldsRejected() {
        XCTAssertFalse(accepts(""), "空串")
        XCTAssertFalse(accepts("13.0"), "只有 1 段")
        XCTAssertFalse(accepts("13.0,5"), "只有 2 段")
    }

    /// **中间出现空段**：`omittingEmptySubsequences: false` 下空段是空串，
    /// 解析必然失败 → 跳过。字节扫描必须给出同样的结论。
    func testEmptyFieldsRejected() {
        XCTAssertFalse(accepts("13.0,,255,0"), "mode 段为空")
        XCTAssertFalse(accepts(",5,255,0"), "time 段为空")
        XCTAssertFalse(accepts("13.0,5,,0"), "color 段为空")
        // 第 4 段空不影响（只取前三段）："13.0,5,255," 的三段是 13.0 / 5 / 255。
        XCTAssertTrue(accepts("13.0,5,255,"), "第 4 段空不影响")
    }

    /// **多余段必须被忽略**（只取前三段）。
    ///
    /// 第 4 段之后就算放着非 ASCII 昵称、坏数字也都不该影响判定 ——
    /// 字节扫描只走到第 2 个逗号，根本不会碰它们。
    func testTrailingFieldsIgnoredEvenWhenGarbage() {
        XCTAssertTrue(accepts("13.0,5,255,中文昵称,not-a-number,***"), "第 4 段起是垃圾也接受")
        XCTAssertTrue(accepts("13.0,5,255,🎬🎬🎬"), "第 4 段是 emoji 也接受")
        // 但前三段本身坏了就不行。
        XCTAssertFalse(accepts("13.0,5,bad,中文昵称"), "第三段坏 → 跳过")
        XCTAssertFalse(accepts("13.0,bad,255,中文昵称"), "第二段坏 → 跳过")
    }

    /// 数值校验规则不变。
    func testNumericValidationUnchanged() {
        XCTAssertFalse(accepts("bad,1,0,0"), "时间非数字")
        XCTAssertFalse(accepts("-1,1,0,0"), "时间为负")
        XCTAssertFalse(accepts("13.0,0,0,0"), "模式 0 不合法")
        XCTAssertFalse(accepts("13.0,2,0,0"), "模式 2 不合法")
        XCTAssertFalse(accepts("13.0,9,0,0"), "模式 9 不合法")
        XCTAssertFalse(accepts("13.0,1,16777216,0"), "颜色越界 0x1000000")
        XCTAssertFalse(accepts("13.0,1,-1,0"), "颜色为负")
    }

    /// **正文空白判定不变，但不再分配**。
    ///
    /// 原先 `trimmingCharacters(in: .whitespacesAndNewlines)` 只为判空就分配一个新
    /// 字符串（113 ns/条），而返回值用的还是**原文**。现在改成
    /// `contains(where: { !$0.isWhitespace })`，语义相同、零分配。
    func testBlankContentRejectedButWhitespaceInsideKept() {
        XCTAssertFalse(accepts("13.0,1,0,0", "   "), "全空格")
        XCTAssertFalse(accepts("13.0,1,0,0", "\n\t "), "换行制表")
        XCTAssertFalse(accepts("13.0,1,0,0", ""), "空串")
        // 内部空白当然要保留（返回值是原文，不是 trim 过的）。
        XCTAssertTrue(accepts("13.0,1,0,0", "前 后"), "内部空格 → 接受")
        XCTAssertTrue(accepts("13.0,1,0,0", " 前后有空白 "), "两端有空白但中间有内容 → 接受")
    }

    /// **仅由零宽空格（U+200B）组成的正文仍然算空**（保持旧口径）。
    ///
    /// `CharacterSet.whitespacesAndNewlines` 认 U+200B 是空白，而
    /// `Character.isWhitespace` 不认（它是 Cf 格式类）。穷举全部 0x10FFFF 个码位比对过：
    /// 这是两个集合**唯一**的差异。若不补这一条，「仅零宽空格」的弹幕会从
    /// 「丢弃」悄悄变成「接受」—— 肉眼看不见，但那是行为变化。
    func testZeroWidthSpaceOnlyContentStillRejected() {
        XCTAssertFalse(accepts("13.0,1,0,0", "\u{200B}"), "仅 U+200B")
        XCTAssertFalse(accepts("13.0,1,0,0", " \u{200B} "), "空格 + U+200B")
        XCTAssertFalse(accepts("13.0,1,0,0", "\u{200B}\u{200B}"), "两个 U+200B")
        // 但混了真内容就要接受（零宽空格只是修饰）。
        XCTAssertTrue(accepts("13.0,1,0,0", "\u{200B}正文"), "U+200B + 正文 → 接受")
    }

    /// 原文（含两端空白）必须**原样**进 JSON —— 判空用 trim 结果，输出用原文。
    func testContentIsNotTrimmedInOutput() throws {
        let comments = [DanmakuComment(cid: 1, p: "13.0,1,0,0", m: "  保留两端空白  ")]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        let parsed = try XCTUnwrap(DanmakuJSONParser.parse(json))
        XCTAssertEqual(parsed.first?.text, "  保留两端空白  ")
    }
}
