import XCTest
@testable import HPlayer

@MainActor
final class CloudLibraryScannerTests: XCTestCase {
    private lazy var defaults: UserDefaults = {
        let suite = "CloudLibraryScannerTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }()

    private func scanner(maximumAttempts: Int = 3) -> CloudLibraryScanner {
        CloudLibraryScanner(defaults: defaults, minimumRequestInterval: 0, maximumAttempts: maximumAttempts, retryBaseDelay: 0)
    }

    private func file(_ id: String, parent: String = "0", directory: Bool = false, video: Bool = true) -> P115File {
        P115File(id: id, parentId: parent, name: directory ? "Folder \(id)" : "Movie \(id).mkv",
                 isDir: directory, kind: directory ? "folder" : (video ? "video" : "document"),
                 size: 1024, pickCode: directory ? "" : "pc\(id)", sha1: "", updatedAt: "", thumbUrl: "")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Scanner did not reach expected state", file: file, line: line)
    }

    func testRecursesEveryDirectoryAndPageWithoutDuplicateVideosOrCycles() async {
        let scanner = scanner()
        var requests: [String] = []
        var found: [String] = []
        scanner.start(accountID: "device:1", fetchPage: { [self] cid, offset in
            requests.append("\(cid):\(offset)")
            switch (cid, offset) {
            case ("0", 0): return Direct115FilePage(files: [file("10", directory: true), file("1")], nextOffset: 2)
            case ("0", 2): return Direct115FilePage(files: [file("20", directory: true), file("2"), file("99", video: false)], nextOffset: nil)
            case ("10", 0): return Direct115FilePage(files: [file("0", directory: true), file("1"), file("3", parent: "10")], nextOffset: nil)
            case ("20", 0): return Direct115FilePage(files: [], nextOffset: nil)
            default: XCTFail("Unexpected request \(cid):\(offset)"); return Direct115FilePage(files: [], nextOffset: nil)
            }
        }, onBatch: { found += $0.map(\.id) })
        await waitUntil { scanner.phase != .running }
        XCTAssertEqual(scanner.phase, .completed)
        XCTAssertEqual(requests, ["0:0", "0:2", "10:0", "20:0"])
        XCTAssertEqual(found, ["1", "2", "3"])
        XCTAssertEqual(scanner.progress, .init(scannedFolders: 3, discoveredFolders: 3, discoveredVideos: 3))
    }

    func testRestoresInsideDirectoryAndReplaysInventoryBeforeContinuing() async {
        let first = scanner()
        first.start(accountID: "device:1", fetchPage: { [self] _, offset in
            if offset == 0 { return Direct115FilePage(files: [file("1")], nextOffset: 500) }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Direct115FilePage(files: [], nextOffset: nil)
        }, onBatch: { _ in })
        await waitUntil { first.discoveredFiles.count == 1 }
        first.pause()

        let restored = scanner()
        restored.selectAccount("device:1")
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertEqual(restored.discoveredFiles.map(\.id), ["1"])
        var requests: [Int] = []
        var delivered: [String] = []
        restored.resume(fetchPage: { [self] cid, offset in
            XCTAssertEqual(cid, "0")
            requests.append(offset)
            return Direct115FilePage(files: [file("2")], nextOffset: nil)
        }, onBatch: { delivered += $0.map(\.id) })
        await waitUntil { restored.phase != .running }
        XCTAssertEqual(restored.phase, .completed)
        XCTAssertEqual(requests, [500])
        XCTAssertEqual(delivered, ["1", "2"])
    }

    func testFailureLeavesFolderPendingAndResumeDoesNotRescanCompletedRoot() async {
        let first = scanner()
        first.start(accountID: "device:1", fetchPage: { [self] cid, _ in
            if cid == "0" { return Direct115FilePage(files: [file("10", directory: true), file("1")], nextOffset: nil) }
            throw Direct115HTTPError(statusCode: 403)
        }, onBatch: { _ in })
        await waitUntil { first.phase != .running }
        XCTAssertEqual(first.phase, .failed)
        XCTAssertEqual(first.progress.scannedFolders, 1)
        XCTAssertEqual(first.progress.discoveredFolders, 2)
        XCTAssertTrue(first.lastError.contains("403"))

        let restored = scanner()
        restored.selectAccount("device:1")
        var requests: [String] = []
        restored.resume(fetchPage: { [self] cid, _ in
            requests.append(cid)
            return Direct115FilePage(files: [file("2", parent: cid)], nextOffset: nil)
        }, onBatch: { _ in })
        await waitUntil { restored.phase != .running }
        XCTAssertEqual(restored.phase, .completed)
        XCTAssertEqual(requests, ["10"])
        XCTAssertEqual(restored.discoveredFiles.map(\.id), ["1", "2"])
    }

    func testAccountChangeRejectsLateResponseAndKeepsInventoryIsolated() async {
        let scanner = scanner()
        var pending: CheckedContinuation<Direct115FilePage, Never>?
        var deliveredA = 0
        scanner.start(accountID: "device:1", fetchPage: { _, _ in
            await withCheckedContinuation { pending = $0 }
        }, onBatch: { deliveredA += $0.count })
        await waitUntil { pending != nil }
        scanner.selectAccount("device:2")
        scanner.start(accountID: "device:2", fetchPage: { [self] _, _ in
            Direct115FilePage(files: [file("2")], nextOffset: nil)
        }, onBatch: { _ in })
        await waitUntil { scanner.phase != .running }
        pending?.resume(returning: Direct115FilePage(files: [file("secretA")], nextOffset: nil))
        await Task.yield()
        XCTAssertEqual(scanner.accountID, "device:2")
        XCTAssertEqual(scanner.discoveredFiles.map(\.id), ["2"])
        XCTAssertEqual(deliveredA, 0)

        scanner.selectAccount("device:1")
        XCTAssertEqual(scanner.phase, .paused)
        XCTAssertTrue(scanner.discoveredFiles.isEmpty)
        scanner.selectAccount(nil)
        XCTAssertEqual(scanner.phase, .idle)
        XCTAssertTrue(scanner.discoveredFiles.isEmpty)
    }

    func testRetriesTransientErrorsButDoesNotRetryAuthenticationFailure() async {
        let scanner = scanner()
        var attempts = 0
        scanner.start(accountID: "device:1", fetchPage: { _, _ in
            attempts += 1
            if attempts < 3 { throw URLError(.timedOut) }
            return Direct115FilePage(files: [], nextOffset: nil)
        }, onBatch: { _ in })
        await waitUntil { scanner.phase != .running }
        XCTAssertEqual(scanner.phase, .completed)
        XCTAssertEqual(attempts, 3)

        attempts = 0
        scanner.start(accountID: "device:1", fetchPage: { _, _ in
            attempts += 1
            throw Direct115HTTPError(statusCode: 401)
        }, onBatch: { _ in }, restart: true)
        await waitUntil { scanner.phase != .running }
        XCTAssertEqual(scanner.phase, .failed)
        XCTAssertEqual(attempts, 1)
    }

    func testDoesNotCallRepeatedPageACompleteScan() async {
        let scanner = scanner()
        scanner.start(accountID: "device:1", fetchPage: { [self] _, offset in
            Direct115FilePage(files: [file("1")], nextOffset: offset == 0 ? 500 : nil)
        }, onBatch: { _ in })
        await waitUntil { scanner.phase != .running }
        XCTAssertEqual(scanner.phase, .failed)
        XCTAssertEqual(scanner.progress.scannedFolders, 0)
        XCTAssertEqual(scanner.discoveredFiles.count, 1)
    }

    func testInterruptedRunningCheckpointLoadsPausedAfterRelaunch() async {
        let first = scanner()
        first.start(accountID: "device:1", fetchPage: { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Direct115FilePage(files: [], nextOffset: nil)
        }, onBatch: { _ in })
        XCTAssertEqual(first.phase, .running)
        let relaunched = scanner()
        relaunched.selectAccount("device:1")
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.progress.discoveredFolders, 1)
        first.pause()
    }

