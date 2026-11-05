import XCTest
@testable import HPlayer

final class Direct115FileOpsTests: XCTestCase {
    private func client() -> Direct115Client {
        Direct115Client(cookie: "UID=1_test; CID=abc; path=/; domain=.115.com", protocolClasses: [RoutedURLProtocol.self])
    }

    private func ok(_ extra: [String: Any] = [:]) -> RoutedURLProtocol.Reply {
        var json: [String: Any] = ["state": true]
        json.merge(extra) { _, new in new }
        return .json(json)
    }

    // MARK: 校验

    func testNameValidationTrimsAndRejectsUnsafeNames() throws {
        XCTAssertEqual(try Direct115Client.validatedName("  新建文件夹  "), "新建文件夹")
        for bad in ["", "   ", "a/b", "a\\b", "line\nbreak", String(repeating: "长", count: 256)] {
            XCTAssertThrowsError(try Direct115Client.validatedName(bad), bad) { error in
                XCTAssertEqual(error as? Direct115FileError, .invalidName)
            }
        }
    }

    func testIDValidation() throws {
        XCTAssertEqual(try Direct115Client.validatedID(" 12345 "), "12345")
        XCTAssertEqual(try Direct115Client.validatedID("0", allowRoot: true), "0")
        for bad in ["", "0", "12a", "-3", "１２", String(repeating: "1", count: 21)] {
            XCTAssertThrowsError(try Direct115Client.validatedID(bad), bad)
        }
    }

    func testSecurityKeyMustBeSixDigits() throws {
        XCTAssertEqual(try Direct115Client.validatedSecurityKey(" 123456 "), "123456")
        for bad in ["", "12345", "1234567", "12345a"] {
            XCTAssertThrowsError(try Direct115Client.validatedSecurityKey(bad), bad)
        }
    }

    func testBatchesSplitEvenlyAndKeepOrder() {
        let ids = (1...250).map(String.init)
        let batches = Direct115Client.batches(ids, size: 100)
        XCTAssertEqual(batches.map(\.count), [100, 100, 50])
        XCTAssertEqual(batches.flatMap { $0 }, ids)
        XCTAssertTrue(Direct115Client.batches([String](), size: 100).isEmpty)
    }

    // MARK: 操作结果

    func testOperationFailureMapsKnownCodes() {
        XCTAssertNil(Direct115Client.operationFailure(["state": true]))
        XCTAssertNil(Direct115Client.operationFailure(["state": 1]))
        XCTAssertEqual(Direct115Client.operationFailure(["state": false, "errno": 20004]), .nameExists)
        XCTAssertEqual(Direct115Client.operationFailure(["state": false, "errno": "800006"]), .cyclicMove)
        XCTAssertEqual(Direct115Client.operationFailure(["state": false, "errno": 91002]), .cyclicCopy)
        XCTAssertEqual(Direct115Client.operationFailure(["state": false, "errno": 99]), .notLoggedIn)
        XCTAssertEqual(Direct115Client.operationFailure(["state": false, "error": "没有权限"]),
                       .server(code: 0, message: "没有权限"))
        XCTAssertEqual(Direct115Client.operationFailure(["state": false]), .server(code: 0, message: ""))
        XCTAssertEqual(Direct115FileError.nameExists.errorDescription, "这个位置已经有同名的文件或文件夹")
    }

    // MARK: 文件信息与回收站解析

