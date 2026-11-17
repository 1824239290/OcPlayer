import XCTest
@testable import OcPlayer

/// 首页栏目布局的编解码：未知值剔除 / 去重 / 缺项迁移 / 关掉不丢位置 / 空串 = 全关。
///
/// 这份用例守的是一个真实反馈：**关掉栏目后它从设置页直接消失，再也打不开**——
/// 因为旧格式只存「显示中的栏目」，关掉 = 从串里删掉 = 没入口。现在串里永远
/// 列全部栏目（`-` 前缀 = 已关闭），位置也保住。
final class HomeSectionPreferenceTests: XCTestCase {

    /// 全序永远是四栏的一个排列（归一化不变量），逐个用例都拿它兜底。
    private func assertOrderIsAPermutation(_ layout: HomeSectionLayout, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.order.count, HomeSection.allCases.count, file: file, line: line)
        XCTAssertEqual(Set(layout.order), Set(HomeSection.allCases), file: file, line: line)
    }

    // MARK: - 默认串

    /// 缺省串必须与历史字面一致：默认用户升上来零迁移、也不会被无谓重写。
    func testDefaultRawKeepsHistoricalLiteral() {
        XCTAssertEqual(HomeSectionPreference.defaultRaw, "resume,nextUp,latest,libraries")
    }

    func testDefaultRawDecodesToAllCasesInOrder() {
        let layout = HomeSectionPreference.decode(HomeSectionPreference.defaultRaw)
        XCTAssertEqual(layout.order, HomeSection.allCases)
        XCTAssertEqual(layout.visible, HomeSection.allCases)
        XCTAssertTrue(layout.hidden.isEmpty)
    }

    // MARK: - 旧格式迁移（升级兼容）

    /// 旧串「只列显示项，缺项 = 隐藏」：已列项保序显示，缺项标为已关闭并归位。
    /// 关键断言是 `visible`——升级后首页渲染的栏目与顺序必须与升级前一致。
    func testLegacyRawKeepsListedVisibleAndMissingHiddenAtNaturalPosition() {
        let layout = HomeSectionPreference.decode("resume,latest,libraries")
        XCTAssertEqual(layout.visible, [.resume, .latest, .libraries], "首页渲染与升级前一致")
        XCTAssertEqual(layout.order, HomeSection.allCases, "缺项回到自然位置，不堆到末尾")
        XCTAssertEqual(layout.hidden, [.nextUp])
    }

    /// 常见形态（用户沿默认顺序用过、只关掉其中几栏）：缺项全部回到原位，
    /// 设置页升上来就是「默认顺序 + 相应的开关关着」，看不出迁移痕迹。
    func testLegacyRawWithNaturalOrderHolesDecodesToDefaultOrder() {
        let cases: [(raw: String, visible: [HomeSection])] = [
            ("resume", [.resume]),
            ("libraries", [.libraries]),
            ("resume,nextUp,libraries", [.resume, .nextUp, .libraries]),
            ("nextUp,latest", [.nextUp, .latest]),
        ]
        for (raw, visible) in cases {
            let layout = HomeSectionPreference.decode(raw)
            XCTAssertEqual(layout.visible, visible, "「\(raw)」的显示项")
            XCTAssertEqual(layout.order, HomeSection.allCases, "「\(raw)」的缺项归位")
        }
    }

    /// 旧串本身是被用户重排过的（没记录的缺项只能挑一个稳定位置）：
    /// 已列项的**相对顺序**必须原样保住。
    func testLegacyRawPreservesListedRelativeOrderWhenReordered() {
        let layout = HomeSectionPreference.decode("libraries,nextUp")
        assertOrderIsAPermutation(layout)
        XCTAssertEqual(layout.visible, [.libraries, .nextUp], "已列项相对顺序不动")
        XCTAssertEqual(layout.hidden, [.resume, .latest])
    }

    /// 损坏串（一个已知项都没有）：回默认全开，与改动前行为一致。
    func testGarbageRawFallsBackToAllVisible() {
        XCTAssertEqual(HomeSectionPreference.decode("nope,whatever").visible, HomeSection.allCases)
    }

    /// 空串 = 旧版的「全关」（`encode([])` 就是空串），是用户的明确选择，不再回默认全开。
    func testEmptyRawMeansEverythingClosed() {
        let layout = HomeSectionPreference.decode("")
        XCTAssertTrue(layout.visible.isEmpty)
        XCTAssertEqual(layout.order, HomeSection.allCases, "全关也保住顺序，打开即回原位")
        XCTAssertEqual(layout.hidden, Set(HomeSection.allCases))
    }

    // MARK: - 新格式

    func testDecodeDropsUnknownValues() {
        let layout = HomeSectionPreference.decode("latest,resume")
        assertOrderIsAPermutation(layout)
        XCTAssertEqual(layout.visible, [.latest, .resume])
        XCTAssertEqual(layout.hidden, [.nextUp, .libraries])
    }

    /// 重复项按首次出现定案：串里多写一次不改结果。
    func testDecodeDedupesKeepingFirstOccurrence() {
        XCTAssertEqual(
            HomeSectionPreference.decode("latest,resume,latest"),
            HomeSectionPreference.decode("latest,resume"))
        XCTAssertEqual(
            HomeSectionPreference.decode("resume,resume,-libraries"),
            HomeSectionPreference.decode("resume,-libraries"))
    }

    /// 显隐标志也按首次出现定案（后写的标志不生效）。
    func testDecodeVisibilityFlagFollowsFirstOccurrence() {
        XCTAssertTrue(HomeSectionPreference.decode("resume,-resume").isVisible(.resume))
        XCTAssertFalse(HomeSectionPreference.decode("-resume,resume").isVisible(.resume))
    }

    /// 容忍手改串里的空格。
    func testDecodeTrimsWhitespaceAroundTokens() {
        let layout = HomeSectionPreference.decode(" latest , -resume ")
        assertOrderIsAPermutation(layout)
        XCTAssertEqual(layout.visible, [.latest])
        XCTAssertEqual(layout.hidden, [.resume, .nextUp, .libraries])
    }

    func testEncodeMarksHiddenWithDashPrefixAndRoundtrips() {
        let layout = HomeSectionLayout.allVisible
            .setting(.nextUp, visible: false)
            .setting(.libraries, visible: false)
        let raw = HomeSectionPreference.encode(layout)
        XCTAssertEqual(raw, "resume,-nextUp,latest,-libraries")
        XCTAssertEqual(HomeSectionPreference.decode(raw), layout)
        XCTAssertEqual(HomeSectionPreference.encode(HomeSectionPreference.decode(raw)), raw)
    }

    // MARK: - 设置页行来源（本次反馈的核心验收）

    /// 设置页的行来自 `layout.order`：**不论串长什么样，永远是全部栏目**。
    /// 这正是「关掉的行还在设置页、随时能再打开」这条验收的模型层保证——
    /// 旧实现的行来源是「存下来的显示项」，关掉就从列表里没了。
    func testOrderAlwaysListsEverySectionSoSettingsKeepsEveryRow() {
        let raws = [
            "",                                     // 旧版全关
            "resume",                               // 旧版只留一栏
            "resume,latest,libraries",              // 旧版关掉「接下来看」
            "nope,whatever",                        // 损坏串
            "latest,resume,latest",                 // 重复
            "resume,-nextUp,latest,-libraries",     // 新格式：关两栏
            " nextUp ",                             // 带空格
            "-",                                    // 只有一个标志位
            ",," ,                                  // 只有分隔符
        ]
        for raw in raws {
            // 保证是「每栏恰好一行」，不保证排列一定是默认顺序：串被重排过时，
            // 缺项只能挑一个稳定位置（见 testLegacyRawPreservesListedRelativeOrderWhenReordered）。
            let order = HomeSectionPreference.decode(raw).order
            XCTAssertEqual(order.count, HomeSection.allCases.count, "「\(raw)」不缺项也不重复")
            XCTAssertEqual(Set(order), Set(HomeSection.allCases), "「\(raw)」也要列出全部栏目")
        }
    }

    // MARK: - 开关与排序的行为（用户可见语义）

    /// 关掉再打开**回到原位置**，不是追加到末尾——顺序信息不再随「关闭」丢失。
    func testHidingAndShowingKeepsPosition() {
        let hidden = HomeSectionLayout.allVisible.setting(.latest, visible: false)
        XCTAssertEqual(hidden.order, HomeSection.allCases)
        XCTAssertEqual(hidden.visible, [.resume, .nextUp, .libraries])

        let shown = hidden.setting(.latest, visible: true)
        XCTAssertEqual(shown.visible, HomeSection.allCases)
        XCTAssertEqual(HomeSectionPreference.encode(shown), HomeSectionPreference.defaultRaw)
    }

    func testSettingIsIdempotent() {
        let layout = HomeSectionLayout.allVisible.setting(.resume, visible: false)
        XCTAssertEqual(layout.setting(.resume, visible: false), layout)
        XCTAssertEqual(layout.setting(.resume, visible: true).setting(.resume, visible: true), .allVisible)
    }

    func testMovingSwapsNeighboursAndStopsAtBounds() {
        let all = HomeSectionLayout.allVisible
        XCTAssertEqual(all.moving(.resume, by: -1), all, "第一项上移是空操作")
        XCTAssertEqual(all.moving(.libraries, by: 1), all, "最后一项下移是空操作")
        XCTAssertEqual(all.moving(.nextUp, by: -1).order, [.nextUp, .resume, .latest, .libraries])
        XCTAssertEqual(all.moving(.libraries, by: -1).order, [.resume, .nextUp, .libraries, .latest])
    }

    /// 已关闭的栏目照样能排序，且移动它**不改变首页可见顺序**（可以先排好再打开）。
    func testMovingHiddenSectionKeepsVisibleOrderAndHiddenState() {
        let layout = HomeSectionLayout.allVisible
            .setting(.nextUp, visible: false)
            .moving(.nextUp, by: 1)
        XCTAssertEqual(layout.order, [.resume, .latest, .nextUp, .libraries])
        XCTAssertEqual(layout.visible, [.resume, .latest, .libraries])
        XCTAssertEqual(layout.hidden, [.nextUp])
    }

    // MARK: - 构造归一化

    func testInitNormalizesOrderToAllCases() {
        XCTAssertEqual(HomeSectionLayout(order: [.libraries, .libraries]).order,
                       [.libraries, .resume, .nextUp, .latest])
        XCTAssertEqual(HomeSectionLayout(order: []).order, HomeSection.allCases)
        XCTAssertEqual(HomeSectionLayout(order: []).hidden, [])
    }
}
