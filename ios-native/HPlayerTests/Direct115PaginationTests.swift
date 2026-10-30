import XCTest
@testable import HPlayer

final class Direct115PaginationTests: XCTestCase {
    private func rawFile(_ id: String) -> [String: Any] {
        ["fid": id, "n": "Video \(id).mkv", "pc": "pick\(id)", "isv": 1]
    }

    func testParsesReportedOffsetAndContinuesShortPageWhenCountHasMore() throws {
        let page = try Direct115Client.parseFilesPage(
            ["offset": "500", "count": "800", "data": [rawFile("1"), rawFile("2")]],
            cid: "10", requestedOffset: 500, limit: 500
        )
        XCTAssertEqual(page.files.map(\.id), ["1", "2"])
        XCTAssertEqual(page.files.map(\.parentId), ["10", "10"])
        XCTAssertEqual(page.nextOffset, 502)
    }

    func testKnownCountEndsExactlyAtFinalPage() throws {
        let page = try Direct115Client.parseFilesPage(
            ["offset": 2, "count": 3, "data": [rawFile("3")]],
            cid: "0", requestedOffset: 2, limit: 1
        )
        XCTAssertEqual(page.files.count, 1)
        XCTAssertNil(page.nextOffset)
    }

    func testRejectsEmptyPageWithKnownRemainingFiles() {
        XCTAssertThrowsError(try Direct115Client.parseFilesPage(
            ["offset": 500, "count": 700, "data": [[String: Any]]()],
            cid: "0", requestedOffset: 500, limit: 500
        ))
    }

    func testAllowsEmptyPageAtKnownEndAndOffsetOmission() throws {
        let page = try Direct115Client.parseFilesPage(
            ["count": 500, "data": [[String: Any]]()],
            cid: "0", requestedOffset: 500, limit: 500
        )
        XCTAssertTrue(page.files.isEmpty)
        XCTAssertNil(page.nextOffset)
    }

    func testRejectsMismatchedReportedOffsetAndInvalidCount() {
        XCTAssertThrowsError(try Direct115Client.parseFilesPage(
            ["offset": 0, "count": 501, "data": [rawFile("1")]],
            cid: "0", requestedOffset: 500, limit: 500
        ))
        for value in ["not-a-count", "-1"] {
            XCTAssertThrowsError(try Direct115Client.parseFilesPage(
                ["count": value, "data": [rawFile("1")]],
                cid: "0", requestedOffset: 0, limit: 500
            ))
        }
    }

    func testCollectsEveryPageUsingReturnedOffsets() async throws {
        var requests: [Int] = []
        let files = try await Direct115Client.collectFiles(pageDelayNanoseconds: 0) { offset in
            requests.append(offset)
            let raw = self.rawFile(String(offset + 1))
            return try Direct115Client.parseFilesPage(
                ["offset": offset, "count": 3, "data": [raw]],
                cid: "0", requestedOffset: offset, limit: 1
            )
        }
        XCTAssertEqual(requests, [0, 1, 2])
        XCTAssertEqual(files.map(\.id), ["1", "2", "3"])
    }

    func testCollectorRejectsRepeatedTerminalPageInsteadOfReturningIncompleteList() async {
        var requests: [Int] = []
        do {
            _ = try await Direct115Client.collectFiles(pageDelayNanoseconds: 0) { offset in
                requests.append(offset)
                return Direct115FilePage(files: [P115File(id: "1", parentId: "0", name: "Video.mkv", isDir: false,
                    kind: "video", size: 1, pickCode: "pick", sha1: "", updatedAt: "", thumbUrl: "")],
                    nextOffset: offset == 0 ? 500 : nil)
            }
            XCTFail("Repeated page must fail even when it claims to be the final page")
        } catch {
            XCTAssertEqual(requests, [0, 500])
        }
    }

    func testCollectorRejectsAnOffsetThatDoesNotAdvance() async {
        do {
            _ = try await Direct115Client.collectFiles(pageDelayNanoseconds: 0) { _ in
                Direct115FilePage(files: [], nextOffset: 0)
            }
            XCTFail("Invalid pagination must fail rather than loop forever")
        } catch { }
    }
}
