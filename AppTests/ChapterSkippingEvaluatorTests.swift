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

    // MARK: - 词边界（op/ed 不能命中单词中段）

    func testTwoLetterKeywordRequiresWordBoundary() {
        // "Operations & Bonus" 含 "op"，但不能判成片头；"Media" 含 "ed"，不能判成片尾。
        let chapters = [
            chapter(0, "Operations & Bonus", start: 0, length: 300, total: 1200),
            chapter(1, "Media", start: 300, length: 900, total: 1200),
        ]
        let marks = evaluator.skipMarks(chapters: chapters, totalSeconds: 1200)
        XCTAssertTrue(marks.isEmpty, "options/media 是单词中段出现 op/ed，不该命中")
    }

    func testTwoLetterKeywordStillMatchesWholeWord() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "OP", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.first?.kind, .opening)

        // 「ED 1」在片头位置会命中位置兜底，把长度抬过片头 240s 上限，只验证词边界命中。
        let ed = evaluator.skipMarks(chapters: [
            chapter(0, "ED 1", start: 0, length: 300, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(ed.first?.kind, .credits)
    }

    func testCJKKeywordKeepsSubstringMatching() {
        // 无词边界概念：片头曲/片尾曲这种组合名也要命中「片头」/「片尾」。
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "片头曲", start: 0, length: 90, total: 1200),
            chapter(1, "片尾曲", start: 1110, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.map(\.kind), [.opening, .credits])
    }

    func testMultiWordKeywordStillMatchesSubstring() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1000, total: 1200),
            chapter(1, "Ending Credits", start: 1000, length: 200, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.map(\.kind), [.credits])
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
        let mark = SkipMark(id: "opening-0", source: .chapterHeuristic, kind: .opening, startSeconds: 0, endSeconds: 90)
        XCTAssertTrue(mark.contains(0))
        XCTAssertTrue(mark.contains(89))
        XCTAssertFalse(mark.contains(90))
        XCTAssertEqual(mark.label, "跳过片头")
    }

    // MARK: - 当前章节(currentIndex)

    private func segment(_ index: Int, start: Double, end: Double?) -> PlaybackChapter {
        PlaybackChapter(id: index, name: "C\(index)", startSeconds: start, endSeconds: end)
    }

    func testCurrentIndexTracksPositionWithinChapter() {
        let chapters = [
            segment(0, start: 0, end: 90),
            segment(1, start: 90, end: 600),
            segment(2, start: 600, end: 1200),
        ]
        XCTAssertEqual(PlaybackChapter.currentIndex(in: chapters, at: 0), 0)
        XCTAssertEqual(PlaybackChapter.currentIndex(in: chapters, at: 89), 0)
        XCTAssertEqual(PlaybackChapter.currentIndex(in: chapters, at: 90), 1)
        XCTAssertEqual(PlaybackChapter.currentIndex(in: chapters, at: 1199), 2)
        XCTAssertNil(PlaybackChapter.currentIndex(in: chapters, at: 1200), "end 是开区间，恰好等于片长不归属任何章节")
    }

    func testCurrentIndexHandlesChapterWithUnknownEnd() {
        let chapters = [segment(0, start: 0, end: 90), segment(1, start: 90, end: nil)]
        XCTAssertEqual(PlaybackChapter.currentIndex(in: chapters, at: 5000), 1, "end 未知时按起点归属")
    }

    func testCurrentIndexReturnsNilInGapOrEmpty() {
        let chapters = [segment(0, start: 0, end: 90), segment(1, start: 120, end: 600)]
        XCTAssertNil(PlaybackChapter.currentIndex(in: chapters, at: 100), "章节间隙不归属任何章节")
        XCTAssertNil(PlaybackChapter.currentIndex(in: [], at: 0))
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

    private func mark(_ kind: SkipKind, start: Double, end: Double, source: SkipMarkSource = .chapterHeuristic) -> SkipMark {
        SkipMark(id: "\(kind.rawValue)-\(Int(start))", source: source, kind: kind, startSeconds: start, endSeconds: end)
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

    // MARK: - 弹幕片头提示注入(applyDanmakuIntroHint)

    func testDanmakuHintInjectsOpeningMark() {
        var session = ChapterSession()
        let applied = session.applySkipTimesHint(startSeconds: 98, endSeconds: 198, source: .danmaku)
        XCTAssertTrue(applied)
        XCTAssertEqual(session.skipMarks.count, 1)
        XCTAssertEqual(session.skipMarks.first?.source, .danmaku)
        XCTAssertEqual(session.skipMarks.first?.kind, .opening)
        XCTAssertEqual(session.skipMarks.first?.startSeconds, 98)
        // 提示注入后与普通 mark 一样驱动提示与 seek。
        XCTAssertEqual(session.prompt(at: 120, duration: 1420, isPlaying: true)?.kind, .opening)
        session.noteSkipped(session.skipMarks[0])
        XCTAssertNil(session.prompt(at: 120, duration: 1420, isPlaying: true))
    }

    func testDanmakuHintWithoutStartFallsBackToZero() {
        var session = ChapterSession()
        session.applySkipTimesHint(startSeconds: nil, endSeconds: 95, source: .danmaku)
        XCTAssertEqual(session.skipMarks.first?.startSeconds, 0)
        XCTAssertEqual(session.prompt(at: 30, duration: 1420, isPlaying: true)?.kind, .opening)
    }

    func testDanmakuHintReplacesHeuristicOpeningButYieldsToMediaSegment() {
        // 章节启发式的片头让位给弹幕实证。
        var session = ChapterSession()
        session.skipMarks = [mark(.opening, start: 0, end: 60)]
        XCTAssertTrue(session.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku))
        XCTAssertEqual(session.skipMarks.count, 1)
        XCTAssertEqual(session.skipMarks.first?.source, .danmaku)
        XCTAssertEqual(session.skipMarks.first?.endSeconds, 132)

        // 服务端智能识别的片头最准,弹幕让位。
        var segmentSession = ChapterSession()
        segmentSession.skipMarks = [mark(.opening, start: 40, end: 130, source: .mediaSegment)]
        XCTAssertFalse(segmentSession.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku))
        XCTAssertEqual(segmentSession.skipMarks.count, 1)
        XCTAssertEqual(segmentSession.skipMarks.first?.source, .mediaSegment)
    }

    func testDanmakuHintKeepsCreditsMarksUntouched() {
        var session = ChapterSession()
        session.skipMarks = [mark(.credits, start: 1100, end: 1200)]
        session.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku)
        XCTAssertEqual(session.skipMarks.count, 2)
        XCTAssertTrue(session.skipMarks.contains { $0.kind == .credits })
    }

    func testDanmakuHintRejectsNonsensicalRange() {
        var session = ChapterSession()
        XCTAssertFalse(session.applySkipTimesHint(startSeconds: 0, endSeconds: 0.5, source: .danmaku))
        XCTAssertFalse(session.applySkipTimesHint(startSeconds: 200, endSeconds: 100, source: .danmaku))
        XCTAssertTrue(session.skipMarks.isEmpty)
        // 起点 ≥ 终点 - 1 的退化窗口也拒绝。
        XCTAssertFalse(session.applySkipTimesHint(startSeconds: 198, endSeconds: 198.5, source: .danmaku))
        XCTAssertTrue(session.skipMarks.isEmpty)
    }

    func testRepeatedDanmakuHintUpdatesSameMarkID() {
        // 换源重匹配后提示更新时,同一 id 原位替换,skippedIDs 去重不受影响。
        var session = ChapterSession()
        session.applySkipTimesHint(startSeconds: 0, endSeconds: 120, source: .danmaku)
        session.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku)
        XCTAssertEqual(session.skipMarks.count, 1)
        XCTAssertEqual(session.skipMarks.first?.endSeconds, 132)
        XCTAssertEqual(session.skipMarks.first?.id, "skiptimes-opening")
    }

    func testAniSkipHintReplacesDanmakuButYieldsToMediaSegment() {
        // AniSkip 有社区投票背书,同集先弹幕后 AniSkip 时原位升级。
        var session = ChapterSession()
        session.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku)
        XCTAssertTrue(session.applySkipTimesHint(startSeconds: 88, endSeconds: 178, source: .aniskip))
        XCTAssertEqual(session.skipMarks.count, 1)
        XCTAssertEqual(session.skipMarks.first?.source, .aniskip)
        XCTAssertEqual(session.skipMarks.first?.startSeconds, 88)

        // 反向不覆盖:AniSkip 在场时迟到的弹幕提示让位。
        XCTAssertFalse(session.applySkipTimesHint(startSeconds: 0, endSeconds: 132, source: .danmaku))
        XCTAssertEqual(session.skipMarks.first?.startSeconds, 88)
    }
}