import BangumiKit
import DanmakuKit
import XCTest
@testable import OcPlayer

/// Bangumi 别名桥：取中文名优先，只认搜索第一条，失败静默降级。
///
/// 回归背景：弹弹play 库里的 `animeTitle` 固定简体中文，日文名召回不稳
/// （实测 `負けヒロインが多すぎる` 搜不到正确作品）；Bangumi 的 `name_cn` 能把
/// 本地日文/罗马音标题换到弹弹play 的主语言。
final class BangumiTitleAliasProviderTests: XCTestCase {

    private static func subject(name: String, nameCN: String) -> BangumiSlimSubjectDTO {
        var subject = BangumiSlimSubjectDTO()
        subject.name = name
        subject.nameCN = nameCN
        return subject
    }

    func testPrefersChineseNameFromTopHit() async {
        let provider = BangumiTitleAliasProvider { _ in
            [Self.subject(name: "負けヒロインが多すぎる！", nameCN: "败犬女主太多了！")]
        }
        let aliases = await provider.aliases(for: "Makeine")
        XCTAssertEqual(aliases, ["败犬女主太多了！", "負けヒロインが多すぎる！"], "中文名优先，原名兜底")
    }

    /// 只取第一条：Bangumi 后续条目常是同名无关作品（实测搜 `Sousou no Frieren`
    /// 第 3 条是《古寺闹鬼记》），拿它们当别名会污染检索词。
    func testOnlyUsesTopHit() async {
        let provider = BangumiTitleAliasProvider { _ in
            [
                Self.subject(name: "葬送のフリーレン", nameCN: "葬送的芙莉莲"),
                Self.subject(name: "古寺のおばけ騒動", nameCN: "古寺闹鬼记"),
            ]
        }
        let aliases = await provider.aliases(for: "Sousou no Frieren")
        XCTAssertEqual(aliases, ["葬送的芙莉莲", "葬送のフリーレン"])
    }

    /// 中文名缺失（空串）或与输入同名的项不进结果。
    func testSkipsEmptyAndIdenticalNames() async {
        let provider = BangumiTitleAliasProvider { _ in
            [Self.subject(name: "Makeine", nameCN: "   ")]
        }
        let aliases = await provider.aliases(for: "Makeine")
        XCTAssertEqual(aliases, [])
    }

    func testSearchFailureDegradesToEmpty() async {
        struct Boom: Error {}
        let provider = BangumiTitleAliasProvider { _ in throw Boom() }
        let aliases = await provider.aliases(for: "Whatever")
        XCTAssertEqual(aliases, [], "别名桥是加分项，失败不得打断匹配")
    }

    func testEmptySearchResult() async {
        let provider = BangumiTitleAliasProvider { _ in [] }
        let aliases = await provider.aliases(for: "某部 Bangumi 没收录的作品")
        XCTAssertEqual(aliases, [])
    }
}
