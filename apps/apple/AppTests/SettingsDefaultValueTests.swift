import XCTest
@testable import OcPlayer

/// 「默认开」开关的读取语义。
///
/// 坑：`@AppStorage` / Toggle 只把用户拨过的值写盘，默认值从不落盘；键不存在时
/// `bool(forKey:)` 返回 false，把「默认开」误判成关。实战后果是 Bangumi 自动标看过
/// 对全新安装永久静默失效（review-20260914 P1-2）。`bool(forKey:default:)` 把
/// 「键不存在 → fallback」做成显式语义。
final class SettingsDefaultValueTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ocplayer.tests.settings-default.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// bug 本体：键从未写过（用户没拨过开关）时回默认值 true，而不是裸读取的 false。
    func testAbsentKeyReturnsProvidedDefault() {
        XCTAssertNil(defaults.object(forKey: "missing.key"), "前提：键确实不存在")
        XCTAssertTrue(
            defaults.bool(forKey: "missing.key", default: true),
            "键不存在时要回调用方给的默认值，不能是 bool(forKey:) 的 false"
        )
    }

    /// 用户显式关掉过：读到 false，不受默认值影响。
    func testExplicitFalseIsHonored() {
        defaults.set(false, forKey: "flag.key")
        XCTAssertFalse(defaults.bool(forKey: "flag.key", default: true))
    }

    /// 用户显式打开过：读到 true，即使调用方给的默认是 false。
    func testExplicitTrueOverridesDefaultFalse() {
        defaults.set(true, forKey: "flag.key")
        XCTAssertTrue(defaults.bool(forKey: "flag.key", default: false))
    }
}
