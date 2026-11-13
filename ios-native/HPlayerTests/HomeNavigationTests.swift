import SwiftUI
import XCTest
@testable import HPlayer

final class HomeNavigationTests: XCTestCase {
    func testSystemPopUpdatesCloudBreadcrumbsBeforeOpeningAnotherFolder() {
        let navigation = HomeNavigation()
        let root = CloudRoute.folder(Crumb(cid: "0", name: "115 网盘"))
        let first = CloudRoute.folder(Crumb(cid: "1", name: "电影"))
        let second = CloudRoute.folder(Crumb(cid: "2", name: "剧集"))
        navigation.setCloudRoutes([root, first])

        navigation.path.removeLast()
        XCTAssertEqual(navigation.cloudRoutes, [root])

        navigation.setCloudRoutes(navigation.cloudRoutes + [second])
        XCTAssertEqual(navigation.cloudRoutes, [root, second])
        XCTAssertEqual(navigation.path.count, 2)
    }

    func testCancelledPopCanRestoreTheWholeCloudPath() {
        let navigation = HomeNavigation()
        let routes: [CloudRoute] = [
            .folder(Crumb(cid: "0", name: "115 网盘")),
            .folder(Crumb(cid: "1", name: "电影")),
            .page(.offline)
        ]
        navigation.setCloudRoutes(routes)
        let beforePop = navigation.path

        navigation.path.removeLast(navigation.path.count)
        XCTAssertTrue(navigation.cloudRoutes.isEmpty)
        navigation.path = beforePop
        XCTAssertEqual(navigation.cloudRoutes, routes)
    }

    func testChangingTabsDoesNotReuseCloudBreadcrumbsForOtherRoutes() {
        let navigation = HomeNavigation()
        navigation.setCloudRoutes([.folder(Crumb(cid: "0", name: "115 网盘"))])
        navigation.path.removeLast()

        // HomeView 切换标签时清空上一标签的路径，再接受演员或动漫等其他路由。
        navigation.setCloudRoutes([])
        navigation.path.append(PerformerRoute(id: "actor", name: "演员"))
        XCTAssertTrue(navigation.cloudRoutes.isEmpty)
        XCTAssertEqual(navigation.path.count, 1)
    }
}
