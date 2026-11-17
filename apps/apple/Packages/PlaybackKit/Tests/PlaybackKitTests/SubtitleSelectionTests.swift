import XCTest
@testable import PlaybackKit

/// 自动选字幕的规则。全是「字符串像不像中文」的启发式，用用例把边界钉住——
/// 片源五花八门（内封轨语言标签为空、语言藏在轨名里、Jellyfin 侧车名只有
/// "简体" 两个字），猜错的代价是用户每次开片都得手动切回来。
final class SubtitleSelectionTests: XCTestCase {

    private func subtitle(
        id: Int64,
        language: String? = nil,
        title: String? = nil,
        source: TrackInfo.Source = .embedded,
        selected: Bool = false
    ) -> TrackInfo {
        .stub(id: id, kind: .subtitle, source: source, selected: selected,
              title: title, language: language, codec: "ass")
    }

    // MARK: - 中文优先

    /// 核心诉求：内核默认选中的是第一条英文字幕，而片子里有中文字幕。
    func testSelectsChineseOverSourceDefault() {
        let tracks = [
            .stub(id: 1, kind: .audio, language: "jpn"),
            subtitle(id: 2, language: "eng", selected: true),
            subtitle(id: 3, language: "chi"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 2),
            .select(3)
        )
    }

    /// 简繁都在时按偏好分：默认简体优先，选繁体档则反过来。
    func testPrefersRequestedScript() {
        let tracks = [
            subtitle(id: 1, title: "繁體中文", selected: true),
            subtitle(id: 2, title: "简体中文"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .select(2)
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseTraditional, current: 2),
            .select(1)
        )
    }

    /// 没标简繁的中文轨要压过明确标了「另一个繁简」的轨：
    /// 「中文」多半就是主字幕，而「繁體」是给另一个地区用户的备选。
    func testUnmarkedChineseBeatsOppositeScript() {
        let tracks = [
            subtitle(id: 1, title: "繁體中文", selected: true),
            subtitle(id: 2, title: "中文"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .select(2)
        )
    }

    /// 一条中文字幕都没有 → 不碰内核的选择（别退回「第一条」）。
    func testKeepsSourceDefaultWhenNoChineseExists() {
        let tracks = [
            subtitle(id: 1, language: "jpn", selected: true),
            subtitle(id: 2, language: "eng"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .keep
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseTraditional, current: 1),
            .keep
        )
    }

    /// 全是外挂字幕、内核无从选择（典型：只有外挂字幕的直连片源）→ 退回第一条，
    /// 保持「有字幕可看」的旧行为。
    func testFallsBackToFirstTrackWhenNothingSelectedAndAllExternal() {
        let tracks = [
            .stub(id: 1, kind: .video),
            subtitle(id: 2, language: "eng", source: .external),
            subtitle(id: 3, language: "jpn", source: .external),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: nil),
            .select(2)
        )
    }

    /// 内封字幕里没有中文、内核也没选任何一条 → 不动。容器「默认不显示字幕」是
    /// 个结论，宿主不能自作主张把第一条外语字幕塞给用户。
    func testEmbeddedTracksWithoutChineseRespectKernelDefaultOff() {
        let tracks = [
            .stub(id: 1, kind: .video),
            subtitle(id: 2, language: "eng"),
            subtitle(id: 3, language: "jpn"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: nil),
            .keep
        )
    }

