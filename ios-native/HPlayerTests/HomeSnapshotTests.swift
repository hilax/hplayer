import XCTest
@testable import HPlayer

final class HomeSnapshotTests: XCTestCase {
    func testOnlyMatchedPostersEnterHeroAndShelvesWithoutLosingFiles() {
        let good = makeMetadata(id: "movie", poster: "https://images.example.org/poster.jpg")
        let empty = makeMetadata(id: "empty", poster: "")
        let invalid = makeMetadata(id: "bad", poster: "not-a-url")
        let items = [item("good.mp4", metadata: good), item("empty.mp4", metadata: empty),
                     item("bad.mp4", metadata: invalid), item("unknown.mp4", metadata: nil)]
        let snapshot = HomeSnapshot(items: items)
        XCTAssertEqual(snapshot.items.count, 4, "Hiding unmatched artwork must not remove playable files")
        XCTAssertEqual(snapshot.movies.map(\.metadata?.imdbID), ["movie"])
        XCTAssertEqual(snapshot.featured.map(\.metadata?.imdbID), ["movie"])
        XCTAssertEqual(snapshot.unmatched.count, 3)
    }

    func testUnmatchedLibraryHasNoFallbackHero() {
        let snapshot = HomeSnapshot(items: [item("unknown.mkv", metadata: nil)])
        XCTAssertTrue(snapshot.featured.isEmpty)
        XCTAssertTrue(snapshot.movies.isEmpty)
        XCTAssertTrue(snapshot.series.isEmpty)
        XCTAssertEqual(snapshot.items.count, 1)
    }

    func testGroupsMoviesByPerformerOnlyWhenTheyHaveAtLeastTwoWorks() {
        var a = makeMetadata(id: "a", poster: "https://images.example.org/a.jpg"); a.performers = ["甲", "乙"]
        var b = makeMetadata(id: "b", poster: "https://images.example.org/b.jpg"); b.performers = ["甲"]
        let snapshot = HomeSnapshot(items: [item("a.mp4", metadata: a), item("b.mp4", metadata: b)])
        XCTAssertEqual(snapshot.performers.map(\.name), ["甲"])
        XCTAssertEqual(snapshot.performers.first?.items.count, 2)
    }

    func testPerformerNamesThatDifferOnlyInSpacingAreOnePerson() {
        var a = makeMetadata(id: "a", poster: "https://images.example.org/a.jpg"); a.performers = ["葵 つかさ", "乙"]
        var b = makeMetadata(id: "b", poster: "https://images.example.org/b.jpg"); b.performers = ["葵つかさ", "乙", "乙"]
        let snapshot = HomeSnapshot(items: [item("a.mp4", metadata: a), item("b.mp4", metadata: b)])
        XCTAssertEqual(snapshot.performers.count, 2)
        XCTAssertEqual(snapshot.performers.first { $0.id == PerformerName.key("葵つかさ") }?.items.count, 2)
        XCTAssertEqual(snapshot.performers.first { $0.id == PerformerName.key("乙") }?.items.count, 2,
                       "A repeated name inside one work must not count the work twice")
    }

    func testPerformerCollectionNeverKeepsAnotherActorsWork() {
        var a1 = makeMetadata(id: "a1", poster: "https://images.example.org/a1.jpg"); a1.performers = ["甲"]
        var a2 = makeMetadata(id: "a2", poster: "https://images.example.org/a2.jpg"); a2.performers = ["甲"]
        var b = makeMetadata(id: "b", poster: "https://images.example.org/b.jpg"); b.performers = ["乙"]
        let group = PerformerGroup(
            id: PerformerName.key("甲"),
            name: "甲",
            items: [item("a1.mp4", metadata: a1), item("b.mp4", metadata: b), item("a2.mp4", metadata: a2)]
        )
        XCTAssertEqual(group.collectionItems.map(\.metadata?.imdbID), ["a1", "a2"])
    }

    func testArtworkPrefetchStartsAtTheCurrentHeroThenSpreadsOut() {
        let items = (0..<4).map { index in
            item("m\(index).mp4", metadata: makeMetadata(id: "m\(index)", poster: "https://images.example.org/\(index).jpg"))
        }
        let snapshot = HomeSnapshot(items: items)
        let requests = HomeArtwork.prefetchRequests(snapshot, selection: 2, shelfLimit: 2)
        XCTAssertEqual(requests.count, 10)
        XCTAssertEqual(requests.prefix(8).map { $0.url.lastPathComponent }, ["2.jpg", "2.jpg", "1.jpg", "1.jpg", "3.jpg", "3.jpg", "0.jpg", "0.jpg"])
        XCTAssertEqual(requests.prefix(8).map(\.maxPixel), [1280, 160, 1280, 160, 1280, 160, 1280, 160])
        XCTAssertEqual(requests.suffix(2).map { $0.url.lastPathComponent }, ["0.jpg", "1.jpg"])
        XCTAssertEqual(requests.suffix(2).map(\.maxPixel), [600, 600])
        XCTAssertTrue(HomeArtwork.prefetchRequests(HomeSnapshot(items: [item("none.mp4", metadata: nil)])).isEmpty)
    }

    private func item(_ name: String, metadata: MediaMetadata?) -> HomeMediaItem {
        HomeMediaItem(media: LibraryMedia(local: LocalMedia(url: URL(fileURLWithPath: "/tmp/\(name)"), size: 100, modified: .distantPast)), metadata: metadata)
    }

    private func makeMetadata(id: String, poster: String) -> MediaMetadata {
        MediaMetadata(imdbID: id, type: "movie", title: "Fixture", year: "2026", posterURL: poster,
                      backgroundURL: "", logoURL: "", overview: "", rating: "", genres: [], country: "", season: nil, episode: nil)
    }
}
