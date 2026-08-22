import Testing
import PlaybackKit
@testable import ErikaKit

/// M0 第 4 步的验收：C ABI 真的通了 —— 能创建 presenter、能查状态、能正常销毁。
@Suite("Erika C ABI 冒烟")
struct ErikaSmokeTests {

    @Test("创建与销毁 presenter 不崩")
    func createDestroy() throws {
        let presenter = try ErikaPresenter()
        _ = presenter  // 出作用域即 deinit → erika_presenter_destroy
    }

    @Test("空闲状态下可读取 stats，且计数为零")
    func statsOnIdle() throws {
        let presenter = try ErikaPresenter()
        let stats = try presenter.stats()
        #expect(stats.decoded_video_frames == 0)
        #expect(stats.render_failures == 0)
    }
}
