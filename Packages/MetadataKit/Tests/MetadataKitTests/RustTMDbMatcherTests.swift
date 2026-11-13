import CoreModel
import Foundation
import XCTest
@testable import MetadataKit

#if os(macOS)
final class RustTMDbMatcherTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for shared TMDB matching")
        }
        return path
    }
    private func core() throws -> RustTMDbMatcher {
        let path = try library()
        return try XCTUnwrap(RustTMDbMatcher.make(libraryPath: path))
    }
    private func item(_ name: String, kind: MediaItem.Kind = .series,
                      year: Int? = nil, original: String? = nil) -> MediaItem {
        var value = MediaItem(id: "fixture", name: name, kind: kind)
        value.year = year; value.originalTitle = original
        return value
    }

    func testReferenceUnicodeNormalizationAndYearCorpus() throws {
        let rust = try core()
        var titles: [String?] = [nil, "", "ガ", "カ\u{3099}", "ﾊ\u{309A}", "Cafe\u{301}", "Café",
                                "ΟΣ", "ΟΣ\u{301}", "① Ⅳ ﬃ ²", "Show 1st Season", "season2ndseason",
                                "show 第２季", "(1800) (2024)", "(2100)", "(2101)",
                                "(２０１９) (2024)", "(一二三四) (2024)", "(2019)\0tail",
                                "Show 第2\u{301}季", "Show season2\u{301}", "(2\u{301}024)",
                                "漢字\u{FE0F} 第十季", "한 Season 99",
                                "(2\u{301}019) (2024)", "(\u{FE0F}2019)", "(2019)\u{FE0F}",
                                "Show 第\u{FE0F}2季", "Show 第2季\u{FE0F}"]
        for number in ["2", "一", "Ⅲ", "²", "②", "١"] {
            for mark in ["\u{301}", "\u{200D}", "\u{200C}", "\u{FE0F}", "\u{20E3}", "\u{93E}", "\u{301}\u{345}"] {
                titles.append("Show 第\(number)\(mark)季")
                titles.append("Show season\(number)\(mark)")
            }
        }
        for code in UInt32(0)...UInt32(0x10FFFF) {
            guard let scalar = Unicode.Scalar(code) else { continue }
            let value = String(scalar)
            if Character(value).isNumber {
                titles.append("Show 第\(value)季")
                titles.append("Show \(value)ndseason")
                titles.append("Show (\(value)\(value)\(value)\(value)) (2024)")
            }
            if CharacterSet.nonBaseCharacters.contains(scalar) {
                titles.append("Show 第2\(value)季")
                titles.append("Show season2\(value)")
            }
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || value.lowercased() != value || (0x3000...0x30FF).contains(code)
                || (0xFF00...0xFFEF).contains(code) {
                titles.append("A\(value)B")
            }
        }
        for offset in stride(from: 0, to: titles.count, by: 256) {
            let chunk = Array(titles[offset..<min(offset + 256, titles.count)])
            let reply = try rust.call(.init(operation: "normalize", titles: chunk))
            let normalized = try XCTUnwrap(reply.normalized)
            let years = try XCTUnwrap(reply.years)
            XCTAssertEqual(normalized.count, chunk.count)
            for (index, raw) in chunk.enumerated() {
                // Compare scalars, since Swift equality hides canonical differences.
                XCTAssertEqual(normalized[index].unicodeScalars.map(\.value),
                               TitleNormalizer.normalize(raw).unicodeScalars.map(\.value),
                               "Normalization \(String(describing: raw))")
                XCTAssertEqual(years[index], TitleNormalizer.year(fromTitle: raw),
                               "Year \(String(describing: raw))")
            }
        }
    }

    func testAllScoreTiersStableAlternativesAndExactIdentifiers() throws {
        let rust = try core()
        let native = TMDbMatcher(language: "zh-CN") { _, _, _, _ in [] }
        let names = ["作品", "Cafe\u{301}", "ΟΣ", "ガ", "Show 第二季", "show 2", "① Ⅳ", "", "\u{301}X",
                     "Cafe", "X\u{FE0F}", "X", "カ", "ｶ", "a\u{200D}", "a", "e\u{301}"]
        for index in 0..<900 {
            let name = names[index % names.count]
            let target = item(name, year: index % 3 == 0 ? nil : 2024,
                              original: index % 4 == 0 ? "Café" : nil)
            let candidates = (0..<9).map { rank in
                TMDbSearchResult(id: Int.max - rank, mediaType: rank % 2 == 0 ? .movie : .tv,
                                 title: rank % 3 == 0 ? name : names[(index + rank) % names.count],
                                 originalTitle: rank % 3 == 1 ? name : nil,
                                 overview: "overview \(rank)", posterPath: "/\(rank).jpg",
                                 year: rank % 4 == 0 ? nil : 2024 - rank % 4,
                                 popularity: Double(rank) + 0.25)
            }
            let reply = try rust.call(.init(operation: "rank", item: .init(target), candidates: candidates))
            let scores = candidates.map { native.nativeScore($0, item: target) }
            XCTAssertEqual(reply.scores, scores, "Scores corpus \(index)")
            let ranked = zip(candidates, scores).sorted { $0.1 > $1.1 }
            let best = try XCTUnwrap(reply.match?.native())
            XCTAssertEqual(best.entityKey.tmdbID, ranked[0].0.id)
            XCTAssertEqual(best.confidence, ranked[0].1)
            XCTAssertEqual(best.alternatives, ranked.dropFirst().prefix(5).map(\.0))
            XCTAssertEqual(best.shouldApplyAutomatically, ranked[0].1 >= 0.85)
        }
    }

    func testCompleteInjectedSearchFlowMatchesIndependentNative() async throws {
        let path = try library()
        let names = ["作品", "Cafe\u{301}", "Show (2024)", "ガ", "Unrelated"]
        for index in 0..<90 {
            let target = item(names[index % names.count], kind: index % 2 == 0 ? .movie : .series,
                              year: index % 3 == 0 ? nil : 2024,
                              original: index % 7 == 0 ? names[index % names.count].precomposedStringWithCanonicalMapping : "Original")
            let sharedTrace = Trace(), nativeTrace = Trace()
            func search(_ trace: Trace) -> @Sendable (String, TMDbMediaType, Int?, String) async throws -> [TMDbSearchResult] {
                { query, type, year, language in
                    trace.append("\(query)|\(type.rawValue)|\(String(describing: year))|\(language)")
                    if index % 5 == 0 && query == target.name { throw TMDbError.unauthorized }
                    if index % 11 == 0 { return [] }
                    return [TMDbSearchResult(id: Int.max, mediaType: type,
                                             title: query == target.name && index % 4 == 0 ? "Other" : target.name,
                                             originalTitle: "Original", year: 2024),
                            TMDbSearchResult(id: 2, mediaType: type, title: "Alternative", year: nil)]
                }
            }
            let shared = TMDbMatcher(language: "zh-CN", rustCoreLibraryPath: path, search: search(sharedTrace))
            let native = TMDbMatcher(language: "zh-CN", search: search(nativeTrace))
            XCTAssertTrue(shared.usesCoreMatching)
            let actual = await shared.match(item: target)
            let expected = await native.nativeMatch(item: target)
            XCTAssertEqual(actual, expected, "Complete flow \(index)")
            XCTAssertEqual(sharedTrace.values, nativeTrace.values, "Queries \(index)")
        }
        if ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1" {
            XCTAssertTrue(TMDbMatcher(language: "zh-CN") { _, _, _, _ in [] }.usesCoreMatching)
        }
    }

    func testProviderParentBoundaryAndDisabledSearch() async throws {
        let path = try library(), trace = Trace()
        let shared = TMDbMatcher(language: "zh-CN", rustCoreLibraryPath: path) { _, _, _, _ in
            trace.append("searched"); return []
        }
        for kind in [MediaItem.Kind.movie, .series, .season, .episode, .boxSet, .audio, .other] {
            for raw in ["", "0", "-1", "+603", "\u{85}603\u{2000}", String(Int.max), "9223372036854775808", "６０３"] {
                var target = item("Name", kind: kind)
                target.tmdbID = raw; target.seasonNumber = 0; target.seriesName = "Series"
                for key in [TMDbEntityKey.tv(Int.max), .movie(603), .season(tvID: 2, number: 1), .collection(3)] {
                    let parent = TMDbLink(itemID: "parent", entityKey: key, source: .manual,
                                          confidence: 0.8, linkedAt: Date())
                    let actual = await shared.match(item: target, seriesLink: parent, allowSearch: false)
                    let expected = await shared.nativeMatch(item: target, seriesLink: parent, allowSearch: false)
                    XCTAssertEqual(actual, expected, "Kind \(kind), ID \(raw), parent \(key)")
                }
                XCTAssertEqual(shared.providerTmdbID(of: target), shared.nativeProviderTmdbID(of: target))
            }
        }
        XCTAssertTrue(trace.values.isEmpty)
    }
}
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var trace: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return trace }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; trace.append(value) }
}
#endif
