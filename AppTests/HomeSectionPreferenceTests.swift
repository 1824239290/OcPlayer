import XCTest
@testable import OcPlayer

/// 首页栏目配置串的编解码：未知值剔除 / 去重 / 空回默认。
final class HomeSectionPreferenceTests: XCTestCase {
    func testDecodeFallsBackToAllCasesWhenEmptyOrGarbage() {
        XCTAssertEqual(HomeSectionPreference.decode(""), HomeSection.allCases)
        XCTAssertEqual(HomeSectionPreference.decode("nope,whatever"), HomeSection.allCases)
    }

    func testDecodeDropsUnknownValues() {
        XCTAssertEqual(HomeSectionPreference.decode("latest,resume"), [.latest, .resume])
    }

    func testDecodeDedupesKeepingFirstOccurrence() {
        XCTAssertEqual(
            HomeSectionPreference.decode("latest,resume,latest"),
            [.latest, .resume])
    }

    func testEncodeRoundtrip() {
        let sections: [HomeSection] = [.libraries, .resume]
        XCTAssertEqual(HomeSectionPreference.decode(HomeSectionPreference.encode(sections)), sections)
    }

    func testDefaultRawDecodesToAllCasesInOrder() {
        XCTAssertEqual(HomeSectionPreference.decode(HomeSectionPreference.defaultRaw), HomeSection.allCases)
    }
}
