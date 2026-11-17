import XCTest
@testable import DanmakuKit

/// `P2-38`（其三）：`DanmakuIntroDetector.detect` 的快路径与**旧实现逐条等价**。
///
/// ## 为什么改
///
/// 每条弹幕原先要付 **2 次全量 `p.split`**（`commentTime` / `commentUID`）+
/// **19 次 `String` 关键词搜索**（5 报点 + 10 着陆 + 4 正片）。
/// 实测 1 万条 **348–353 ms**，其中字符串搜索占 **92%**
/// （`String.contains` 走字素簇比较，单次约 1.7 µs）。
///
/// 现在 `p` 与 `m` 各只扫**一遍字节**。实测 1 万条 **50.8 ms（7.0×）**。
///
/// ## 这组用例的核心：把旧实现当成 oracle
///
/// 「字节扫描」与「按字素簇切分/搜索」**确实可能不同** —— 当逗号或关键词末尾的字
/// 与后续组合符合并成一个字素簇时。生产数据里几乎不可能出现，但**「几乎」不是「不会」**。
///
/// 所以这里把**旧实现逐字抄进测试**当作判据，对大量输入逐条比对。
/// 只要新实现与 oracle 完全一致，这个优化就不改变任何行为。
/// 若哪天有人「顺手简化」掉 `parseTimeAndUID` 的 ASCII 回退或 `scanKeywords` 的
/// 字素边界校验，这组用例会立刻红。
final class DanmakuIntroFastPathTests: XCTestCase {

    // MARK: - Oracle：旧实现（逐字副本，不要改）

    private func oracleTime(_ p: String) -> Double? {
        guard let raw = p.split(separator: ",").first,
              let time = Double(raw), time.isFinite, time >= 0
        else { return nil }
        return time
    }

    private func oracleUID(_ p: String) -> String? {
        let segments = p.split(separator: ",")
        guard segments.count >= 4 else { return nil }
        let uid = segments[3].trimmingCharacters(in: .whitespaces)
        return uid.isEmpty ? nil : uid
    }

    // MARK: - 差分：`p` → (time, uid)

    /// **定向边界形态**：空段、连排逗号、尾随逗号、前后空白、非 ASCII、组合符。
    func testParseTimeAndUIDMatchesOracleOnCraftedInputs() {
        let crafted = [
            "", ",", ",,", ",,,,", ",,,,,,,",
            "1", "1,2", "1,2,3", "1,2,3,4", "1,2,3,4,5",
            ",1,2,3,4", "1,,2,3,4", "1,2,,3,4", "1,2,3,,4", "1,2,3,4,",
            "1.5,1,100,abc123", "1.5,1,100, abc ", "1.5,1,100,  ",
            "bad,1,2,3", "-1,1,2,3", "0,1,2,3", "1e3,1,2,3",
            " 1,2,3,4", "1 ,2,3,4", "   ,   ,   ,   ",
            "13.0,5,16777215,0", "13.0,5,16777215,user-42",
            // 非 ASCII：必须走回退分支
            "中,1,2,3", "1,2,3,中", "50,\u{0301}",
            // 逗号 + 组合符合并成字素簇（字节切分与字素切分会不同）
            "5+a.,3Z3+ ,.2,8,\u{0301}a",
            "3 5,7,5b7, 55 ,\u{0301}Z 中",
            "1,2,3,4\u{0301}", "1\u{0301},2,3,4",
        ]
        for input in crafted {
            let expectedTime = oracleTime(input)
            let expectedUID = oracleUID(input)
            let (time, uid) = DanmakuIntroDetector.parseTimeAndUID(input)
            XCTAssertEqual(time, expectedTime, "时间不一致：\(input.debugDescription)")
            XCTAssertEqual(uid, expectedUID, "uid 不一致：\(input.debugDescription)")
        }
    }

