import XCTest
@testable import HPlayer

@MainActor
final class LocalMediaStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testImportingTheLibraryFileItselfPreservesIt() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("movie.mp4")
        let bytes = Data("original video".utf8)
        try bytes.write(to: file)
        let store = LocalMediaStore(directory: root)
        let failures = await store.importFiles([file])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(store.files.count, 1)
        XCTAssertFalse(store.isImporting)
    }

    func testSameNamesKeepBothVideos() async throws {
        let root = try directory(), incoming = try directory()
        let existing = root.appendingPathComponent("movie.mp4")
        let source = incoming.appendingPathComponent("movie.mp4")
        try Data("old".utf8).write(to: existing)
        try Data("new".utf8).write(to: source)
        let store = LocalMediaStore(directory: root)
        let failures = await store.importFiles([source])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("movie (2).mp4")), Data("new".utf8))
        XCTAssertEqual(store.files.count, 2)
    }

    func testFailedImportDoesNotDeleteTheExistingVideo() async throws {
        let root = try directory(), incoming = try directory()
        let existing = root.appendingPathComponent("movie.mp4")
        try Data("old".utf8).write(to: existing)
        let store = LocalMediaStore(directory: root)
        let failures = await store.importFiles([incoming.appendingPathComponent("movie.mp4")])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        XCTAssertEqual(store.files.count, 1)
        XCTAssertFalse(store.isImporting)
    }

    func testUnsupportedInputReportsTheFailure() async throws {
        let root = try directory(), incoming = try directory()
        let source = incoming.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: source)
        let store = LocalMediaStore(directory: root)
        let failures = await store.importFiles([source])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(store.files.isEmpty)
    }
    func testFoldersWithAVideoExtensionAreNotListedAsVideos() throws {
        let root = try directory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
        let store = LocalMediaStore(directory: root)
        XCTAssertTrue(store.files.isEmpty)
    }

}