    /// 没有字幕轨时永远 keep（别对不存在的轨道下发选轨）。
    func testNoSubtitleTracksKeeps() {
        let tracks: [TrackInfo] = [.stub(id: 1, kind: .video), .stub(id: 2, kind: .audio, language: "chi")]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: nil),
            .keep
        )
    }

    /// 音轨上的 "chi" 不算数：只认字幕轨。
    func testIgnoresNonSubtitleTracksWithChineseLanguage() {
        let tracks = [
            .stub(id: 1, kind: .audio, language: "chi"),
            subtitle(id: 2, language: "eng", selected: true),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 2),
            .keep
        )
    }

    // MARK: - 幂等与「不跟用户抢」

    /// 已经选中的就是最优解 → keep（轨道每次刷新都会重算，不能来回下发）。
    func testKeepsCurrentWhenAlreadyBest() {
        let tracks = [subtitle(id: 1, language: "eng"), subtitle(id: 2, language: "chi", selected: true)]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 2),
            .keep
        )
    }

    /// 同档等价候选（都是简体、只是英文轨名不同）→ 保留当前，不为等价项来回切。
    func testKeepsCurrentAmongEquivalentCandidates() {
        let tracks = [
            subtitle(id: 1, language: "jpn"),
            subtitle(id: 2, title: "CHS", selected: true),
            subtitle(id: 3, title: "简体"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 2),
            .keep
        )
    }

    /// 外挂字幕陆续下载完会多次刷新：每次都重算，一旦最优解变成后到的那条就切过去。
    func testSwitchesWhenBetterCandidateArrivesLater() {
        let before = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, language: "chi", title: "繁體"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: before, preference: .chineseSimplified, current: 1),
            .select(2)
        )
        let after = before + [subtitle(id: 3, language: "chi", title: "简体", source: .external)]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: after, preference: .chineseSimplified, current: 2),
            .select(3)
        )
    }

    // MARK: - 另外两档

    /// 跟随文件默认：有中文字幕也不动。
    func testFollowSourceNeverIntervenes() {
        let tracks = [subtitle(id: 1, language: "eng", selected: true), subtitle(id: 2, language: "chi")]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .followSource, current: 1),
            .keep
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .followSource, current: nil),
            .keep
        )
    }

    /// 默认关闭字幕：只在真的选着一条时才下发关闭，免得反复刷。
    func testOffDisablesOnlyWhenSomethingIsSelected() {
        let tracks = [subtitle(id: 1, language: "chi", selected: true)]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .off, current: 1),
            .disable
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .off, current: nil),
            .keep
        )
    }

    // MARK: - 识别（语言标签 / 轨名 / 外挂显示名）

    /// 语言标签的各种写法都要认出来。
    func testRecognizesChineseLanguageTags() {
        for language in ["zh", "zh-CN", "zh-Hans", "ZH", "chi", "zho", "cmn", "Chinese", "Chinese (Simplified)"] {
            let tracks = [
                subtitle(id: 1, language: "eng", selected: true),
                subtitle(id: 2, language: language),
            ]
            XCTAssertEqual(
                SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
                .select(2),
                "语言标签 \(language) 应识别为中文"
            )
        }
    }

    /// 内封轨语言标签常为空，语言藏在轨名里。
    func testRecognizesChineseFromTrackTitleOnly() {
        let tracks = [
            subtitle(id: 1, title: "Japanese", selected: true),
            subtitle(id: 2, title: "简体中文"),
            subtitle(id: 3, title: "CHS&JPN"),
            subtitle(id: 4, title: "中文（繁體）"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .select(2)
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseTraditional, current: 1),
            .select(4)
        )
    }

    /// Jellyfin 侧车字幕的语言元数据不在内核里，靠 App 层显示名判断。
    func testRecognizesExternalSubtitleFromDisplayName() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, source: .external, selected: false),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(
                in: tracks, preference: .chineseSimplified, current: 1, displayNames: [2: "简体"]
            ),
            .select(2)
        )
    }

    /// 日文轨不能因为「字幕」二字被误判成中文。
    func testDoesNotMisreadJapaneseTrack() {
        let tracks = [
            subtitle(id: 1, language: "jpn", title: "日本語字幕", selected: true),
            subtitle(id: 2, language: "eng", title: "English"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .keep
        )
    }

    /// 简体标注的常见写法（发布组 token 风）都要算简体。
    func testRecognizesSimplifiedTokens() {
        for title in ["CHS", "sc", "GB", "简体", "简中", "简体中文", "hans"] {
            let tracks = [
                subtitle(id: 1, language: "jpn", selected: true),
                subtitle(id: 2, title: title),
            ]
            XCTAssertEqual(
                SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
                .select(2),
                "轨名 \(title) 应识别为简体中文"
            )
        }
    }

    // MARK: - 双语轨名（内封 ASS 的常见写法）

    /// 「中日双语」「简日双语」这类轨名要认出来——它们是最常见的内封字幕命名，
    /// 而且这些轨的 `language` 往往是空的，只认语言码会整片漏掉。
    func testRecognizesBilingualTrackTitles() {
        for title in ["中日双语", "中英双语", "简日双语", "繁日双语", "简繁字幕", "粤语"] {
            let tracks = [
                subtitle(id: 1, language: "jpn", title: "日本語", selected: true),
                subtitle(id: 2, title: title),
            ]
            XCTAssertEqual(
                SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
                .select(2),
                "双语轨名 \(title) 应识别为中文"
            )
        }
    }

    // MARK: - 字段可信度（同样是「sc」，在不同字段里含义不同）

    /// 语言字段里的 `sc` 是**撒丁语**（ISO 639-1），不是「简体中文」的发布组标注。
    func testSardinianLanguageTagIsNotSimplifiedChinese() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, language: "sc"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .keep,
            "语言码 sc（撒丁语）不该被当成简体中文"
        )
    }

    /// 同一串 `sc` 出现在**轨名**里就是发布组写法（Simplified Chinese）。
    func testShortScriptTokenCountsInTrackTitle() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, title: "sc"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .select(2)
        )
    }

    /// App 层显示名的兜底可能是 `codec.uppercased()`（外部输入），短 token 在这里
    /// 不算数——否则一条 codec 恰好叫 "sc" 的字幕会被误当简体中文抢走选择。
    func testShortScriptTokenInExternalDisplayNameIsIgnored() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, source: .external),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(
                in: tracks, preference: .chineseSimplified, current: 1, displayNames: [2: "SC"]
            ),
            .keep,
            "显示名里的短 token 不足以判定中文"
        )
        // 但显示名里出现完整中文词仍然算（Jellyfin 的流标题就是这种）。
        XCTAssertEqual(
            SubtitleTrackSelector.selection(
                in: tracks, preference: .chineseSimplified, current: 1, displayNames: [2: "简体"]
            ),
            .select(2)
        )
    }

    /// 轨名与语言码**互相矛盾**（muxer 常把整条轨的语言码标错）时降级为「未标注」，
    /// 让另一个结论明确的中文轨以更高分胜出——而不是选到与偏好相反的那条。
    func testConflictingLanguageAndTitleSignalsDegradeGracefully() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, language: "zh-Hans", title: "繁體"),
            subtitle(id: 3, language: "zh", title: "简体"),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .chineseSimplified, current: 1),
            .select(3),
            "名字写着「繁體」但语言码写 zh-Hans 的轨应降级，让「简体」以 120 分胜出"
        )
    }

    // MARK: - 全外挂轨道的兜底（加偏好之前的既有行为）

    /// 只有外挂字幕（内封没有字幕轨）：内核对外挂轨完全不碰，一条都不选，
    /// 宿主必须兜一条——`followSource` 档也照旧，否则用户看到「有字幕却不显示」。
    func testAllExternalFallbackAppliesToFollowSourceToo() {
        let tracks = [
            .stub(id: 1, kind: .video),
            subtitle(id: 2, language: "jpn", source: .external),
            subtitle(id: 3, language: "eng", source: .external),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .followSource, current: nil),
            .select(2)
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .off, current: nil),
            .keep,
            "「默认关闭」档不该被兜底打开"
        )
    }

    /// 内封轨存在时，`followSource` 仍然彻底不干预。
    func testFollowSourceKeepsHandsOffWithEmbeddedTracks() {
        let tracks = [
            subtitle(id: 1, language: "eng", selected: true),
            subtitle(id: 2, language: "chi", source: .external),
        ]
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .followSource, current: 1),
            .keep
        )
        XCTAssertEqual(
            SubtitleTrackSelector.selection(in: tracks, preference: .followSource, current: nil),
            .keep,
            "有内封轨时内核已经选过（或有意不选），跟随档不该兜底"
        )
    }
}
