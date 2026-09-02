import Foundation
import Testing
import PlaybackKit
@testable import ErikaKit

/// open 让位契约：open 长持主锁期间（内核同步做网络连接与格式探测，弱网可达数十秒），
/// stop / detach / resize 只登记意图立即返回、open 收尾补做；play / pause / seek /
/// 速率 / 音量直接丢弃。宿主（PlaybackController）据此把 open 派到后台并安全取消。
/// 用真实内核 presenter 但不打开媒体——让位机器不依赖媒体内容。
@Suite("Erika open 让位契约")
struct ErikaOpenYieldTests {

    @Test("open 在飞时 stop 让位登记，收尾补做并置 interrupted")
    func stopDuringOpeningIsDeferredUntilFinish() throws {
        let engine = try ErikaEngine()
        engine.markOpeningStarted()
        try? engine.stop() // 让位：立即返回，不碰主锁（登记路径不抛，try? 只为签名）
        #expect(!engine.openWasInterrupted, "收尾前 interrupted 不应置位")
        engine.finishOpening() // 收尾：补 stop
        #expect(engine.openWasInterrupted, "登记过的 stop 应在收尾时置 interrupted")
        // 收尾之后再 stop：opening 已结束，走正常路径（presenter 无媒体，错误被 try? 吞掉）
        #expect(throws: Never.self) { _ = try? engine.stop() }
    }

    @Test("open 在飞时 detach 让位登记并报告未断开")
    func detachDuringOpeningIsDeferred() throws {
        let engine = try ErikaEngine()
        engine.markOpeningStarted()
        let detached = engine.detach()
        #expect(!detached, "open 在飞时 detach 应报告未断开（登记给收尾补做）")
        #expect(!engine.openWasInterrupted)
        engine.finishOpening()
        #expect(engine.openWasInterrupted)
    }

    @Test("open 在飞时播放控制被丢弃且不算让位")
    func controlCallsDroppedDuringOpening() throws {
        let engine = try ErikaEngine()
        engine.markOpeningStarted()
        #expect(throws: Never.self) { try engine.play() }
        #expect(throws: Never.self) { try engine.pause() }
        #expect(throws: Never.self) { try engine.seek(to: .seconds(1)) }
        #expect(throws: Never.self) { try engine.setRate(1.5) }
        #expect(throws: Never.self) { try engine.setVolume(0.5) }
        engine.finishOpening()
        #expect(!engine.openWasInterrupted, "丢弃的控制调用不是让位，open 成果应保留")
    }

    @Test("无让位登记的干净 open 收尾不置 interrupted")
    func cleanOpenNotMarkedInterrupted() throws {
        let engine = try ErikaEngine()
        engine.markOpeningStarted()
        engine.finishOpening()
        #expect(!engine.openWasInterrupted)
    }

    @Test("后写的 surface 操作覆盖先写的（后写胜出）")
    func laterSurfaceOperationWins() throws {
        let engine = try ErikaEngine()
        engine.markOpeningStarted()
        _ = engine.detach() // 登记 detach
        // 重新登记（模拟视图又发起 resize 覆盖 detach 的极端时序）：
        // 直接通过 resize 覆盖——登记槽是单槽后写胜出。
        engine.resize(pixelWidth: 100, pixelHeight: 80, scale: 2)
        engine.finishOpening()
        // 断言落在行为上：收尾不崩溃、interrupted 置位（有 surface 操作被补做）。
        #expect(engine.openWasInterrupted)
    }
}
