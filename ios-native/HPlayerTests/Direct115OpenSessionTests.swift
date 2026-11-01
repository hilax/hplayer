import XCTest
@testable import HPlayer

@MainActor
final class Direct115OpenSessionTests: XCTestCase {
    func testOlderDeviceCodeCannotReplaceANewerRequest() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let older = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(1)
        let newer = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(2)
        await f.network.finish(1, response: code("new"))
        _ = try await newer.value
        await f.network.finish(0, response: code("old"))
        do { _ = try await older.value; XCTFail("The old QR must be rejected") } catch { }
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        try await f.network.waitForCount(3)
        let url = await f.network.request(2).url!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uid" })?.value, "new")
        await f.network.finish(2, response: ["state": true, "data": ["status": 0]])
        _ = try await poll.value
    }

    func testLateExpiredPollCannotClearANewerQRCode() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let first = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(1)
        await f.network.finish(0, response: code("old")); _ = try await first.value
        let oldPoll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        try await f.network.waitForCount(2)
        let newer = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(3)
        await f.network.finish(2, response: code("new")); _ = try await newer.value
        await f.network.finish(1, response: ["state": false])
        do { _ = try await oldPoll.value; XCTFail("The old poll must be rejected") } catch { }
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        try await f.network.waitForCount(4)
        let url = await f.network.request(3).url!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uid" })?.value, "new")
        await f.network.finish(3, response: ["state": true, "data": ["status": 0]])
        _ = try await poll.value
    }

    func testChangingAppIDInvalidatesAnInFlightDeviceCode() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let start = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(1)
        _ = try await f.client.route(path: "/api/115/open/config", method: "POST", body: try JSONEncoder().encode(["clientId": "app-b"]))
        await f.network.finish(0, response: code("old"))
        do { _ = try await start.value; XCTFail("An old AppID must not supply the current QR") } catch { }
        let data = try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "expired")
    }

    func testUnauthorizedWriteCannotReplayUnderANewlyAuthorizedAccount() async throws {
        let f = fixture(); defer { f.cleanUp() }
        saveTokens(access: "account-a", refresh: "refresh-a", fixture: f)
        let write = Task { try await f.client.route(path: "/api/115/torrent/tasks", method: "POST", body: taskBody()) }
        try await f.network.waitForCount(1)
        let start = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        try await f.network.waitForCount(2)
        await f.network.finish(1, response: code("account-b")); _ = try await start.value
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        try await f.network.waitForCount(3)
        await f.network.finish(2, response: ["state": true, "data": ["status": 2]])
        try await f.network.waitForCount(4)
        await f.network.finish(3, response: tokens(access: "account-b", refresh: "refresh-b"))
        _ = try await poll.value
        await f.network.finish(0, response: ["state": false, "code": 40140125])
        do { _ = try await write.value; XCTFail("An old write must not be sent with the new account") } catch { }
        let count = await f.network.count
        XCTAssertEqual(count, 4)
        XCTAssertTrue(f.storage.load(f.tokenKey)?.contains("account-b") == true)
    }

    func testExpiredTokenRefreshStillRetriesWithinTheSameAuthorization() async throws {
        let f = fixture(); defer { f.cleanUp() }
        saveTokens(access: "old-access", refresh: "old-refresh", fixture: f)
        let write = Task { try await f.client.route(path: "/api/115/torrent/tasks", method: "POST", body: taskBody()) }
        try await f.network.waitForCount(1)
        await f.network.finish(0, response: ["state": false, "code": 40140125])
        try await f.network.waitForCount(2)
        let refreshURL = await f.network.request(1).url?.path
        XCTAssertEqual(refreshURL, "/open/refreshToken")
        await f.network.finish(1, response: tokens(access: "new-access", refresh: "new-refresh"))
        try await f.network.waitForCount(3)
        let bearer = await f.network.request(2).value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(bearer, "Bearer new-access")
        await f.network.finish(2, response: ["state": true])
        _ = try await write.value
        XCTAssertTrue(f.storage.load(f.tokenKey)?.contains("new-refresh") == true)
    }

    private func code(_ uid: String) -> [String: Any] {
        ["state": true, "data": ["uid": uid, "time": "1", "sign": "signature", "qrcode": "https://115.com/\(uid)"]]
    }
    private func tokens(access: String, refresh: String) -> [String: Any] {
        ["state": true, "data": ["access_token": access, "refresh_token": refresh, "expires_in": 7200]]
    }
    private func taskBody() throws -> Data {
        try JSONEncoder().encode(["sha1": String(repeating: "a", count: 40), "pickCode": "abc123", "infoHash": String(repeating: "b", count: 40), "wanted": "0", "savePath": "HPlayer", "folderId": "0"])
    }
    private func saveTokens(access: String, refresh: String, fixture: OpenSessionFixture) {
        let value: [String: Any] = ["access": access, "refresh": refresh, "expiresAt": Date().addingTimeInterval(7200).timeIntervalSinceReferenceDate]
        let data = try! JSONSerialization.data(withJSONObject: value)
        fixture.storage.save(String(data: data, encoding: .utf8)!, fixture.tokenKey)
    }
    private func fixture() -> OpenSessionFixture {
        let suffix = UUID().uuidString
        let clientKey = "test.open.client.\(suffix)", tokenKey = "test.open.tokens.\(suffix)"
        let memory = OpenSessionCredentials()
        let storage = Direct115Open.CredentialStorage(load: memory.load, save: memory.save, delete: memory.delete)
        storage.save("app-a", clientKey)
        let network = OpenSessionNetwork()
        return OpenSessionFixture(client: Direct115Open(clientKey: clientKey, tokenKey: tokenKey, transport: network.send, storage: storage), network: network, storage: storage, clientKey: clientKey, tokenKey: tokenKey)
    }
}

private struct OpenSessionFixture {
    let client: Direct115Open
    let network: OpenSessionNetwork
    let storage: Direct115Open.CredentialStorage
    let clientKey: String
    let tokenKey: String
    func cleanUp() { storage.delete(clientKey); storage.delete(tokenKey) }
}

private final class OpenSessionCredentials {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func load(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    func save(_ value: String, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

private actor OpenSessionNetwork {
    private struct WaitTimeout: LocalizedError {
        let expected: Int
        let actual: Int
        var errorDescription: String? { "Mock network expected \(expected) requests but received \(actual) within 5 seconds" }
    }
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stopped = false
    var count: Int { requests.count }
    func request(_ index: Int) -> URLRequest { requests[index] }
    func send(_ request: URLRequest, allowStateZero: Bool) async throws -> [String: Any] {
        guard !stopped else { throw CancellationError() }
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
    }
    func waitForCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        do {
            while requests.count < count {
                try Task.checkCancellation()
                guard Date() < deadline else { throw WaitTimeout(expected: count, actual: requests.count) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            stopped = true
            let outstanding = Array(pending.values)
            pending.removeAll()
            outstanding.forEach { $0.resume(throwing: CancellationError()) }
            throw error
        }
    }
    func finish(_ index: Int, response: [String: Any]) {
        pending.removeValue(forKey: index)?.resume(returning: response)
    }
}
