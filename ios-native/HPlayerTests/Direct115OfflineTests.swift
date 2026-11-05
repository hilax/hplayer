import XCTest
@testable import HPlayer

final class Direct115OfflineTests: XCTestCase {
    private func client() -> Direct115Client {
        Direct115Client(cookie: "UID=1_test; CID=abc", protocolClasses: [RoutedURLProtocol.self])
    }

    private func rawTask(_ hash: String, status: Int, percent: Double, extra: [String: Any] = [:]) -> [String: Any] {
        var task: [String: Any] = [
            "info_hash": hash, "name": "示例影片 \(hash)", "size": "1048576", "status": status, "percentDone": percent,
            "file_id": "900", "wp_path_id": "55", "url": "magnet:?xt=urn:btih:\(hash)",
            "add_time": 1_700_000_000, "rateDownload": 2048.5, "left_time": 120,
        ]
        task.merge(extra) { _, new in new }
        return task
    }

    // MARK: 解析

    func testParsesTaskFields() {
        let task = Direct115Client.parseTask(rawTask("ABCDEF", status: 1, percent: 63.5))
        XCTAssertEqual(task.infoHash, "abcdef")
        XCTAssertEqual(task.remoteHash, "ABCDEF")
        XCTAssertEqual(task.status, .downloading)
        XCTAssertEqual(task.percent, 63.5, accuracy: 0.001)
        XCTAssertEqual(task.size, 1_048_576)
        XCTAssertEqual(task.folderID, "55")
        XCTAssertEqual(task.sourceLabel, "磁力链接")
        XCTAssertEqual(task.addedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(task.speed, 2048.5, accuracy: 0.001)
        XCTAssertEqual(task.remainingSeconds, 120)
    }

    func testTaskStatusMapping() {
        XCTAssertEqual(Direct115Client.parseTask(rawTask("a", status: 2, percent: 100)).status, .done)
        XCTAssertEqual(Direct115Client.parseTask(rawTask("a", status: 1, percent: 100)).status, .done)
        XCTAssertEqual(Direct115Client.parseTask(rawTask("a", status: 0, percent: 0)).status, .waiting)
        XCTAssertEqual(Direct115Client.parseTask(rawTask("a", status: -1, percent: 12)).status, .failed)
    }

    func testNegativeSpeedAndTimeAreClamped() {
        let task = Direct115Client.parseTask(rawTask("a", status: 1, percent: 5, extra: ["rateDownload": -1, "left_time": -1]))
        XCTAssertEqual(task.speed, 0)
        XCTAssertEqual(task.remainingSeconds, 0)
    }

    func testSourceLabels() {
        func label(_ url: String) -> String {
            Direct115Client.parseTask(rawTask("a", status: 1, percent: 1, extra: ["url": url])).sourceLabel
        }
        XCTAssertEqual(label("https://example.com/a.mp4"), "HTTP 链接")
        XCTAssertEqual(label("ed2k://|file|a|1|x|/"), "电驴链接")
        XCTAssertEqual(label("ftp://example.com/a"), "FTP 链接")
        XCTAssertEqual(label(""), "离线任务")
    }

    func testParsesTaskPageAndPaging() throws {
        let page = try XCTUnwrap(Direct115Client.parseTaskPage(
            ["state": true, "count": 45, "page_count": 2, "tasks": [rawTask("a", status: 2, percent: 100), rawTask("b", status: 1, percent: 3)]],
            requestedPage: 1))
        XCTAssertEqual(page.tasks.map(\.infoHash), ["a", "b"])
        XCTAssertEqual(page.total, 45)
        XCTAssertEqual(page.pageCount, 2)
        XCTAssertTrue(page.hasMore)

        let last = try XCTUnwrap(Direct115Client.parseTaskPage(
            ["state": true, "count": 45, "page_count": 2, "tasks": [rawTask("c", status: 2, percent: 100)]], requestedPage: 2))
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(Direct115Client.parseTaskPage(["state": true, "tasks": NSNull()], requestedPage: 1))
    }

    func testParsesFolderPath() {
        let path = Direct115Client.parseFolderPath(["path": [["cid": 0, "name": "根目录"], ["cid": "5", "name": "电影"], ["cid": "6", "name": "2024"]]])
        XCTAssertEqual(path, ["网盘", "电影", "2024"])
        XCTAssertTrue(Direct115Client.parseFolderPath([:]).isEmpty)
    }

    // MARK: 添加结果

    func testAddSummaryReportsEachLink() {
        let links = ["magnet:?xt=urn:btih:aa", "magnet:?xt=urn:btih:bb", "https://bad", "https://quota"]
        let summary = Direct115Client.addSummary(results: [
            ["state": true],
            ["state": false, "errcode": 10008],
            ["state": false, "errcode": 10004],
            ["state": false, "errcode": 10010],
        ], links: links)
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failures.map(\.link), ["https://bad", "https://quota"])
        XCTAssertEqual(summary.failures.map { $0.error.errorDescription },
                       [Direct115OfflineError.invalidLink.errorDescription, Direct115OfflineError.quotaExhausted.errorDescription])
    }

