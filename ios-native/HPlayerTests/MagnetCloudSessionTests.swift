import XCTest
@testable import HPlayer

@MainActor
final class MagnetCloudSessionTests: XCTestCase {
    private func completedCloudController() -> MagnetController {
        let file = P115File(id: "old-file", parentId: "0", name: "Episode.mkv", isDir: false,
                            kind: "video", size: 1024, pickCode: "old-account-pick", sha1: "", updatedAt: "", thumbUrl: "")
        let catalog = MagnetCatalog(cloudVideos: [Direct115CloudVideo(file: file, folder: "")],
                                    name: "Show", totalSize: 1024)
        let controller = MagnetController.interfaceFixture(catalog: catalog,
                                                            cloudClient: Direct115Client(cookie: "UID=account-a"))
        let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
        controller.cloudQueue = PlaybackQueue(source: source, items: [source])
        return controller
    }

    func testSwitchingAccountsDiscardsPreviousCloudFilesAndPlaybackQueue() {
        let controller = completedCloudController()
        controller.configureCloud(client: Direct115Client(cookie: "UID=account-b"), enabled: true)
        XCTAssertNil(controller.catalog)
        XCTAssertNil(controller.cloudCatalog)
        XCTAssertNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .off)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.usesCloud)
    }

    func testLogoutDiscardsPreviousCloudFilesAndPlaybackQueue() {
        let controller = completedCloudController()
        controller.configureCloud(client: nil, enabled: true)
        XCTAssertNil(controller.catalog)
        XCTAssertNil(controller.cloudCatalog)
        XCTAssertNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .off)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.usesCloud)
    }

    func testReconfiguringSameSessionPreservesCompletedCloudFiles() {
        let controller = completedCloudController()
        controller.configureCloud(client: Direct115Client(cookie: "UID=account-a"), enabled: true)
        XCTAssertNotNil(controller.catalog)
        XCTAssertNotNil(controller.cloudCatalog)
        XCTAssertNotNil(controller.cloudQueue)
        XCTAssertEqual(controller.cloud, .ready)
        XCTAssertEqual(controller.phase, .ready)
    }

    func testPrepareDefaultCloudQueueSelectsLargestMainVideoForMultiFileCatalog() {
        MagnetHistoryStore.shared.remove("0123456789012345678901234567890123456789")
        let ep1 = P115File(id: "f1", parentId: "0", name: "EP01.mkv", isDir: false,
                           kind: "video", size: 500_000_000, pickCode: "pc-ep1", sha1: "", updatedAt: "", thumbUrl: "")
        let ep2 = P115File(id: "f2", parentId: "0", name: "EP02.mkv", isDir: false,
                           kind: "video", size: 800_000_000, pickCode: "pc-ep2", sha1: "", updatedAt: "", thumbUrl: "")
        let catalog = MagnetCatalog(
            cloudVideos: [
                Direct115CloudVideo(file: ep1, folder: ""),
                Direct115CloudVideo(file: ep2, folder: ""),
            ],
            name: "SSIS-001",
            totalSize: 1_300_000_000
        )
        let controller = MagnetController.interfaceFixture(
            catalog: catalog,
            cloudClient: Direct115Client(cookie: "UID=account-a")
        )
        XCTAssertNil(controller.cloudQueue)

        controller.prepareDefaultCloudQueueIfReady()
        let queue = controller.cloudQueue
        XCTAssertNotNil(queue, "多文件 115 目录就绪时应能同步生成默认播放队列，避免首帧闪屏")
        XCTAssertEqual(queue?.source.id, "p115|pc-ep2", "无历史记录时应默认选中体积最大的正片")
        XCTAssertEqual(queue?.items.count, 2)
        XCTAssertTrue(queue?.source.title.contains("SSIS-001") == true, "单文件名不含番号时应自动附带种子番号便于辨识与字幕匹配")
    }
}
