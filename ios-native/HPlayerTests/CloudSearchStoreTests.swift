import XCTest
@testable import HPlayer

@MainActor
final class CloudSearchStoreTests: XCTestCase {
    private func file(_ name: String) -> P115File {
        P115File(id: name, parentId: "0", name: name + ".mp4", isDir: false, kind: "video", size: 1,
                 pickCode: name, sha1: "", updatedAt: "", thumbUrl: "")
    }

    private func anime(_ id: Int, _ name: String) -> AnimeVideoItem {
        AnimeVideoItem(id: id, name: name)
    }

    func testOlderResponseCannotReplaceTheNewQuery() async {
        let gate = SearchResponseGate<P115File>(), store = CloudSearchStore()
        let old = Task { await store.search("old", lookup: gate.lookup) }
        await gate.waitForRequest("old")
        let current = Task { await store.search("current", lookup: gate.lookup) }
        await gate.waitForRequest("current")
        await gate.finish("current", with: .success([file("current")]))
        await current.value
        await gate.finish("old", with: .success([file("old")]))
        await old.value
        XCTAssertEqual(store.searchedKeyword, "current")
        XCTAssertEqual(store.results.map(\.id), ["current"])
        XCTAssertFalse(store.loading)
    }

    func testOldFailureDoesNotReplaceSuccessfulResults() async {
        let gate = SearchResponseGate<P115File>(), store = CloudSearchStore()
        let old = Task { await store.search("old", lookup: gate.lookup) }
        await gate.waitForRequest("old")
        await store.search("new") { _ in [self.file("new")] }
        await gate.finish("old", with: .failure(APIError.server("旧请求失败")))
        await old.value
        XCTAssertEqual(store.results.map(\.id), ["new"])
        XCTAssertEqual(store.error, "")
    }

    func testAccountChangeDiscardsPendingResults() async {
        let gate = SearchResponseGate<P115File>(), store = CloudSearchStore()
        let pending = Task { await store.search("old account", lookup: gate.lookup) }
        await gate.waitForRequest("old account")
        store.invalidate(clearResults: true)
        await gate.finish("old account", with: .success([file("private")]))
        await pending.value
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(store.searchedKeyword, "")
        XCTAssertFalse(store.loading)
    }

    func testCancellationDoesNotBecomeASearchFailure() async {
        let store = CloudSearchStore()
        let pending = Task {
            await store.search("cancelled") { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return []
            }
        }
        while !store.loading { await Task.yield() }
        pending.cancel()
        await pending.value
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.error, "")
    }

    func testAlreadyCancelledSearchCannotInvalidateTheCurrentRequest() async {
        let gate = SearchResponseGate<P115File>(), store = CloudSearchStore()
        let current = Task { await store.search("current", lookup: gate.lookup) }
        await gate.waitForRequest("current")
        var lookedUp = false
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.search("cancelled") { _ in lookedUp = true; return [] }
        }
        await cancelled.value
        XCTAssertFalse(lookedUp)
        XCTAssertTrue(store.loading)
        await gate.finish("current", with: .success([file("current")]))
        await current.value
        XCTAssertEqual(store.searchedKeyword, "current")
        XCTAssertEqual(store.results.map(\.id), ["current"])
        XCTAssertFalse(store.loading)
    }

    func testAnimeSearchStoreProtectsOrderAndErrors() async {
        let gate = SearchResponseGate<AnimeVideoItem>(), store = AnimeSearchStore()
        let old = Task { await store.search("old", lookup: gate.lookup) }
        await gate.waitForRequest("old")
        let current = Task { await store.search("new", lookup: gate.lookup) }
        await gate.waitForRequest("new")
        await gate.finish("new", with: .success([anime(2, "新番")]))
        await current.value
        await gate.finish("old", with: .failure(APIError.server("旧请求超时")))
        await old.value

        XCTAssertEqual(store.searchedKeyword, "new")
        XCTAssertEqual(store.results.map(\.id), [2])
        XCTAssertEqual(store.error, "")
        XCTAssertFalse(store.loading)

        await store.search("fail") { _ in throw APIError.server("网络不可用") }
        XCTAssertEqual(store.error, "网络不可用")
        XCTAssertFalse(store.loading)
    }

    func testSearchHistoryDeduplicatesMovesToFrontCapsAndClears() {
        let suite = "hplayer.tests.search-history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SearchHistoryStore(defaults: defaults)
        store.record("   ")
        XCTAssertTrue(store.items.isEmpty)

        store.record("沙丘")
        store.record("Dune")
        store.record(" 沙丘 ")
        XCTAssertEqual(store.items, ["沙丘", "Dune"])

        store.record("dune")
        XCTAssertEqual(store.items, ["dune", "沙丘"])

        for i in 1...15 {
            store.record("片名\(i)")
        }
        XCTAssertEqual(store.items.count, SearchHistoryStore.maxItems)
        XCTAssertEqual(store.items.first, "片名15")

        store.remove("片名15")
        XCTAssertEqual(store.items.first, "片名14")

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        let reloaded = SearchHistoryStore(defaults: defaults)
        XCTAssertTrue(reloaded.items.isEmpty)
    }
}

private actor SearchResponseGate<Item> {
    private var pending: [String: CheckedContinuation<[Item], Error>] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    func lookup(_ query: String) async throws -> [Item] {
        try await withCheckedThrowingContinuation { continuation in
            pending[query] = continuation
            waiting.removeValue(forKey: query)?.forEach { $0.resume() }
        }
    }
    func waitForRequest(_ query: String) async {
        if pending[query] != nil { return }
        await withCheckedContinuation { waiting[query, default: []].append($0) }
    }
    func finish(_ query: String, with result: Result<[Item], Error>) {
        pending.removeValue(forKey: query)?.resume(with: result)
    }
}
