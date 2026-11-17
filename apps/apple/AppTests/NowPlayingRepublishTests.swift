import MediaPlayer
import XCTest

@testable import OcPlayer

/// `P2-32`：`nowPlayingInfo` 的重发判据。
///
/// ## 背景
///
/// `nowPlayingInfo` 的 setter 会**跨进程同步**。原实现「快照 != 上次就发」，
/// 而快照含整秒位置 → 播放中每秒一次写入。系统本就按 `playbackRate` 自行外推，
/// 那些写入几乎没有信息量。
///
/// ## 这组用例**真的驱动 `publish()`**
///
/// 第一版只测纯函数 `needsRepublish`（审查阻断级）：把 `publish` 里对它的调用
/// **整段删掉**，9 条用例仍然全绿 —— 测试完全不在生产路径上。
///
/// 现在 `PlaybackNowPlayingCenter` 有一个注入点 `writeNowPlaying`，用例把它换成
/// **计数器桩**，然后真的调 `publish(...)`，数「写了几次」。于是「接线被删」
/// 这种改动会立刻让所有计数类断言归零。
@MainActor
final class NowPlayingRepublishTests: XCTestCase {

    private typealias Center = PlaybackNowPlayingCenter

    /// 造一个装了计数桩 + **可控时钟**的中心。返回中心与 `writes` 的读取闭包。
    ///
    /// 时钟必须注入：否则 `publish()` 循环瞬间跑完、`systemUptime` 几乎不动，
    /// 心跳永不触发、而 seek 判据会因「位置在涨但外推时间≈0」每隔几秒误触发 ——
    /// 实测会得到 1201 次这种毫无意义的数字。
    private func makeCenter(clock: @escaping () -> TimeInterval = { 0 })
        -> (center: Center, writes: () -> Int) {
        let center = Center()
        var count = 0
        center.writeNowPlaying = { _ in count += 1 }
        #if os(macOS)
        center.writePlaybackState = { _ in }
        #endif
        center.now = clock
        return (center, { count })
    }

    /// 一次 `publish` 调用。参数默认是「正常播放中的第 N 秒」。
    private func publish(
        _ center: Center,
        position: Double,
        rate: Double = 1,
        isPlaying: Bool = true,
        duration: Double = 1426,
        title: String = "剧名",
        subtitle: String = "S01E01"
    ) {
        center.setMetadata(title: title, subtitle: subtitle)
        center.publish(
            durationSeconds: duration, positionSeconds: position,
            rate: rate, isPlaying: isPlaying, isActive: true)
    }

    // MARK: - 生产路径（真的经过 publish）

    /// **核心回归：播放中逐秒 publish，只写一次。**
    ///
    /// 这条直接数 `publish()` 实际写了几次 —— 接线被删（恢复每秒都写）时
    /// 这里会读到 30 而不是 1。
    func testPlayingPublishesOncePerHeartbeatNotPerSecond() {
        var clock = 0.0
        let (center, writes) = makeCenter(clock: { clock })
        // 30 秒正常播放，每秒 publish 一次，时钟同步推进。
        for second in 0...30 {
            clock = Double(second)
            publish(center, position: Double(second))
        }
        // 心跳 10 s → 0 s / 10 s / 20 s / 30 s 各一次 = 4 次。
        // 原实现会是 31 次。
        XCTAssertLessThanOrEqual(writes(), 5, "30 秒播放不该写超过约 4 次（原实现 31 次）")
        XCTAssertGreaterThanOrEqual(writes(), 3, "心跳也不能太少")
    }

    /// **一小时 → 约 361 次**（原 3600 次）。走真实 `publish()`。
    func testOneHourPlaybackWritesTenTimesFewer() {
        var clock = 0.0
        let (center, writes) = makeCenter(clock: { clock })
        for second in 0...3600 {
            clock = Double(second)
            publish(center, position: Double(second))
        }
        XCTAssertLessThanOrEqual(writes(), 362, "一小时不该超过约 361 次写入")
        XCTAssertGreaterThanOrEqual(writes(), 358, "心跳也不能太少，否则漂移收不回来")
        XCTAssertLessThan(writes(), 3600 / 9, "写入量应降到原来的约 1/10")
    }

    /// 首次必然写。
    func testFirstPublishWrites() {
        let (center, writes) = makeCenter()
        XCTAssertEqual(writes(), 0)
        publish(center, position: 0)
        XCTAssertEqual(writes(), 1)
    }

