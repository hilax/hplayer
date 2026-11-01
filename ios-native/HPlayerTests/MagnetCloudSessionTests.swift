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
}
