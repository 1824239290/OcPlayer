import XCTest
@testable import OcPlayer

/// 章节片头 / 片尾识别评估器的纯逻辑测试(不依赖内核 / 网络)。
final class ChapterSkippingEvaluatorTests: XCTestCase {

    private let evaluator = ChapterNameHeuristicEvaluator()

    private func chapter(_ index: Int, _ name: String, start: Double, length: Double, total: Double) -> PlaybackChapter {
        PlaybackChapter(
            id: index,
            name: name,
            startSeconds: start,
            endSeconds: min(start + length, total)
        )
    }

    // MARK: - 命名识别

    func testOpeningByEnglishKeyword() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "OP — 第一话", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.kind, .opening)
        XCTAssertEqual(marks.first?.endSeconds, 90)
    }

    func testCreditsByChineseKeyword() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "本集乱评", start: 0, length: 1020, total: 1200),
            chapter(1, "片尾", start: 1020, length: 180, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.kind, .credits)
    }

    func testJapaneseOpeningKeyword() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "オープニング", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.kind, .opening)
    }

    // MARK: - 位置兜底

    func testOpeningPositionFallbackWhenNameUnknown() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "第 1 节", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        // 开头的短章节 → 判为片头。
        XCTAssertEqual(marks.map(\.kind), [.opening])
    }

    func testCreditsPositionFallbackWhenNameUnknown() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1150, total: 1300),
            chapter(1, "尾声", start: 1150, length: 150, total: 1300),
        ], totalSeconds: 1300)
        XCTAssertEqual(marks.map(\.kind), [.credits])
    }

    func testNoMarksWhenOnlyMiddleChapters() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "开篇", start: 200, length: 300, total: 1000),
            chapter(1, "中段", start: 500, length: 300, total: 1000),
        ], totalSeconds: 1000)
        XCTAssertTrue(marks.isEmpty, "既不在开头也不在结尾、名字没命中 → 不该弹跳过")
    }

    func testNoMarksWhenOpeningTooLong() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 500, total: 600),
        ], totalSeconds: 600)
        // 500s 的「第一段」远超片头时长上限 → 不判为片头。
        XCTAssertTrue(marks.isEmpty)
    }

    // MARK: - 边界

    func testSkipMarkContainsAndIdentity() {
        let mark = SkipMark(id: "opening-0", kind: .opening, startSeconds: 0, endSeconds: 90)
        XCTAssertTrue(mark.contains(0))
        XCTAssertTrue(mark.contains(89))
        XCTAssertFalse(mark.contains(90))
        XCTAssertEqual(mark.label, "跳过片头")
    }

    func testMultipleOpeningMarksCollapseToOneEarliest() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "OP", start: 0, length: 90, total: 2400),
            chapter(1, "中段一", start: 90, length: 600, total: 2400),
            chapter(2, "OP2", start: 1200, length: 90, total: 2400),
        ], totalSeconds: 2400)
        // 每类只保留最先命中一条。
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.startSeconds, 0)
    }

    // MARK: - 跳过提示(ChapterSession.prompt)

    private func mark(_ kind: SkipKind, start: Double, end: Double) -> SkipMark {
        SkipMark(id: "\(kind.rawValue)-\(Int(start))", kind: kind, startSeconds: start, endSeconds: end)
    }

    func testPromptFiresInsideMarkWhilePlaying() {
        var session = ChapterSession()
        session.skipMarks = [mark(.opening, start: 0, end: 90)]
        let prompt = session.prompt(at: 30, duration: 1200, isPlaying: true)
        XCTAssertEqual(prompt?.kind, .opening)
    }

    func testPromptHidesWhenPaused() {
        var session = ChapterSession()
        session.skipMarks = [mark(.opening, start: 0, end: 90)]
        XCTAssertNil(session.prompt(at: 30, duration: 1200, isPlaying: false))
        XCTAssertNil(session.prompt(at: 1150, duration: 1200, isPlaying: false))
    }

    func testNoneMarkedStillGetsEndCreditsFallbackWithin90s() {
        var session = ChapterSession()
        let prompt = session.prompt(at: 1150, duration: 1200, isPlaying: true)
        XCTAssertEqual(prompt?.kind, .credits)
    }

    func testEndCreditsFallbackRequiresLastMinute30() {
        var session = ChapterSession()
        // 还剩 110s > 90s → 不弹。
        XCTAssertNil(session.prompt(at: 1090, duration: 1200, isPlaying: true))
        // 还剩 89s → 弹。
        XCTAssertEqual(session.prompt(at: 1111, duration: 1200, isPlaying: true)?.kind, .credits)
    }

    func testSkipDedupsMarkWithinSession() {
        var session = ChapterSession()
        let op = mark(.opening, start: 0, end: 90)
        session.skipMarks = [op]
        XCTAssertEqual(session.prompt(at: 30, duration: 1200, isPlaying: true)?.kind, .opening)
        session.noteSkipped(op)
        XCTAssertNil(session.prompt(at: 30, duration: 1200, isPlaying: true))
    }

    func testMarkTakesPriorityOverEndCreditsFallback() {
        var session = ChapterSession()
        session.skipMarks = [mark(.credits, start: 1100, end: 1200)]
        let prompt = session.prompt(at: 1130, duration: 1200, isPlaying: true)
        XCTAssertEqual(prompt?.kind, .credits)
    }

    func testResetClearsSession() {
        var session = ChapterSession()
        session.skipMarks = [mark(.opening, start: 0, end: 90)]
        session.noteSkipped(mark(.opening, start: 0, end: 90))
        session.reset()
        XCTAssertTrue(session.skipMarks.isEmpty)
        XCTAssertTrue(session.chapters.isEmpty)
        // reset 清掉 skipMarks 后,片头不再弹;但 90s 保底与 marks 无关仍会给出片尾提示。
        XCTAssertNil(session.prompt(at: 30, duration: 1200, isPlaying: true), "reset 后无 mark,片头不弹")
        XCTAssertEqual(session.prompt(at: 1150, duration: 1200, isPlaying: true)?.kind, .credits)
    }
}