    /// 内容变化（标题 / 副标题 / 时长 / 速率）立即写。
    func testContentChangesPublishImmediately() {
        let (center, writes) = makeCenter()
        publish(center, position: 100)
        let baseline = writes()

        publish(center, position: 100, title: "别的剧")
        XCTAssertEqual(writes(), baseline + 1, "标题变了要写")

        publish(center, position: 100, title: "别的剧", subtitle: "S01E02")
        XCTAssertEqual(writes(), baseline + 2, "副标题变了要写")

        publish(center, position: 100, duration: 1500, title: "别的剧", subtitle: "S01E02")
        XCTAssertEqual(writes(), baseline + 3, "时长变了要写")

        publish(center, position: 100, rate: 2, duration: 1500, title: "别的剧", subtitle: "S01E02")
        XCTAssertEqual(writes(), baseline + 4, "速率变了要写")
    }

    /// 暂停（rate 1 → 0 且 isPlaying=false）立即写。
    func testPausePublishesImmediately() {
        let (center, writes) = makeCenter()
        publish(center, position: 100, isPlaying: true)
        let baseline = writes()
        publish(center, position: 100, rate: 0, isPlaying: false)
        XCTAssertEqual(writes(), baseline + 1, "暂停要立刻写，否则系统还在按 1x 外推")
    }

    /// **seek 立即写**（±10 秒按钮、拖进度条）。
    func testSeekPublishesImmediately() {
        let (center, writes) = makeCenter()
        publish(center, position: 100)
        let baseline = writes()
        publish(center, position: 110)          // 跳 10 s
        XCTAssertEqual(writes(), baseline + 1, "seek 必须立即写")
    }

    // MARK: - 纯函数边界（不进 publish 的部分）

    private func needs(
        last: Center.Snapshot?, lastPublishedAt: TimeInterval?,
        position: Double, rate: Double = 1,
        title: String = "剧名", subtitle: String = "S01E01",
        duration: Double = 1426, now: TimeInterval = 100
    ) -> Bool {
        Center.needsRepublish(
            last: last, lastPublishedAt: lastPublishedAt,
            title: title, subtitle: subtitle, durationSeconds: duration,
            positionSeconds: position, rate: rate, now: now)
    }

    private func snapshot(position: Double, rate: Double = 1) -> Center.Snapshot {
        Center.Snapshot(title: "剧名", subtitle: "S01E01",
                        durationSeconds: 1426, positionSeconds: position, rate: rate)
    }

    /// **`rate != 1` 的外推必须带上倍速因子**（审查指出的缺口）。
    ///
    /// 第一版所有用例的 rate 只有 0 和 1，且位置永远按 1x 走 —— 把
    /// `last.rate * elapsed` 改成 `elapsed`，9 条用例**全绿**。
    /// 而 `rate=2` 在生产里可达（长按快进 `applyRate(2.0)`）。
    func testTwoTimesPlaybackExtrapolatesWithRate() {
        let last = snapshot(position: 100, rate: 2)
        // 过了 5.5 s，2x 应该走到 100 + 11 = 111。
        XCTAssertFalse(needs(last: last, lastPublishedAt: 100, position: 111, rate: 2, now: 105.5),
                       "2x 播放时位置按 1x 外推会误判 seek")
        // 少走 3 s（111 → 108）→ 真实偏差 3 s > 2 s 容差 → seek。
        XCTAssertTrue(needs(last: last, lastPublishedAt: 100, position: 108, rate: 2, now: 105.5),
                      "偏差超过容差应判 seek")
    }

    /// **精确位置 vs 取整位置**：基准取整会误判（审查指出的零覆盖行为变更）。
    ///
    /// 上次发布在 100.9，过了 1.4 s（1x）→ 期望 102.3；实际 103.5 → 偏差 1.2 s。
    /// - 精确基准：102.3 vs 103.5 → 差 1.2 s，**在容差内** → 不发。
    /// - 取整基准（100.0）：期望 101.4 vs 103.5 → 差 2.1 s > 2 s → **误发**。
    func testPrecisePositionBaselineAvoidsFalseSeek() {
        let last = snapshot(position: 100.9, rate: 1)
        XCTAssertFalse(
            needs(last: last, lastPublishedAt: 100, position: 103.5, now: 101.4),
            "精确基准下偏差 1.2 s 在容差内，不该判 seek（取整基准会误判成 2.1 s）")
    }

