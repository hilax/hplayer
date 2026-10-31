import XCTest
@testable import HPlayer

@MainActor
final class AppStateTests: XCTestCase {
    /// 读钥匙串要和系统服务通信。首页每刷新一次、打开播放页都会问一遍登录账号，
    /// 反复读会拖慢点封面之后的响应，所以读到一次就放在内存里。
    func testSavedSessionIsReadOnceInsteadOfOnEveryAccess() async {
        var reads = 0
        let state = AppState(cookieLoader: {
            reads += 1
            return "UID=12345_99; CID=local-session"
        })
        XCTAssertEqual(reads, 1, "Restoring the session reads the saved cookie once")

        XCTAssertEqual(state.libraryAccountID, "device:12345")
        XCTAssertEqual(state.directCookie, "UID=12345_99; CID=local-session")
        XCTAssertNotNil(state.directClient())
        XCTAssertEqual(state.libraryAccountID, "device:12345")
        XCTAssertEqual(reads, 1, "Later accesses must come from memory")

        // 启动时的登录检查会重新读一次，防止第一次读的时候手机还没解锁
        await state.checkAuth()
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.libraryAccountID, "device:12345")
        XCTAssertEqual(reads, 2)
    }

    func testMissingSessionIsRememberedToo() async {
        var reads = 0
        let state = AppState(cookieLoader: {
            reads += 1
            return nil
        })
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.libraryAccountID)
        XCTAssertNil(state.directClient())
        XCTAssertEqual(reads, 1)

        await state.checkAuth()
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testPlayerCacheBudgetStaysWithinLimits() {
        let limit = PlayerDiskCache.limitMiB()
        XCTAssertGreaterThanOrEqual(limit, 64)
        XCTAssertLessThanOrEqual(limit, 2048)
    }
}
