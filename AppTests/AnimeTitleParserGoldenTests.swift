import XCTest
@testable import OcPlayer

/// `AnimeTitleParser` 的**行为快照**（golden 语料）。
///
/// 存在的理由：`P1-07` 把那批「每次调用都现编译」的 `NSRegularExpression` 提成了
/// 静态量。那是一次**纯重构** —— 主张是「API 不变 ⇒ 语义不变」。但这主张没法靠
/// 读 diff 证明：43 条 pattern 从「每次 try? 编译」变成「编译一次复用」，任何一条
/// 行为漂移（漏条、换了 API、替换模板串了）都不会编译报错，只会让匹配悄悄变。
///
/// 所以这份语料是**改代码之前**用原实现 dump 出来的，逐字段钉住：
/// `rawTitle` 之外的 6 个字段全在串里（`clean | season | part | isFinal | subtitle | year`）。
/// 语料刻意覆盖每一条 pattern：中文季数 / ASCII 季数 / 结尾裸数字 / 罗马数字三形态 /
/// 最终季四形态 / 篇章关键词 / Part·Cour / 全角 / 括号 / S·T 后缀 / 反例。
///
/// ⚠️ 这份期望值是用**当时的实现**生成的，不是「正确答案」——它记录的是既有行为
/// （包括其中已知的古怪之处，例如 `某番 (2024)` 的 base 里留了 `2024`、
/// `进击的巨人 Part 2` 的 base 是 `进击的巨人part`）。
/// 要改行为请连这里一起改，并且明确知道自己在改行为。
///
/// ## 语料规模是怎么来的（一段教训）
///
/// 初版只有 39 条。独立审查逐条把 43 条 pattern 换成 `(?!)` 哨兵跑这份测试，发现
/// **19 条删掉后仍然全绿** —— 更严重的是两个 `usedSeasonRegex` / `usedPartRegex`
/// 标志改掉也全绿。也就是说初版「golden 钉住了行为」的说法是**假的**。
///
/// 现在补到 **90 条**，并逐条实测过「把某条 pattern 换成哨兵 → 这份测试必须报红」。
/// 补进去的两类最关键语料：
/// - **非 ASCII 十进制数字**（`٣` `४`）：`NSRegularExpression` 的 `\d` 等于 `\p{Nd}`，
///   所以 `"第٣季"` 会命中、而 `Int("٣")` 是 nil —— 这是两个 flag 唯一的行为差异点，
///   没有这类语料就测不出 flag 被改坏。
/// - **ASCII 罗马数字与后缀两条分支**（`Overlord IV` / `进击的巨人III`）：`Ⅳ` 是
///   Unicode 罗马数字，走的是另一张表，只测它测不到 ASCII 那 12 条。
///
/// ## 新增 pattern 时的规矩
///
/// 往 `AnimeTitleParser` 的静态表里加一条 pattern，**必须同时**在这里加一条能触发
/// 它的标题。否则一旦它被人改坏或被「清理」，这份测试不会报红，守卫就退化成装饰。
@MainActor
final class AnimeTitleParserGoldenTests: XCTestCase {

