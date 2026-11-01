import XCTest
@testable import HPlayer

@MainActor
final class P115AccountInfoStoreTests: XCTestCase {
    func testRepeatedRequestsShareWorkAndReuseFreshValues() async {
        let gate = AccountInfoGate(), store = makeStore(gate)
        let session = UUID(), client = Direct115Client(cookie: "account-a")
        let first = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 1)
        let second = Task { await store.refreshIfNeeded(session: session, client: client) }
        await Task.yield()
        let countsDuringLoad = await gate.counts(client.cookie)
        XCTAssertEqual(countsDuringLoad.status, 1)
        XCTAssertEqual(countsDuringLoad.quota, 1)

        await gate.finishStatus(client.cookie, .success(status("账号甲")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await first.value
        await second.value
        XCTAssertEqual(store.status(for: session)?.userName, "账号甲")
        XCTAssertEqual(store.quota(for: session)?.usedText, "1 GB")
        XCTAssertFalse(store.isLoading(for: session))

        await store.refreshIfNeeded(session: session, client: client)
        let countsAfterSwitch = await gate.counts(client.cookie)
        XCTAssertEqual(countsAfterSwitch.status, 1)
        XCTAssertEqual(countsAfterSwitch.quota, 1)
    }

    func testRefreshKeepsVisibleValuesWhileNewDataLoads() async {
        var date = Date(timeIntervalSince1970: 1000)
        let gate = AccountInfoGate(), store = makeStore(gate, now: { date })
        let session = UUID(), client = Direct115Client(cookie: "account-a")
        let initial = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 1)
        await gate.finishStatus(client.cookie, .success(status("账号甲")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await initial.value

        date.addTimeInterval(301)
        let refresh = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 2)
        XCTAssertEqual(store.status(for: session)?.userName, "账号甲")
        XCTAssertEqual(store.quota(for: session)?.usedText, "1 GB")
        XCTAssertTrue(store.isLoading(for: session))
        await gate.finishStatus(client.cookie, .success(status("账号甲更新")))
        await gate.finishQuota(client.cookie, .success(quota("2 GB")))
        await refresh.value
        XCTAssertEqual(store.status(for: session)?.userName, "账号甲更新")
        XCTAssertEqual(store.quota(for: session)?.usedText, "2 GB")
    }

    func testChangingSessionDiscardsOlderResponses() async {
        let gate = AccountInfoGate(), store = makeStore(gate)
        let oldSession = UUID(), newSession = UUID()
        let oldClient = Direct115Client(cookie: "account-a"), newClient = Direct115Client(cookie: "account-b")
        let old = Task { await store.refreshIfNeeded(session: oldSession, client: oldClient) }
        await waitForRequests(gate, cookie: oldClient.cookie, count: 1)
        let current = Task { await store.refreshIfNeeded(session: newSession, client: newClient) }
        await waitForRequests(gate, cookie: newClient.cookie, count: 1)
        XCTAssertNil(store.status(for: oldSession))
        XCTAssertNil(store.quota(for: oldSession))
        await gate.finishStatus(newClient.cookie, .success(status("账号乙")))
        await gate.finishQuota(newClient.cookie, .success(quota("2 GB")))
        await current.value
        // The old server deliberately ignores cancellation and returns afterwards.
        await gate.finishStatus(oldClient.cookie, .success(status("账号甲")))
        await gate.finishQuota(oldClient.cookie, .success(quota("1 GB")))
        await old.value
        XCTAssertEqual(store.status(for: newSession)?.userName, "账号乙")
        XCTAssertEqual(store.quota(for: newSession)?.usedText, "2 GB")
        XCTAssertNil(store.status(for: oldSession))
    }

    func testLogoutClearsCachedDataAndRejectsLateResponses() async {
        var date = Date(timeIntervalSince1970: 1000)
        let gate = AccountInfoGate(), store = makeStore(gate, now: { date })
        let session = UUID(), loggedOut = UUID(), client = Direct115Client(cookie: "account-a")
        let initial = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 1)
        await gate.finishStatus(client.cookie, .success(status("旧账号")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await initial.value
        XCTAssertEqual(store.status(for: session)?.userName, "旧账号")
        date.addTimeInterval(301)
        let pending = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 2)
        await store.refreshIfNeeded(session: loggedOut, client: nil)
        XCTAssertNil(store.status(for: session))
        XCTAssertNil(store.status(for: loggedOut))
        XCTAssertNil(store.quota(for: loggedOut))
        XCTAssertFalse(store.isLoading(for: loggedOut))
        await gate.finishStatus(client.cookie, .success(status("旧账号")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await pending.value
        XCTAssertNil(store.status(for: loggedOut))
        XCTAssertNil(store.quota(for: loggedOut))
    }

    func testFailureKeepsCachedValuesAndThrottlesRetries() async {
        var date = Date(timeIntervalSince1970: 1000)
        let gate = AccountInfoGate(), store = makeStore(gate, now: { date })
        let session = UUID(), client = Direct115Client(cookie: "account-a")
        let initial = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 1)
        await gate.finishStatus(client.cookie, .success(status("账号甲")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await initial.value
        date.addTimeInterval(301)
        let failed = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 2)
        await gate.finishStatus(client.cookie, .failure(APIError.server("网络暂不可用")))
        await gate.finishQuota(client.cookie, .failure(APIError.server("网络暂不可用")))
        await failed.value
        XCTAssertEqual(store.status(for: session)?.userName, "账号甲")
        XCTAssertEqual(store.quota(for: session)?.usedText, "1 GB")
        XCTAssertFalse(store.error(for: session).isEmpty)
        await store.refreshIfNeeded(session: session, client: client)
        let throttled = await gate.counts(client.cookie)
        XCTAssertEqual(throttled.status, 2)
        XCTAssertEqual(throttled.quota, 2)
        date.addTimeInterval(31)
        let retry = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 3)
        await gate.finishStatus(client.cookie, .success(status("账号甲")))
        await gate.finishQuota(client.cookie, .success(quota("2 GB")))
        await retry.value
        XCTAssertTrue(store.error(for: session).isEmpty)
        XCTAssertEqual(store.quota(for: session)?.usedText, "2 GB")
    }

    func testExplicitValidationCannotBeOverwrittenByAnOlderRequest() async {
        let gate = AccountInfoGate(), store = makeStore(gate)
        let session = UUID(), client = Direct115Client(cookie: "account-a")
        let pending = Task { await store.refreshIfNeeded(session: session, client: client) }
        await waitForRequests(gate, cookie: client.cookie, count: 1)
        store.record(status("已验证"), for: session)
        await gate.finishStatus(client.cookie, .success(status("旧结果")))
        await gate.finishQuota(client.cookie, .success(quota("1 GB")))
        await pending.value
        XCTAssertEqual(store.status(for: session)?.userName, "已验证")
        XCTAssertFalse(store.isLoading(for: session))
    }

    func testAlreadyCancelledRefreshCannotReplaceCurrentSession() async {
        let gate = AccountInfoGate(), store = makeStore(gate)
        let current = UUID(), old = UUID()
        store.seed(session: current, status: status("当前账号"), quota: quota("1 GB"))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refreshIfNeeded(session: old, client: Direct115Client(cookie: "old"))
        }
        await cancelled.value
        XCTAssertEqual(store.status(for: current)?.userName, "当前账号")
        XCTAssertNil(store.status(for: old))
        let counts = await gate.counts("old")
        XCTAssertEqual(counts.status, 0)
        XCTAssertEqual(counts.quota, 0)
    }

    private func makeStore(_ gate: AccountInfoGate, now: @escaping () -> Date = { Date() }) -> P115AccountInfoStore {
        P115AccountInfoStore(fetchStatus: { try await gate.status($0.cookie) },
                             fetchQuota: { try await gate.quota($0.cookie) }, now: now)
    }

    private func status(_ name: String) -> P115Status {
        P115Status(configured: true, userId: 1, userName: name, vip: 1, error: nil, message: nil)
    }

    private func quota(_ used: String) -> QuotaResponse {
        QuotaResponse(usedText: used, totalText: "5 GB", usedBytes: 1, totalBytes: 5)
    }

    private func waitForRequests(_ gate: AccountInfoGate, cookie: String, count: Int) async {
        let ready = await gate.waitForRequests(cookie, count: count)
        XCTAssertTrue(ready, "The expected account requests should start")
    }
}

private actor AccountInfoGate {
    private var statusCalls: [String: Int] = [:]
    private var quotaCalls: [String: Int] = [:]
    private var pendingStatus: [String: [CheckedContinuation<P115Status, Error>]] = [:]
    private var pendingQuota: [String: [CheckedContinuation<QuotaResponse, Error>]] = [:]

    func status(_ cookie: String) async throws -> P115Status {
        statusCalls[cookie, default: 0] += 1
        return try await withCheckedThrowingContinuation { pendingStatus[cookie, default: []].append($0) }
    }

    func quota(_ cookie: String) async throws -> QuotaResponse {
        quotaCalls[cookie, default: 0] += 1
        return try await withCheckedThrowingContinuation { pendingQuota[cookie, default: []].append($0) }
    }

    func counts(_ cookie: String) -> (status: Int, quota: Int) {
        (statusCalls[cookie, default: 0], quotaCalls[cookie, default: 0])
    }

    func waitForRequests(_ cookie: String, count: Int) async -> Bool {
        for _ in 0..<500 {
            if statusCalls[cookie, default: 0] >= count && quotaCalls[cookie, default: 0] >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func finishStatus(_ cookie: String, _ result: Result<P115Status, Error>) {
        pendingStatus.removeValue(forKey: cookie)?.forEach { $0.resume(with: result) }
    }

    func finishQuota(_ cookie: String, _ result: Result<QuotaResponse, Error>) {
        pendingQuota.removeValue(forKey: cookie)?.forEach { $0.resume(with: result) }
    }
}