    func testParsesFileInfo() throws {
        let info = try Direct115Client.parseFileInfo([
            "state": true, "file_name": "Movie.mkv", "file_category": "1", "pick_code": "abc123",
            "sha1": "AABB", "count": "1", "folder_count": "0", "size": "4.37GB", "ptime": "1700000000", "utime": "2023-11-15 08:30",
            "paths": [["file_id": 0, "file_name": "根目录"], ["file_id": "55", "file_name": "电影"], ["file_id": "77", "file_name": "Movie.mkv"]],
        ], id: "77")
        XCTAssertEqual(info.name, "Movie.mkv")
        XCTAssertFalse(info.isDirectory)
        XCTAssertEqual(info.pickCode, "abc123")
        XCTAssertEqual(info.location, ["网盘", "电影"])
        XCTAssertEqual(info.sizeText, "4.37GB")
        XCTAssertEqual(info.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(info.modifiedAt)
    }

    func testFolderInfoCarriesCounts() throws {
        let info = try Direct115Client.parseFileInfo([
            "state": true, "file_name": "2024", "file_category": "0", "count": 31, "folder_count": 3, "size": "120GB",
        ], id: "9")
        XCTAssertTrue(info.isDirectory)
        XCTAssertEqual(info.fileCount, 31)
        XCTAssertEqual(info.folderCount, 3)
    }

    func testMissingNameMeansTheItemIsGone() {
        XCTAssertThrowsError(try Direct115Client.parseFileInfo(["state": true], id: "9"))
        XCTAssertThrowsError(try Direct115Client.parseFileInfo(["state": false, "errno": 20004], id: "9")) { error in
            XCTAssertEqual(error as? Direct115FileError, .nameExists)
        }
    }

    func testParsesRecyclePageAndPaging() throws {
        let json: [String: Any] = [
            "state": true, "count": "5", "offset": 0, "page_size": 2,
            "data": [
                ["id": "r1", "file_name": "A.mkv", "file_size": "1024", "cid": "10", "parent_name": "电影", "dtime": "1700000000"],
                ["id": "r2", "file_name": "旧资料", "file_size": 0, "cid": 11, "parent_name": "网盘", "dtime": 1_700_000_100, "ico": "folder"],
            ],
        ]
        let page = try Direct115Client.parseRecyclePage(json, requestedOffset: 0, limit: 2)
        XCTAssertEqual(page.items.map(\.id), ["r1", "r2"])
        XCTAssertEqual(page.items[0].size, 1024)
        XCTAssertEqual(page.items[0].parentName, "电影")
        XCTAssertFalse(page.items[0].isDirectory)
        XCTAssertTrue(page.items[1].isDirectory)
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.nextOffset, 2)

        let last = try Direct115Client.parseRecyclePage(
            ["state": true, "count": 3, "data": [["id": "r3", "file_name": "C.mp4"]]], requestedOffset: 2, limit: 2)
        XCTAssertNil(last.nextOffset)
        let empty = try Direct115Client.parseRecyclePage(["state": true, "count": 0, "data": [[String: Any]]()], requestedOffset: 0, limit: 100)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.nextOffset)
    }

    // MARK: 请求

    func testCreateFolderSendsParentAndName() async throws {
        RoutedURLProtocol.install { _ in .json(["state": true, "cid": "9001", "cname": "新片"]) }
        let folder = try await client().createFolder(named: " 新片 ", in: "0")
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://webapi.115.com/files/add")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(RoutedURLProtocol.form(of: request), ["pid": "0", "cname": "新片"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("UID=1_test") == true)
        XCTAssertEqual(folder.id, "9001")
        XCTAssertEqual(folder.parentId, "0")
        XCTAssertTrue(folder.isDir)
    }

    func testCreateFolderReportsExistingName() async {
        RoutedURLProtocol.install { _ in .json(["state": false, "errno": 20004, "error": "文件名已存在"]) }
        do {
            _ = try await client().createFolder(named: "电影", in: "5")
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .nameExists)
        }
    }

    func testRenameSendsBothNameFields() async throws {
        RoutedURLProtocol.install { _ in self.ok() }
        try await client().rename("123", to: "新名字.mkv")
        let request = try XCTUnwrap(RoutedURLProtocol.requests().first)
        XCTAssertEqual(request.url?.absoluteString, "https://webapi.115.com/files/batch_rename")
        XCTAssertEqual(RoutedURLProtocol.form(of: request), ["fid": "123", "file_name": "新名字.mkv", "files_new_name[123]": "新名字.mkv"])
    }

    func testMoveCopyAndDeleteUseIndexedIDs() async throws {
        RoutedURLProtocol.install { _ in self.ok() }
        try await client().move(["1", "2"], to: "30")
        try await client().copy(["3"], to: "0")
        try await client().moveToRecycleBin(["4", "5"])
        let requests = RoutedURLProtocol.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/files/move", "/files/copy", "/rb/delete"])
        XCTAssertEqual(RoutedURLProtocol.form(of: requests[0]), ["pid": "30", "fid[0]": "1", "fid[1]": "2"])
        XCTAssertEqual(RoutedURLProtocol.form(of: requests[1]), ["pid": "0", "fid[0]": "3"])
        XCTAssertEqual(RoutedURLProtocol.form(of: requests[2]), ["fid[0]": "4", "fid[1]": "5"])
    }

    func testLargeSelectionsAreSentInBatches() async throws {
        RoutedURLProtocol.install { _ in self.ok() }
        try await client().moveToRecycleBin((1...130).map(String.init))
        let forms = RoutedURLProtocol.requests().map { RoutedURLProtocol.form(of: $0) }
        XCTAssertEqual(forms.map(\.count), [100, 30])
        XCTAssertEqual(forms[1]["fid[0]"], "101")
    }

    func testMoveRefusesRootAsASource() async {
        RoutedURLProtocol.install { _ in self.ok() }
        do {
            try await client().move(["0"], to: "5")
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .invalidID)
            XCTAssertTrue(RoutedURLProtocol.requests().isEmpty)
        }
    }

    func testMovingIntoItselfIsReportedClearly() async {
        RoutedURLProtocol.install { _ in .json(["state": false, "errno": 800006]) }
        do {
            try await client().move(["8"], to: "9")
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .cyclicMove)
        }
    }

    func testRecycleBinListingAndRestore() async throws {
        RoutedURLProtocol.install { request in
            if request.url?.path == "/rb" {
                return .json(["state": true, "count": 1, "data": [["id": "r9", "file_name": "X.mp4", "file_size": 5, "dtime": 1_700_000_000]]])
            }
            return self.ok()
        }
        let page = try await client().recycleBin(offset: 0, limit: 50)
        XCTAssertEqual(page.items.map(\.name), ["X.mp4"])
        let listing = try XCTUnwrap(RoutedURLProtocol.requests().first?.url?.query)
        XCTAssertTrue(listing.contains("aid=7"))
        XCTAssertTrue(listing.contains("limit=50"))
        try await client().restoreFromRecycleBin(["r9"])
        let restore = try XCTUnwrap(RoutedURLProtocol.requests().last)
        XCTAssertEqual(restore.url?.path, "/rb/revert")
        XCTAssertEqual(RoutedURLProtocol.form(of: restore), ["rid[0]": "r9"])
    }

    func testPermanentDeleteSendsSecurityKeyAndEmptyListClearsEverything() async throws {
        RoutedURLProtocol.install { _ in self.ok() }
        try await client().deleteFromRecycleBin(["r1", "r2"], securityKey: "123456")
        try await client().deleteFromRecycleBin([])
        let forms = RoutedURLProtocol.requests().map { RoutedURLProtocol.form(of: $0) }
        XCTAssertEqual(forms[0], ["password": "123456", "rid[0]": "r1", "rid[1]": "r2"])
        XCTAssertEqual(forms[1], ["password": "000000"])
    }

    func testWrongSecurityKeyAsksForTheKey() async {
        RoutedURLProtocol.install { _ in .json(["state": false, "error": "安全密钥错误"]) }
        do {
            try await client().deleteFromRecycleBin(["r1"])
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual(error as? Direct115FileError, .needsSecurityKey("安全密钥错误"))
        }
    }

    func testHTTPFailureAndGarbageAreReported() async {
        RoutedURLProtocol.install { _ in .init(status: 502) }
        do {
            try await client().rename("1", to: "x")
            XCTFail("应该失败")
        } catch {
            XCTAssertEqual((error as? Direct115HTTPError)?.statusCode, 502)
        }
        RoutedURLProtocol.install { _ in .init(status: 200, body: Data("<html>".utf8)) }
        do {
            try await client().rename("1", to: "x")
            XCTFail("应该失败")
        } catch {
            XCTAssertNotNil(error as? APIError)
        }
    }

    func testDownloadRequestUsesPlayerHeaders() throws {
        let request = client().downloadRequest(for: try XCTUnwrap(URL(string: "https://cdn.example.test/a.mkv")))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), Direct115Client.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://115.com/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "UID=1_test; CID=abc")
    }
}