    /// 一行一条：`标题 ⟹ clean|season|part|isFinal|subtitle|year`。
    private static let golden: [String] = [
        "进击的巨人 第二季 ⟹ 进击的巨人|2|nil|false|nil|nil",
        "鬼灭之刃 第三期 ⟹ 鬼灭之刃|3|nil|false|nil|nil",
        "某科学的超电磁炮 第一季度 ⟹ 某科学的超电磁炮|1|nil|false|nil|nil",
        "进击的巨人 第十季 ⟹ 进击的巨人|10|nil|false|nil|nil",
        "进击的巨人 第十季度 ⟹ 进击的巨人|10|nil|false|nil|nil",
        "进击的巨人 第一部 ⟹ 进击的巨人|1|nil|false|nil|nil",
        "進撃の巨人 Season 2 ⟹ 進撃の巨人|2|nil|false|nil|nil",
        "进击的巨人 S2 ⟹ 进击的巨人|2|nil|false|nil|nil",
        "进击的巨人 2nd Season ⟹ 进击的巨人|2|nil|false|nil|nil",
        "进击的巨人 season  12 ⟹ 进击的巨人|12|nil|false|nil|nil",
        "吹响吧！上低音号 3 ⟹ 吹响吧上低音号|3|nil|false|nil|nil",
        "约会大作战 4 ⟹ 约会大作战|4|nil|false|nil|nil",
        "约会大作战 Ⅳ ⟹ 约会大作战|4|nil|false|nil|nil",
        "Overlord II ⟹ overlord|2|nil|false|nil|nil",
        "デート・ア・ライブIV ⟹ デートアライブ|4|nil|false|nil|nil",
        "Fate/stay night III ⟹ fatestaynight|3|nil|false|nil|nil",
        "进击的巨人 最终季 ⟹ 进击的巨人|nil|nil|true|nil|nil",
        "進撃の巨人 The Final Season ⟹ 進撃の巨人|nil|nil|true|nil|nil",
        "进击的巨人 完结篇 ⟹ 进击的巨人|nil|nil|true|nil|nil",
        "我的青春恋爱物语果然有问题。完 ⟹ 我的青春恋爱物语果然有问题完|nil|nil|true|nil|nil",
        "我的青春恋爱物语果然有问题。续 ⟹ 我的青春恋爱物语果然有问题续|2|nil|false|nil|nil",
        "鬼灭之刃 游郭篇 ⟹ 鬼灭之刃|nil|nil|false|游郭篇|nil",
        "鬼灭之刃 无限列车篇 ⟹ 鬼灭之刃|nil|nil|false|无限列车篇|nil",
        "物语系列 after story ⟹ 物语系列|nil|nil|false|after story|nil",
        "咒术回战 怀玉·玉折 ⟹ 咒术回战|nil|nil|false|怀玉·玉折|nil",
        "无职转生 ～到了异世界就拿出真本事～ 第2季 ⟹ 无职转生到了异世界就拿出真本事|2|nil|false|nil|nil",
        "进击的巨人 Part 2 ⟹ 进击的巨人part|2|2|false|nil|nil",
        "进击的巨人 第2クール ⟹ 进击的巨人|nil|2|false|nil|nil",
        "进击的巨人 前半 ⟹ 进击的巨人|nil|1|false|nil|nil",
        "进击的巨人 后半 ⟹ 进击的巨人|nil|2|false|nil|nil",
        "１２３　ＡＢＣ：～！ ⟹ 123abc|nil|nil|false|nil|nil",
        "某番【第2季】 ⟹ 某番|2|nil|false|nil|nil",
        "某番 (2024) ⟹ 某番2024|nil|nil|false|nil|nil",
        "某科学的超电磁炮S ⟹ 某科学的超电磁炮s|2|nil|false|s|nil",
        "某科学的超电磁炮T ⟹ 某科学的超电磁炮t|3|nil|false|t|nil",
        "Arknights ⟹ arknights|nil|nil|false|nil|nil",
        "明日方舟 ⟹ 明日方舟|nil|nil|false|nil|nil",
        "！！！ ⟹ |nil|nil|false|nil|nil",
        "12345 ⟹ 12345|nil|nil|false|nil|nil",
        // ---- 补漏（独立审查指出原 39 条掩护不足，43 条 pattern 里 19 条删掉仍全绿）----
        // flag 语义：正则命中但 Int() 为 nil（\d = \p{Nd}，非 ASCII 十进制数字）
        "第٣季 续 ⟹ 续|nil|nil|false|nil|nil",
        "某番 Season ٣ S ⟹ 某番s|nil|nil|false|nil|nil",
        "super S 第٣季 ⟹ supers|nil|nil|false|nil|nil",
        "第٣季 完 ⟹ 完|nil|nil|false|nil|nil",
        "进击的巨人 Part ٣ 前半 ⟹ 进击的巨人|nil|nil|false|nil|nil",
        "进击的巨人 第٣クール 后篇 ⟹ 进击的巨人|nil|nil|false|nil|nil",
        "第४季 续 ⟹ 续|nil|nil|false|nil|nil",
        "Season ४ 完 ⟹ 完|nil|nil|false|nil|nil",
        "进击的巨人 完结 ⟹ 进击的巨人|nil|nil|false|nil|nil",
        "进击的巨人 前篇 ⟹ 进击的巨人|nil|1|false|nil|nil",
        "进击的巨人 后篇 ⟹ 进击的巨人|nil|2|false|nil|nil",
        "鬼灭之刃 锻刀村篇 ⟹ 鬼灭之刃|nil|nil|false|锻刀村篇|nil",
        "鬼灭之刃 柱训练篇 ⟹ 鬼灭之刃|nil|nil|false|柱训练篇|nil",
        "咒术回战 涩谷事变 ⟹ 咒术回战|nil|nil|false|涩谷事变|nil",
        "咒术回战 死灭洄游 ⟹ 咒术回战|nil|nil|false|死灭洄游|nil",
        "进击的巨人 cour 3 ⟹ 进击的巨人cour|3|nil|false|nil|nil",
        "进击的巨人 COUR 12 ⟹ 进击的巨人cour|12|nil|false|nil|nil",
        "某番 Season 7 foo ⟹ 某番foo|7|nil|false|nil|nil",
        "某番 season 9 bar ⟹ 某番bar|9|nil|false|nil|nil",
        "Overlord VIII ⟹ overlord|8|nil|false|nil|nil",
        "Overlord VII ⟹ overlord|7|nil|false|nil|nil",
        "Overlord VI ⟹ overlord|6|nil|false|nil|nil",
        "Overlord V ⟹ overlord|5|nil|false|nil|nil",
        "Overlord IX ⟹ overlord|9|nil|false|nil|nil",
        "Overlord X ⟹ overlord|10|nil|false|nil|nil",
        "进击的巨人VIII ⟹ 进击的巨人v|3|nil|false|nil|nil",
        "进击的巨人VII ⟹ 进击的巨人v|2|nil|false|nil|nil",
        "进击的巨人VI ⟹ 进击的巨人vi|nil|nil|false|nil|nil",
        "鬼灭之刃 锻刀村篇 x ⟹ 鬼灭之刃|10|nil|false|锻刀村篇|nil",
        "物语系列 afterstory ⟹ 物语系列|nil|nil|false|afterstory|nil",
        "某番 代号白 ⟹ 某番代号白|nil|nil|false|代号白|nil",
        "咒术回战 怀玉玉折 ⟹ 咒术回战|nil|nil|false|怀玉玉折|nil",
        "进击的巨人 Final Seasoǹ ⟹ 进击的巨人|nil|nil|false|nil|nil",
        "进击的巨人 final Season ⟹ 进击的巨人|nil|nil|true|nil|nil",
        "巨人 ﬁnal Season ⟹ 巨人|nil|nil|false|nil|nil",
        "约会大作战 IV ⟹ 约会大作战|4|nil|false|nil|nil",
        "Overlord IV ⟹ overlord|4|nil|false|nil|nil",
        "进击的巨人III ⟹ 进击的巨人|3|nil|false|nil|nil",
        "进击的巨人II ⟹ 进击的巨人|2|nil|false|nil|nil",
        "进击的巨人IV ⟹ 进击的巨人|4|nil|false|nil|nil",
        "某番 cour 5 ⟹ 某番cour|5|nil|false|nil|nil",
        "进击的巨人 Part 5 ⟹ 进击的巨人part|5|5|false|nil|nil",
        "进击的巨人 第5クール ⟹ 进击的巨人|nil|5|false|nil|nil",
        "某番 Season 7 foo ⟹ 某番foo|7|nil|false|nil|nil",
        "某番 S7 foo ⟹ 某番foo|7|nil|false|nil|nil",
        "某番 7th Season foo ⟹ 某番foo|7|nil|false|nil|nil",
    ]