    /// **随机差分**（固定种子，可复现）：ASCII 数字/逗号/空白/点/符号 + 非 ASCII + 组合符。
    func testParseTimeAndUIDMatchesOracleOnRandomInputs() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        var scalars: [Unicode.Scalar] = Array("0123456789,.-+abcZ \t".unicodeScalars)
        scalars += [Unicode.Scalar(0x0301)!, Unicode.Scalar(0x00A0)!,
                    Unicode.Scalar(0x4E2D)!, Unicode.Scalar(0xFE0F)!]
        for _ in 0..<20_000 {
            let length = Int(rng.next() % 21)
            var view = String.UnicodeScalarView()
            for _ in 0..<length {
                view.append(scalars[Int(rng.next() % UInt64(scalars.count))])
            }
            let input = String(view)
            let (time, uid) = DanmakuIntroDetector.parseTimeAndUID(input)
            XCTAssertEqual(time, oracleTime(input), "时间不一致：\(input.debugDescription)")
            XCTAssertEqual(uid, oracleUID(input), "uid 不一致：\(input.debugDescription)")
        }
    }

    // MARK: - 差分：关键词扫描

    /// 全部关键词一次扫出来的结果，必须等于逐词 `text.contains(_:)`。
    func testScanKeywordsMatchesOracle() {
        let jump = DanmakuIntroDetector.jumpKeywords
        let landing = DanmakuIntroDetector.landingKeywords
        let start = DanmakuIntroDetector.startKeywords

        var rng = SeededRNG(seed: 0xBEEF)
        var scalars: [Unicode.Scalar] = Array("跳伞空降正片开始成功已着陆感谢指挥塔部隊投至到完中".unicodeScalars)
        scalars += [Unicode.Scalar(0x0301)!, Unicode.Scalar(0xFE0F)!,
                    Unicode.Scalar(0x200D)!, Unicode.Scalar(0x20)!,
                    Unicode.Scalar(0x61)!, Unicode.Scalar(0x1F600)!,
                    Unicode.Scalar(0x0600)!, Unicode.Scalar(0x110BD)!]

        // 定向：关键词的各种包围形态
        let crafted = ["", "跳伞", "空降成功", "正片开始", "开始正片",
                       "跳伞至3:17", "前面有字空降成功后面也有",
                       "跳伞\u{0301}", "空降\u{FE0F}成功", "👨\u{200D}👩\u{200D}👧跳伞",
                       "a跳伞b", "跳\u{0301}伞", "正片开始了", "開始正片",
                       // **Prepend 类字符会把关键词首字并进同一字素簇** ——
                       // 此时起点 `String.Index` 为 nil、终点正常。只校验终点会漏掉这三条。
                       "\u{0600}跳伞", "\u{0601}空降成功", "\u{110BD}正片开始"]
        for text in crafted {
            let scan = DanmakuIntroDetector.scanKeywords(in: text)
            XCTAssertEqual(scan.hasLanding, landing.contains { text.contains($0) },
                           "landing 不一致：\(text.debugDescription)")
            XCTAssertEqual(scan.hasStart, start.contains { text.contains($0) },
                           "start 不一致：\(text.debugDescription)")
            for (index, keyword) in jump.enumerated() {
                XCTAssertEqual(scan.jumpMatchEnds[index] != nil, text.contains(keyword),
                               "jump「\(keyword)」不一致：\(text.debugDescription)")
            }
        }

        // 随机
        for _ in 0..<8_000 {
            let length = Int(rng.next() % 15)
            var view = String.UnicodeScalarView()
            for _ in 0..<length {
                view.append(scalars[Int(rng.next() % UInt64(scalars.count))])
            }
            let text = String(view)
            let scan = DanmakuIntroDetector.scanKeywords(in: text)
            XCTAssertEqual(scan.hasLanding, landing.contains { text.contains($0) },
                           "landing 不一致：\(text.debugDescription)")
            XCTAssertEqual(scan.hasStart, start.contains { text.contains($0) },
                           "start 不一致：\(text.debugDescription)")
            for (index, keyword) in jump.enumerated() {
                XCTAssertEqual(scan.jumpMatchEnds[index] != nil, text.contains(keyword),
                               "jump「\(keyword)」不一致：\(text.debugDescription)")
            }
        }
    }

    /// **首次命中的位置必须与 `range(of:)` 相同**（`jumpTarget` 依赖它取窗口）。
    ///
    /// 若扫描记录的不是「首次」命中，报点落点会从错误的位置开始读时间戳。
    func testJumpMatchEndIsFirstOccurrence() {
        let cases = [
            "空降3:17，然后跳伞5:20",   // 两个词都有，数组顺序里「空降」在前
            "跳伞5:20，然后空降3:17",
            "空降 空降成功 02:12",
            "没有关键词的弹幕",
        ]
        for text in cases {
            let scan = DanmakuIntroDetector.scanKeywords(in: text)
            for (index, keyword) in DanmakuIntroDetector.jumpKeywords.enumerated() {
                let expected = text.range(of: keyword)?.upperBound
                XCTAssertEqual(scan.jumpMatchEnds[index], expected,
                               "「\(keyword)」首次命中位置不一致：\(text.debugDescription)")
            }
        }
    }

    /// **关键词按 `jumpKeywords` 的数组顺序遍历，不是文本里的先后顺序。**
    ///
    /// 旧实现是 `for keyword in jumpKeywords { text.range(of: keyword) }` ——
    /// 数组里靠前的词赢，哪怕它在文本里出现得更晚。若哪天改成「取文本里最靠前的词」，
    /// 下面这条会红。
    func testJumpTargetUsesKeywordArrayOrderNotTextOrder() {
        // 文本里「空降」在前、「跳伞」在后；但数组顺序是 跳伞 先。
        let text = "空降3:17，跳伞9:00"
        // 按数组顺序 → 取「跳伞」后的 9:00 = 540 秒。
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: text), 540,
                       "应按 jumpKeywords 的数组顺序取「跳伞」，而不是文本里更靠前的「空降」")
        // 反向排列：这次文本顺序与数组顺序一致，结果仍是「跳伞」那个。
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "跳伞9:00，空降3:17"), 540)
        // 只有「空降」时才用它。
        XCTAssertEqual(DanmakuIntroDetector.jumpTarget(in: "空降3:17"), 197)
    }

    /// **非 ASCII 出现在前 4 段之后，仍必须走回退路径。**
    ///
    /// 这是我在实现时踩到过的真 bug：为了省事在「已收齐 4 段」时提前 `break`，
    /// 于是后面那个非 ASCII 字节根本没被看到 → 没回退 → 用字节切分算出了错的 uid。
    /// 例：`"5+a.,3Z3+ ,.2,8,\u{0301}a"` —— 逗号与组合符合并，字素切分只有 4 段、
    /// 第 4 段是 `"8,\u{0301}a"`，而字节切分会把它切成 `"8"`。
    func testNonASCIIAfterFourthSegmentStillFallsBack() {
        let cases = [
            "1,2,3,4,中",
            "1,2,3,4,5,\u{0301}a",
            "5+a.,3Z3+ ,.2,8,\u{0301}a",
            "3 5,7,5b7, 55 ,\u{0301}Z 中",
            "1.5,1,100,abc\u{0301}def",
        ]
        for input in cases {
            let expected = oracleUID(input)
            let (_, uid) = DanmakuIntroDetector.parseTimeAndUID(input)
            XCTAssertEqual(uid, expected, "4 段之后的非 ASCII 导致 uid 不一致：\(input.debugDescription)")
        }
    }

    /// **预计算的关键词表必须覆盖全部关键词，且分类正确。**
    ///
    /// 第一版把这张表放在 `scanKeywords` 里**每条弹幕重建一遍** —— 实测 **2902 ns/条**，
    /// 在优化后的 `detect`（≈5170 ns/条）里占了一半以上。提到 `static let` 后归零，
    /// 整条路径从 51.7 ms 降到 **17.5 ms**（1 万条）。
    ///
    /// 这条用例钉住「表里确实有全部 19 个词」—— 若有人改表时漏掉几个，
    /// 后面的差分用例会因为「扫不出这个词」而红，但那时已经很难定位。
    func testPrecomputedNeedleTableIsComplete() {
        let jump = DanmakuIntroDetector.jumpKeywords
        let landing = DanmakuIntroDetector.landingKeywords
        let start = DanmakuIntroDetector.startKeywords
        // 逐个词单独构造一条只含它的文本，确认扫描能认出来。
        for keyword in jump {
            let scan = DanmakuIntroDetector.scanKeywords(in: "前缀\(keyword)后缀")
            let index = jump.firstIndex(of: keyword)!
            XCTAssertNotNil(scan.jumpMatchEnds[index], "预计算表漏了报点词「\(keyword)」")
        }
        for keyword in landing {
            XCTAssertTrue(DanmakuIntroDetector.scanKeywords(in: "前缀\(keyword)后缀").hasLanding,
                          "预计算表漏了着陆词「\(keyword)」")
        }
        for keyword in start {
            XCTAssertTrue(DanmakuIntroDetector.scanKeywords(in: "前缀\(keyword)后缀").hasStart,
                          "预计算表漏了正片词「\(keyword)」")
        }
        // 分类不能串：报点词不该被算成 landing/start，反之亦然。
        XCTAssertFalse(DanmakuIntroDetector.scanKeywords(in: "跳伞").hasLanding)
        XCTAssertFalse(DanmakuIntroDetector.scanKeywords(in: "跳伞").hasStart)
        XCTAssertFalse(DanmakuIntroDetector.scanKeywords(in: "空降成功").hasStart)
        XCTAssertFalse(DanmakuIntroDetector.scanKeywords(in: "正片开始").hasLanding)
    }

    /// **关键词必须没有 Unicode 规范分解**（否则字节扫描会静默漏命中）。
    ///
    /// 字节扫描 + 字素边界校验等价于 `String.contains`，**前提是关键词本身不自带
    /// 规范分解**。反例：`"か\u{3099}".contains("が")` 是 **true**（`String` 会做规范比较），
    /// 而字节扫描找不到 `が` 的字节（文本里是分解形式），边界校验也救不回来。
    ///
    /// 现有 19 个关键词全是 precomposed 的 CJK，不受影响。但将来若加「が」「パ」这类
    /// 可分解的词，就会**静默漏命中** —— 那是最难查的一类 bug。这条用例把它挡在门口。
    func testKeywordsHaveNoCanonicalDecomposition() {
        let all = DanmakuIntroDetector.jumpKeywords
            + DanmakuIntroDetector.landingKeywords
            + DanmakuIntroDetector.startKeywords
        for keyword in all {
            XCTAssertEqual(
                keyword, keyword.precomposedStringWithCanonicalMapping,
                "关键词「\(keyword)」在 NFD 形态下与自身不同 —— 字节扫描会漏命中，"
                    + "请改用 precomposed 写法")
            XCTAssertEqual(
                keyword, keyword.decomposedStringWithCanonicalMapping,
                "关键词「\(keyword)」有规范分解 —— 字节扫描会漏命中，请改用 precomposed 写法")
        }
    }
}

/// 固定种子的 LCG：用例必须**可复现**，不能用 `SystemRandomNumberGenerator`。
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
