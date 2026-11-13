import XCTest
@testable import HPlayer

@MainActor
final class FavoriteStarStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "FavoriteStarStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func star(_ id: String, avatar: String? = nil) -> MagnetStarItem {
        MagnetStarItem(id: id, name: "女优 \(id)", avatarURL: avatar.flatMap(URL.init(string:)), detailPath: "/star/\(id)")
    }

    func testToggleKeepsNewestFirstAndPersists() {
        let defaults = makeDefaults()
        let store = FavoriteStarStore(defaults: defaults)
        XCTAssertTrue(store.toggle(star("a")))
        XCTAssertTrue(store.toggle(star("b")))
        XCTAssertEqual(store.items.map(\.id), ["b", "a"], "Most recently liked comes first")
        XCTAssertTrue(store.contains(star("a")))

        let reloaded = FavoriteStarStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.items.first?.item.detailPath, "/star/b")

        XCTAssertFalse(reloaded.toggle(star("b")))
        XCTAssertEqual(FavoriteStarStore(defaults: defaults).items.map(\.id), ["a"])
    }

    func testRefreshUpdatesAvatarWithoutReordering() {
        let store = FavoriteStarStore(defaults: makeDefaults())
        store.toggle(star("a"))
        store.toggle(star("b"))
        store.refresh(star("a", avatar: "https://example.com/a.jpg"))
        XCTAssertEqual(store.items.map(\.id), ["b", "a"])
        XCTAssertEqual(store.items.last?.avatarURL, "https://example.com/a.jpg")
        store.refresh(star("zzz", avatar: "https://example.com/z.jpg"))
        XCTAssertEqual(store.items.count, 2, "Refreshing someone not liked does nothing")
    }
}