    func testAddSummaryTrustsLinksWithoutAResult() {
        let summary = Direct115Client.addSummary(results: [], links: ["a", "b"])
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertTrue(summary.failures.isEmpty)
    }

    func testAddRejectsEmptyAndTooManyLinks() async {
        do {
            _ = try await client().addOfflineTasks(["  ", ""], userID: 1, folderID: nil)
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, Direct115OfflineError.invalidLink.errorDescription)
        }
        do {
            let links = (0...Direct115Client.offlineAddLimit).map { "https://example.com/\($0)" }
            _ = try await client().addOfflineTasks(links, userID: 1, folderID: nil)
            XCTFail("应该失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("最多"))
        }
        do {
            _ = try await client().addOfflineTasks(["https://example.com/a"], userID: 1, folderID: "abc")
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .invalidID)
        }
    }

    // MARK: 请求

    func testReadsOneTaskPage() async throws {
        RoutedURLProtocol.install { _ in
            .json(["state": true, "count": 1, "page_count": 1, "tasks": [self.rawTask("abc", status: 2, percent: 100)]])
        }
        let page = try await client().offlinePage(2)
        XCTAssertEqual(page.tasks.count, 1)
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertTrue(request.url?.absoluteString.contains("ac=task_lists") == true)
        XCTAssertTrue(request.url?.absoluteString.contains("page=2") == true)
    }

    func testEmptyListIsNotAnError() async throws {
        RoutedURLProtocol.install { _ in .json(["state": true, "tasks": NSNull(), "count": 0]) }
        let page = try await client().offlinePage(1)
        XCTAssertTrue(page.tasks.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testDeleteSendsIndexedHashesAndFlag() async throws {
        RoutedURLProtocol.install { _ in .json(["state": true]) }
        try await client().deleteOfflineTasks(["H1", "h2"], deleteFiles: true)
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertTrue(request.url?.absoluteString.contains("ac=task_del") == true)
        let form = RoutedURLProtocol.form(of: request)
        XCTAssertEqual(form["hash[0]"], "H1")
        XCTAssertEqual(form["hash[1]"], "h2")
        XCTAssertEqual(form["flag"], "1")
        XCTAssertEqual(form["ac"], "task_del")
    }

    func testDeleteWithoutFilesUsesFlagZeroAndEmptyListDoesNothing() async throws {
        RoutedURLProtocol.install { _ in .json(["state": true]) }
        try await client().deleteOfflineTasks([], deleteFiles: false)
        XCTAssertTrue(RoutedURLProtocol.requests().isEmpty)
        try await client().deleteOfflineTasks(["h"], deleteFiles: false)
        XCTAssertEqual(RoutedURLProtocol.form(of: try XCTUnwrap(RoutedURLProtocol.requests().first))["flag"], "0")
    }

    func testClearUsesTheScopeFlag() async throws {
        RoutedURLProtocol.install { _ in .json(["state": true]) }
        try await client().clearOfflineTasks(.failed)
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertTrue(request.url?.absoluteString.contains("ac=task_clear") == true)
        XCTAssertEqual(RoutedURLProtocol.form(of: request)["flag"], "2")
    }

    func testActionFallsBackToTheSecondEndpointOnlyWhenTheFirstIsUnrecognised() async throws {
        RoutedURLProtocol.install { request in
            request.url?.host == "lixian.115.com" ? .init(status: 404) : .json(["state": true])
        }
        try await client().clearOfflineTasks(.completed)
        XCTAssertEqual(RoutedURLProtocol.requests().compactMap { $0.url?.host }, ["lixian.115.com", "clouddownload.115.com"])

        RoutedURLProtocol.install { _ in .json(["state": false, "error_msg": "任务不存在"]) }
        do {
            try await client().deleteOfflineTasks(["h"], deleteFiles: false)
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "任务不存在")
            XCTAssertEqual(RoutedURLProtocol.requests().count, 1)
        }
    }

    func testLoggedOutIsReported() async {
        RoutedURLProtocol.install { _ in .json(["state": false, "errno": 99]) }
        do {
            try await client().clearOfflineTasks(.all)
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .notLoggedIn)
        }
    }

    func testFolderPathReadsOneRow() async throws {
        RoutedURLProtocol.install { _ in
            .json(["state": true, "data": [], "path": [["cid": 0, "name": "根目录"], ["cid": "5", "name": "电影"]]])
        }
        let path = try await client().folderPath(id: "5")
        XCTAssertEqual(path, ["网盘", "电影"])
        let query = try XCTUnwrap(RoutedURLProtocol.requests().first?.url?.query)
        XCTAssertTrue(query.contains("limit=1"))
        XCTAssertTrue(query.contains("cid=5"))
    }
}