    func testSavedInventoryReplaysOnceAsynchronouslyAndCanBeSkipped() async {
        let first = scanner()
        first.start(accountID: "device:1", fetchPage: { [self] _, offset in
            Direct115FilePage(files: [file(String(offset + 1))], nextOffset: offset == 0 ? 1 : nil)
        }, onBatch: { _ in })
        await waitUntil { first.phase == .completed }

        let restored = scanner()
        restored.selectAccount("device:1")
        var batches: [[String]] = []
        restored.start(accountID: "device:1", fetchPage: { _, _ in
            XCTFail("A completed scan must not fetch again")
            return Direct115FilePage(files: [], nextOffset: nil)
        }, onBatch: { batches.append($0.map(\.id)) })
        XCTAssertTrue(batches.isEmpty, "Restoring inventory must yield to the UI first")
        await waitUntil { restored.phase == .completed }
        XCTAssertEqual(batches, [["1", "2"]], "Merge the saved inventory once instead of repeatedly copying the growing library")

        batches = []
        restored.start(accountID: "device:1", fetchPage: { _, _ in
            XCTFail("A completed scan must not fetch again")
            return Direct115FilePage(files: [], nextOffset: nil)
        }, onBatch: { batches.append($0.map(\.id)) }, replayInventory: false)
        await waitUntil { restored.phase == .completed }
        XCTAssertTrue(batches.isEmpty)
    }
}