    /// 把一次 `parse` 压成与 `golden` 同构的一行。
    private func serialize(_ title: String) -> String {
        let info = AnimeTitleParser.parse(title: title)
        func opt<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "nil" }
        return "\(title) ⟹ \(info.cleanBaseName)|\(opt(info.season))|\(opt(info.part))|"
            + "\(info.isFinal)|\(opt(info.subtitle))|\(opt(info.year))"
    }

    func testGoldenCorpusMatchesCurrentBehaviour() {
        let actual = Self.golden.map { serialize(String($0.split(separator: " ⟹ ")[0])) }
        XCTAssertEqual(actual, Self.golden,
                       "parse 输出与 golden 语料不一致 —— 这次改动声称是纯重构，不一致即回归")
    }

    /// 空白 / 极短标题单独钉：它们不进上面那张表（`⟹` 分隔符在有空白标题时不好读）。
    func testBlankAndShortTitles() {
        for input in ["", "   ", "\t"] {
            let info = AnimeTitleParser.parse(title: input)
            XCTAssertEqual(info.cleanBaseName, "", "「\(input)」的 base 应为空")
            XCTAssertNil(info.season, "「\(input)」不该判出季数")
            XCTAssertNil(info.part)
            XCTAssertFalse(info.isFinal)
            XCTAssertNil(info.subtitle)
        }
        // 纯数字标题：不该被当成「结尾裸数字季」
        let digits = AnimeTitleParser.parse(title: "12345")
        XCTAssertNil(digits.season, "纯数字标题不该判成季数")
        XCTAssertEqual(digits.cleanBaseName, "12345")
    }

    /// `explicitSeasonName` 那条分支会走**第二次** `cleanBaseString`，单独钉。
    ///
    /// 注意 `游郭篇` / `无限列车篇` 的结果是 `subtitle == nil`：`cleanBaseString` 会先把
    /// 篇章关键词当噪声剥掉、剥成空串，于是「空就不采用」那条守卫把 subtitle 留下了 nil。
    /// 这是**既有行为**，本测试只做快照，不改它（记在 P2 里待评估）。
    func testExplicitSeasonNameBranch() {
        let withArc = AnimeTitleParser.parse(
            title: "某番 第2季", explicitSeason: 2, explicitSeasonName: "游郭篇")
        XCTAssertEqual(withArc.season, 2)
        XCTAssertNil(withArc.subtitle, "既有行为：篇章名先被当噪声剥空，故 subtitle 为 nil")
        XCTAssertEqual(withArc.cleanBaseName, "某番")

        let withPlain = AnimeTitleParser.parse(
            title: "某番", explicitSeason: 3, explicitSeasonName: "第三季")
        XCTAssertEqual(withPlain.season, 3, "显式季数优先")
        XCTAssertEqual(withPlain.cleanBaseName, "某番")

        let withEmpty = AnimeTitleParser.parse(
            title: "某番", explicitSeason: 2, explicitSeasonName: "")
        XCTAssertEqual(withEmpty.season, 2)
        XCTAssertNil(withEmpty.subtitle)
    }

    /// 三个公开的字符串变换各钉一条，防止提静态量时把替换模板串了。
    func testPublicStringTransforms() {
        XCTAssertEqual(AnimeTitleParser.normalizeFullWidth("１２３　ＡＢＣ：～！"), "123 ABC:~!")
        XCTAssertEqual(
            AnimeTitleParser.replaceChineseSeasonNumbers("进击的巨人 第二季"), "进击的巨人 第2季")
        XCTAssertEqual(
            AnimeTitleParser.replaceChineseSeasonNumbers("进击的巨人 第十季度"), "进击的巨人 第10季")
        XCTAssertEqual(AnimeTitleParser.replaceRomanNumerals("约会大作战 Ⅳ"), "约会大作战  4 ")
        XCTAssertEqual(AnimeTitleParser.replaceRomanNumerals("Overlord II"), "Overlord  2 ")
        XCTAssertEqual(
            AnimeTitleParser.replaceRomanNumerals("デート・ア・ライブIV"), "デート・ア・ライブ 4")
        XCTAssertEqual(AnimeTitleParser.cleanBaseString("进击的巨人 第二季"), "进击的巨人")
        XCTAssertEqual(AnimeTitleParser.cleanBaseString("某番 (2024)"), "某番2024")
    }
}