final class OfflineLinksTests: XCTestCase {
    func testClassifiesTheSupportedKinds() {
        let batch = OfflineLinkBatch.parse("""
        magnet:?xt=urn:btih:8E3F1C7A92B04D5E6F8091A2B3C4D5E6F7081920&dn=sample
        https://example.com/files/sample-movie.mp4
        HTTP://EXAMPLE.COM/a
        ed2k://|file|a.mkv|123|ABCDEF|/
        ftp://example.com/pub/a.iso
        """)
        XCTAssertEqual(batch.links.map(\.kind), [.magnet, .http, .http, .ed2k, .ftp])
        XCTAssertTrue(batch.rejected.isEmpty)
        XCTAssertEqual(batch.kindSummary, "磁力 1 · HTTP 2 · 电驴 1 · FTP 1")
    }

    func testIgnoresBlankLinesAndCountsDuplicates() {
        let batch = OfflineLinkBatch.parse("\n  https://example.com/a  \n\nhttps://example.com/a\r\nhttps://example.com/b\n")
        XCTAssertEqual(batch.links.map(\.text), ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(batch.duplicates, 1)
    }

    func testRejectsGarbage() {
        let batch = OfflineLinkBatch.parse("hello\nmagnet:?dn=no-hash\nhttps://\nhttps:// spaced.com\nhttp:///path\nftp://")
        XCTAssertTrue(batch.links.isEmpty)
        XCTAssertEqual(batch.rejected.count, 6)
        XCTAssertTrue(batch.isEmpty)
    }

    func testBareHashBecomesAMagnetLink() {
        let hex = "8e3f1c7a92b04d5e6f8091a2b3c4d5e6f7081920"
        let base32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let batch = OfflineLinkBatch.parse("\(hex)\n\(base32)\n\(hex.dropLast())")
        XCTAssertEqual(batch.links.map(\.text), ["magnet:?xt=urn:btih:\(hex)", "magnet:?xt=urn:btih:\(base32)"])
        XCTAssertEqual(batch.rejected.count, 1)
    }

    func testNonASCIIHTTPLinksAreAccepted() {
        let batch = OfflineLinkBatch.parse("https://example.com/电影/示例.mp4")
        XCTAssertEqual(batch.links.count, 1)
    }
}
