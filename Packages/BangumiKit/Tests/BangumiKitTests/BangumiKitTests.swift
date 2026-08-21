import Foundation
import Testing

@testable import BangumiKit

struct BangumiKitTests {
    @Test func collectionTypeMapping() {
        #expect(BangumiCollectionType(1) == .wish)
        #expect(BangumiCollectionType(3) == .doing)
        #expect(BangumiCollectionType(99) == .none)
        #expect(BangumiCollectionType.allTypes().count == 5)
    }

    @Test func episodeSortDisplay() {
        let episode = BangumiEpisodeDTO(
            id: 1, subjectID: 1, type: .main, sort: 12.5,
            name: "Test", nameCN: "", duration: "", airdate: "",
            comment: 0, disc: 0)
        #expect(episode.sortDisplay == "12.5")
    }

    @Test func progressFraction() {
        var subject = BangumiSubjectDTO(id: 1)
        subject.eps = 10
        subject.interest = BangumiSubjectInterest(
            comment: "", epStatus: 4, volStatus: 0, private: false, rate: 0,
            tags: [], type: .doing, updatedAt: 0)
        let progress = BangumiProgressSubject(subject: subject, episodes: [])
        #expect(progress.progressText == "4 / 10")
        #expect(progress.progressFraction == 0.4)
    }
}
