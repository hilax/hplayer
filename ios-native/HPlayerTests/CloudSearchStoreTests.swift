import XCTest
@testable import HPlayer

@MainActor
final class CloudSearchStoreTests: XCTestCase {
    private func file(_ name: String) -> P115File {
        P115File(id: name, parentId: "0", name: name + ".mp4", isDir: false, kind: "video", size: 1,
                 pickCode: name, sha1: "", updatedAt: "", thumbUrl: "")
    }

    func testOlderResponseCannotReplaceTheNewQuery() async {
        let gate = SearchResponseGate(), store = CloudSearchStore()
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
        let gate = SearchResponseGate(), store = CloudSearchStore()
        let old = Task { await store.search("old", lookup: gate.lookup) }
        await gate.waitForRequest("old")
        await store.search("new") { _ in [self.file("new")] }
        await gate.finish("old", with: .failure(APIError.server("旧请求失败")))
        await old.value
        XCTAssertEqual(store.results.map(\.id), ["new"])
        XCTAssertEqual(store.error, "")
    }

    func testAccountChangeDiscardsPendingResults() async {
        let gate = SearchResponseGate(), store = CloudSearchStore()
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
}

private actor SearchResponseGate {
    private var pending: [String: CheckedContinuation<[P115File], Error>] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    func lookup(_ query: String) async throws -> [P115File] {
        try await withCheckedThrowingContinuation { continuation in
            pending[query] = continuation
            waiting.removeValue(forKey: query)?.forEach { $0.resume() }
        }
    }
    func waitForRequest(_ query: String) async {
        if pending[query] != nil { return }
        await withCheckedContinuation { waiting[query, default: []].append($0) }
    }
    func finish(_ query: String, with result: Result<[P115File], Error>) {
        pending.removeValue(forKey: query)?.resume(with: result)
    }
}