    /// **暂停中的小 seek 必须立即发现**（审查发现的心跳救不了它）。
    ///
    /// 暂停后进度 tick 停了 → `publish()` 不再被调用 → 心跳永远不响。
    /// 所以暂停时容差必须归零：任何位移都是用户操作。
    func testPausedSmallSeekIsDetected() {
        let paused = snapshot(position: 90, rate: 0)
        // 暂停中拖到 91.9（1.9 s）：原实现 2 s 容差会漏判。
        XCTAssertTrue(
            needs(last: paused, lastPublishedAt: 100, position: 91.9, rate: 0, now: 700),
            "暂停中 1.9 s 的位移必须立即发 —— 没有心跳能救它")
        // 对照：播放中同样的 1.9 s 偏差在容差内（由心跳兜底）是可接受的。
        let playing = snapshot(position: 90, rate: 1)
        XCTAssertFalse(
            needs(last: playing, lastPublishedAt: 100, position: 92.9, rate: 1, now: 101),
            "播放中 1.9 s 偏差在容差内，交给心跳")
    }

    /// **暂停中的小 seek 必须立即写 —— 走真实 `publish()`**（审查 S2）。
    ///
    /// 纯函数层已经测过判据，但那条在「容差回退成 2 s」时仍会绿
    /// （因为纯函数里另有一条 `rate == 0` 的判断）。这条**经过 `publish()`**，
    /// 数真实写入次数，才能抓住「容差回退」这种改动。
    ///
    /// 场景：暂停中刚拖了 1.9 s（90 s 短片的滑条约 8 pt，或章节跳转的落点）。
    /// 心跳救不了它 —— 暂停后进度 tick 停了，`publish()` 根本不会再被调用。
    func testPausedSmallSeekWritesImmediately() {
        var clock = 100.0
        let (center, writes) = makeCenter(clock: { clock })
        // 先发布一个「暂停在 90 s」的状态。
        publish(center, position: 90, rate: 0, isPlaying: false)
        let baseline = writes()
        XCTAssertEqual(baseline, 1, "首次发布应写一次")

        // 暂停中拖到 91.9（偏 1.9 s，小于播放态的 2 s 容差）。
        publish(center, position: 91.9, rate: 0, isPlaying: false)
        XCTAssertEqual(writes(), baseline + 1,
                       "暂停中 1.9 s 的位移必须立即写 —— 没有心跳能救它")

        // 对照：播放中同样的 1.9 s 偏差在容差内，不写。
        var clock2 = 200.0
        let (playing, writes2) = makeCenter(clock: { clock2 })
        publish(playing, position: 90, rate: 1, isPlaying: true)
        let b2 = writes2()
        clock2 += 0.5
        publish(playing, position: 92.4, rate: 1, isPlaying: true)   // 期望 90.5，偏 1.9
        XCTAssertEqual(writes2(), b2, "播放中 1.9 s 偏差在容差内，交给心跳")
    }

    /// 心跳：差一点不发、正好发、远超发。
    func testHeartbeatBoundaries() {
        let last = snapshot(position: 100, rate: 1)
        let interval = Center.heartbeatInterval
        XCTAssertFalse(needs(last: last, lastPublishedAt: 100,
                             position: 100 + interval - 0.1, now: 100 + interval - 0.1))
        XCTAssertTrue(needs(last: last, lastPublishedAt: 100,
                            position: 100 + interval, now: 100 + interval))
        XCTAssertTrue(needs(last: last, lastPublishedAt: 100,
                            position: 100 + interval * 3, now: 100 + interval * 3))
    }

    /// 常量合理性。
    func testConstantsAreSane() {
        XCTAssertGreaterThan(Center.heartbeatInterval, Center.seekTolerance * 2)
        XCTAssertGreaterThanOrEqual(Center.seekTolerance, 1)
        XCTAssertLessThanOrEqual(Center.seekTolerance, 5)
    }

    /// `isActive == false` 时清空（走另一条分支）。
    func testInactiveClears() {
        let (center, writes) = makeCenter()
        publish(center, position: 100)
        let afterActive = writes()
        center.publish(durationSeconds: 0, positionSeconds: 0, rate: 0,
                       isPlaying: false, isActive: false)
        XCTAssertEqual(writes(), afterActive + 1, "inactive 应写一次 nil 清空")
    }
}
