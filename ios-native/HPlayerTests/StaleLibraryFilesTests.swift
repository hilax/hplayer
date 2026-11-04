import XCTest
@testable import HPlayer

final class StaleLibraryFilesTests: XCTestCase {
    private func video(_ pickCode: String, parent: String) -> P115File {
        P115File(id: "id-\(pickCode)", parentId: parent, name: "\(pickCode).mkv", isDir: false, kind: "video",
                 size: 1, pickCode: pickCode, sha1: "", updatedAt: "", thumbUrl: "")
    }

    private func entry(_ parent: String, _ name: String) -> CloudFolderEntry { CloudFolderEntry(parent: parent, name: name) }

    func testWholeDiskReportsEveryRecordedVideoThatWasNotFound() {
        let library = [video("a", parent: "10"), video("b", parent: "20"), video("c", parent: "0"), video("d", parent: "30")]
        let groups = StaleLibraryFiles.find(
            library: library, found: ["a"],
            liveFolders: ["10": entry("0", "甲"), "20": entry("0", "乙")],
            recordedFolders: ["30": entry("0", "已删除的文件夹")],
            scopeFolderID: nil, scopeName: "整个网盘")
        XCTAssertEqual(Set(groups.flatMap { $0.files.map(\.pickCode) }), ["b", "c", "d"])
        XCTAssertEqual(groups.first?.folderName, "已删除的文件夹", "A folder that no longer exists is listed first")
        XCTAssertEqual(groups.first?.reason, .folderGone)
        XCTAssertEqual(groups.first { $0.folderID == "20" }?.reason, .fileGone)
        XCTAssertEqual(groups.first { $0.folderID == "0" }?.folderName, "115 网盘根目录")
        XCTAssertEqual(groups.first { $0.folderID == "0" }?.reason, .fileGone)
    }

    func testWholeDiskNamesAFolderThatWasNeverRecorded() {
        let groups = StaleLibraryFiles.find(library: [video("x", parent: "99")], found: [], liveFolders: [:],
                                            recordedFolders: [:], scopeFolderID: nil, scopeName: "整个网盘")
        XCTAssertEqual(groups.map(\.folderName), ["名称没有记录的文件夹"])
        XCTAssertEqual(groups.first?.reason, .folderGone)
    }

    func testFolderScopeOnlyLooksInsideTheChosenFolderAndFollowsDeletedSubfolders() {
        let library = [
            video("p1", parent: "P"), video("p2", parent: "P"),   // p1 还在，p2 不在
            video("q1", parent: "Q"),                              // Q 还在，但 q1 不在了
            video("r1", parent: "R"),                              // R 是以前记过的 P 的子文件夹，现在没了
            video("s1", parent: "S"),                              // S 在 R 里面
            video("z1", parent: "Z"),                              // 别的目录，不能动
            video("o1", parent: "0"),                              // 位置不明（比如从搜索加入），不能动
        ]
        let groups = StaleLibraryFiles.find(
            library: library, found: ["p1"],
            liveFolders: ["Q": entry("P", "子文件夹")],
            recordedFolders: ["Q": entry("P", "子文件夹"), "R": entry("P", "被删的"), "S": entry("R", "孙文件夹"), "Z": entry("other", "别处")],
            scopeFolderID: "P", scopeName: "所选文件夹")
        XCTAssertEqual(Set(groups.flatMap { $0.files.map(\.pickCode) }), ["p2", "q1", "r1", "s1"])
        XCTAssertEqual(groups.first { $0.folderID == "P" }?.folderName, "所选文件夹")
        XCTAssertEqual(groups.first { $0.folderID == "P" }?.reason, .fileGone)
        XCTAssertEqual(groups.first { $0.folderID == "R" }?.reason, .folderGone)
        XCTAssertEqual(groups.first { $0.folderID == "S" }?.reason, .folderGone)
        XCTAssertEqual(Array(groups.map(\.reason).prefix(2)), [.folderGone, .folderGone], "Folders that are gone sort first")
    }

    func testNothingIsStaleWhenEveryVideoWasFound() {
        let library = [video("a", parent: "10")]
        XCTAssertTrue(StaleLibraryFiles.find(library: library, found: ["a"], liveFolders: ["10": entry("0", "甲")],
                                             recordedFolders: [:], scopeFolderID: nil, scopeName: "整个网盘").isEmpty)
    }

    func testFolderCyclesInTheRecordDoNotHangTheSearch() {
        let groups = StaleLibraryFiles.find(
            library: [video("a", parent: "B")], found: [], liveFolders: [:],
            recordedFolders: ["A": entry("B", "A"), "B": entry("A", "B")],
            scopeFolderID: "A", scopeName: "A")
        XCTAssertEqual(groups.flatMap { $0.files.map(\.pickCode) }, ["a"])
    }
}
