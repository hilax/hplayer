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

    func testCancelledValidationCannotSaveCredentials() async {
        let gate = LoginValidationGate()
        var saved: [String] = []
        let state = AppState(cookieLoader: { nil }, cookieValidator: gate.validate,
                             cookieSaver: { saved.append($0) }, cookieRemover: {})
        let pending = Task {
            do { try await state.connectDirect(cookie: "UID=123_1"); return false }
            catch { return error is CancellationError }
        }
        await gate.waitForRequest("UID=123_1")
        pending.cancel()
        // 验证服务故意忽略取消，仍然返回成功。
        await gate.finish("UID=123_1")
        let cancelled = await pending.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.directClient())
    }

    func testLogoutInvalidatesPendingLogin() async {
        let gate = LoginValidationGate()
        var saved: [String] = []
        var removals = 0
        let state = AppState(cookieLoader: { "UID=100_1" }, cookieValidator: gate.validate,
                             cookieSaver: { saved.append($0) }, cookieRemover: { removals += 1 })
        let previousSession = state.sessionID
        let pending = Task { try? await state.connectDirect(cookie: "UID=200_1") }
        await gate.waitForRequest("UID=200_1")
        state.logout()
        await gate.finish("UID=200_1")
        await pending.value
        XCTAssertEqual(removals, 1)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.libraryAccountID)
        XCTAssertNotEqual(state.sessionID, previousSession)
    }

    func testNewerLoginCannotBeReplacedByAnOlderValidation() async {
        let gate = LoginValidationGate()
        var saved: [String] = []
        let state = AppState(cookieLoader: { nil }, cookieValidator: gate.validate,
                             cookieSaver: { saved.append($0) }, cookieRemover: {})
        let older = Task { try? await state.connectDirect(cookie: "UID=100_1") }
        await gate.waitForRequest("UID=100_1")
        let newer = Task { try? await state.connectDirect(cookie: "UID=200_1") }
        await gate.waitForRequest("UID=200_1")
        await gate.finish("UID=200_1")
        await newer.value
        let currentSession = state.sessionID
        await gate.finish("UID=100_1")
        await older.value
        XCTAssertEqual(saved, ["UID=200_1"])
        XCTAssertEqual(state.libraryAccountID, "device:200")
        XCTAssertEqual(state.sessionID, currentSession)
    }

    func testSessionChangesWhenTheSameAccountReconnectsOrRestoresNewCredentials() async throws {
        var cookie: String? = "UID=100_1; CID=old"
        let state = AppState(cookieLoader: { cookie }, cookieValidator: { _ in },
                             cookieSaver: { cookie = $0 }, cookieRemover: {})
        let original = state.sessionID
        await state.checkAuth()
        XCTAssertEqual(state.sessionID, original)
        try await state.connectDirect(cookie: "UID=100_1; CID=new")
        XCTAssertNotEqual(state.sessionID, original)
        let reconnected = state.sessionID
        cookie = "UID=100_1; CID=restored"
        await state.checkAuth()
        XCTAssertNotEqual(state.sessionID, reconnected)
        XCTAssertEqual(state.libraryAccountID, "device:100")
    }

    func testWhitespaceIsNotAUsableSession() {
        let state = AppState(cookieLoader: { " \n\t" })
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.directClient())
    }
}

private actor LoginValidationGate {
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func validate(_ cookie: String) async throws {
        await withCheckedContinuation { continuation in
            pending[cookie] = continuation
            waiting.removeValue(forKey: cookie)?.forEach { $0.resume() }
        }
    }

    func waitForRequest(_ cookie: String) async {
        if pending[cookie] != nil { return }
        await withCheckedContinuation { waiting[cookie, default: []].append($0) }
    }

    func finish(_ cookie: String) {
        pending.removeValue(forKey: cookie)?.resume()
    }
}
