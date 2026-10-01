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

        // 「ED 1」整词命中片尾,但名字命中也要过尾部位置门:开头的不算,尾部的才算。
        let edAtHead = evaluator.skipMarks(chapters: [
            chapter(0, "ED 1", start: 0, length: 300, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertTrue(edAtHead.isEmpty, "片头位置的 ED 1 不该产出片尾 mark")

        let edAtTail = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1020, total: 1200),
            chapter(1, "ED 1", start: 1020, length: 180, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(edAtTail.first?.kind, .credits)
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
        // 关联值必须是当前位置（不是片长）：performSkip 用 max(片长−20s, 它) 算落点，
        // 记成片长会往回跳。这个参数名曾经就叫 duration，值却一直是 position。
        guard case .endCredits(let position) = prompt else {
            XCTFail("应该是 .endCredits：\(String(describing: prompt))")
            return
        }
        XCTAssertEqual(position, 1150)
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

    // MARK: - 真实片源章节结构(2026-10 调研)

    /// 欧美剧集真实样本(用户播放中的一集):
    /// Episode 0:00 / Intro 2:52 / Episode 4:22 / Credits 38:08 / Episode 41:10。
    /// 旧版把 0:00 的冷开场剧情当片头(词表缺 intro + 兜底 240s 过宽),新版应锁定 Intro。
    func testScreenshotSample() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Episode", start: 0, length: 172, total: 2610),
            chapter(1, "Intro", start: 172, length: 90, total: 2610),
            chapter(2, "Episode", start: 262, length: 2026, total: 2610),
            chapter(3, "Credits", start: 2288, length: 182, total: 2610),
            chapter(4, "Episode", start: 2470, length: 140, total: 2610),
        ], totalSeconds: 2610)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 172, "片头是 Intro 章节,不是开头的冷开场")
        XCTAssertEqual(marks.first { $0.kind == .opening }?.endSeconds, 262)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.startSeconds, 2288)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.endSeconds, 2470)
        XCTAssertEqual(marks.count, 2, "冷开场与结尾彩蛋都不该有 mark")
    }

    /// 巴哈/VCB-S 系 TV 动画结构:Recap + OP + Part A/B + ED;前情提要不能抢走片头。
    func testRecapBeforeOP() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Recap", start: 0, length: 40, total: 1440),
            chapter(1, "OP", start: 40, length: 90, total: 1440),
            chapter(2, "Part A", start: 130, length: 590, total: 1440),
            chapter(3, "Part B", start: 720, length: 660, total: 1440),
            chapter(4, "ED", start: 1380, length: 60, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 40)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.startSeconds, 1380)
    }

    /// B-Global/巴哈系把 OP 拆成 Part A/B 两章:合并后整段跳,不能只跳一半。
    func testOPPartAdjacencyMerged() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "OP Part A", start: 0, length: 45, total: 1440),
            chapter(1, "OP Part B", start: 45, length: 90, total: 1440),
            chapter(2, "Part B", start: 135, length: 1245, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 0)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.endSeconds, 135)
    }

    /// ED 拆分章同理合并,片尾取最晚合格组;Preview 不是片尾。
    func testEDPartAdjacencyTakesLatestGroup() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1230, total: 1440),
            chapter(1, "ED Part A", start: 1230, length: 45, total: 1440),
            chapter(2, "ED Part B", start: 1275, length: 90, total: 1440),
            chapter(3, "Preview", start: 1365, length: 75, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.startSeconds, 1230)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.endSeconds, 1365, "合并 ED Part A/B,跳到 B 的结尾")
        XCTAssertEqual(marks.count, 1, "Preview 不是片尾")
    }

    /// 多季番/无字版命名:OP1、ED2、NCOP、NCED 都要命中。
    func testNumberedAndNCVariants() {
        let op1 = evaluator.skipMarks(chapters: [
            chapter(0, "OP1", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(op1.first?.kind, .opening)

        let ncop = evaluator.skipMarks(chapters: [
            chapter(0, "NCOP", start: 0, length: 90, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(ncop.first?.kind, .opening)

        let nced = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1020, total: 1200),
            chapter(1, "NCED", start: 1020, length: 180, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(nced.first?.kind, .credits)

        let ed2 = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1020, total: 1200),
            chapter(1, "ED2", start: 1020, length: 180, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(ed2.first?.kind, .credits)
    }

    /// 「Opening Credits」双关名:片尾取最晚合格组,不能让片尾 mark 落在片头区间。
    func testOpeningCreditsOnlyMatchesOpening() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Title Card", start: 0, length: 10, total: 2350),
            chapter(1, "Opening Credits", start: 10, length: 90, total: 2350),
            chapter(2, "正片", start: 100, length: 2050, total: 2350),
            chapter(3, "Credits", start: 2150, length: 200, total: 2350),
        ], totalSeconds: 2350)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 10)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.startSeconds, 2150, "片尾取最晚命中,不是片头的 Opening Credits")
    }

    /// 「Intro Start / Intro End」成对标记:Start 命中,End 是结束点不命中,
    /// 区间恰好 = [Start 起点, End 起点)。
    func testIntroStartEndPair() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Intro Start", start: 0, length: 90, total: 1440),
            chapter(1, "Intro End", start: 90, length: 510, total: 1440),
            chapter(2, "正片", start: 600, length: 780, total: 1440),
            chapter(3, "ED", start: 1380, length: 60, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 0)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.endSeconds, 90)
        XCTAssertEqual(marks.count, 2)
    }

    /// 欧美剧冷开场(Cold Open)是剧情:不跳;真片头是 Main Titles。
    func testColdOpenGoesToMainTitles() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Cold Open", start: 0, length: 180, total: 1440),
            chapter(1, "Main Titles", start: 180, length: 90, total: 1440),
            chapter(2, "正片", start: 270, length: 1110, total: 1440),
            chapter(3, "End Credits", start: 1380, length: 60, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(marks.first { $0.kind == .opening }?.startSeconds, 180, "Cold Open 不该被当片头,Main Titles 才是")
        XCTAssertEqual(marks.first { $0.kind == .opening }?.endSeconds, 270)
    }

    /// 纯 Chapter xx(mkvtoolnix 默认命名)零语义:第一段 172s 超出兜底 120s 上限,
    /// 旧版会误判成片头,新版宁可不出按钮。
    func testGenericLongFirstChapterNoMark() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "Chapter 01", start: 0, length: 172, total: 1440),
            chapter(1, "Chapter 02", start: 172, length: 1208, total: 1440),
            chapter(2, "Chapter 03", start: 1380, length: 60, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertTrue(marks.filter { $0.kind == .opening }.isEmpty)
        XCTAssertEqual(marks.first { $0.kind == .credits }?.startSeconds, 1380, "尾段兜底仍给出片尾")
    }

    /// 繁体命名与简体/日文同权。
    func testTraditionalCJK() {
        let marks = evaluator.skipMarks(chapters: [
            chapter(0, "片頭", start: 0, length: 90, total: 1200),
            chapter(1, "正片", start: 90, length: 930, total: 1200),
            chapter(2, "結尾", start: 1020, length: 180, total: 1200),
        ], totalSeconds: 1200)
        XCTAssertEqual(marks.map(\.kind), [.opening, .credits])
    }

    /// 电影片尾可达 15 分钟:isMovie 放宽片尾时长上限,剧集不行。
    func testMovieCreditsCap() {
        let chapters = [
            chapter(0, "正片", start: 0, length: 3600, total: 4400),
            chapter(1, "Credits", start: 3600, length: 800, total: 4400),
        ]
        XCTAssertNil(
            evaluator.skipMarks(chapters: chapters, totalSeconds: 4400).first { $0.kind == .credits },
            "剧集上限 450s:800s 的片尾不命中"
        )
        XCTAssertNotNil(
            evaluator.skipMarks(chapters: chapters, totalSeconds: 4400, isMovie: true).first { $0.kind == .credits },
            "电影上限 900s:命中"
        )
    }

    /// 门槛边界:181s 的 OP 拒(>180);ED 在 69% 拒、71% 收。
    func testBoundaryGates() {
        let longOP = evaluator.skipMarks(chapters: [
            chapter(0, "OP", start: 0, length: 181, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertTrue(longOP.filter { $0.kind == .opening }.isEmpty, "181s 超出命名命中 180s 上限")

        let earlyED = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 993, total: 1440),
            chapter(1, "ED", start: 993, length: 447, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertNil(earlyED.first { $0.kind == .credits }, "ED 起点在 69%,不到尾部窗口")

        let lateED = evaluator.skipMarks(chapters: [
            chapter(0, "正片", start: 0, length: 1022, total: 1440),
            chapter(1, "ED", start: 1022, length: 418, total: 1440),
        ], totalSeconds: 1440)
        XCTAssertEqual(lateED.first { $0.kind == .credits }?.startSeconds, 1022, "71% 进入尾部窗口")
    }
}