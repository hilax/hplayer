import XCTest
@testable import HPlayer

@MainActor
final class Direct115OpenSessionTests: XCTestCase {
    func testOlderDeviceCodeCannotReplaceANewerRequest() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let older = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(1)
        let newer = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(2)
        await f.network.finish(1, response: code("new"))
        _ = try await newer.value
        await f.network.finish(0, response: code("old"))
        do { _ = try await older.value; XCTFail("The old QR must be rejected") } catch { }
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        await f.network.waitForCount(3)
        let url = await f.network.request(2).url!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uid" })?.value, "new")
        await f.network.finish(2, response: ["state": true, "data": ["status": 0]])
        _ = try await poll.value
    }

    func testLateExpiredPollCannotClearANewerQRCode() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let first = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(1)
        await f.network.finish(0, response: code("old")); _ = try await first.value
        let oldPoll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        await f.network.waitForCount(2)
        let newer = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(3)
        await f.network.finish(2, response: code("new")); _ = try await newer.value
        await f.network.finish(1, response: ["state": false])
        do { _ = try await oldPoll.value; XCTFail("The old poll must be rejected") } catch { }
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        await f.network.waitForCount(4)
        let url = await f.network.request(3).url!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uid" })?.value, "new")
        await f.network.finish(3, response: ["state": true, "data": ["status": 0]])
        _ = try await poll.value
    }

    func testChangingAppIDInvalidatesAnInFlightDeviceCode() async throws {
        let f = fixture(); defer { f.cleanUp() }
        let start = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(1)
        _ = try await f.client.route(path: "/api/115/open/config", method: "POST", body: try JSONEncoder().encode(["clientId": "app-b"]))
        await f.network.finish(0, response: code("old"))
        do { _ = try await start.value; XCTFail("An old AppID must not supply the current QR") } catch { }
        let data = try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "expired")
    }

    func testUnauthorizedWriteCannotReplayUnderANewlyAuthorizedAccount() async throws {
        let f = fixture(); defer { f.cleanUp() }
        saveTokens(access: "account-a", refresh: "refresh-a", key: f.tokenKey)
        let write = Task { try await f.client.route(path: "/api/115/torrent/tasks", method: "POST", body: taskBody()) }
        await f.network.waitForCount(1)
        let start = Task { try await f.client.route(path: "/api/115/open/auth/start", method: "POST", body: nil) }
        await f.network.waitForCount(2)
        await f.network.finish(1, response: code("account-b")); _ = try await start.value
        let poll = Task { try await f.client.route(path: "/api/115/open/auth/poll", method: "POST", body: nil) }
        await f.network.waitForCount(3)
        await f.network.finish(2, response: ["state": true, "data": ["status": 2]])
        await f.network.waitForCount(4)
        await f.network.finish(3, response: tokens(access: "account-b", refresh: "refresh-b"))
        _ = try await poll.value
        await f.network.finish(0, response: ["state": false, "code": 40140125])
        do { _ = try await write.value; XCTFail("An old write must not be sent with the new account") } catch { }
        let count = await f.network.count
        XCTAssertEqual(count, 4)
        XCTAssertTrue(Keychain.load(f.tokenKey)?.contains("account-b") == true)
    }

    func testExpiredTokenRefreshStillRetriesWithinTheSameAuthorization() async throws {
        let f = fixture(); defer { f.cleanUp() }
        saveTokens(access: "old-access", refresh: "old-refresh", key: f.tokenKey)
        let write = Task { try await f.client.route(path: "/api/115/torrent/tasks", method: "POST", body: taskBody()) }
        await f.network.waitForCount(1)
        await f.network.finish(0, response: ["state": false, "code": 40140125])
        await f.network.waitForCount(2)
        let refreshURL = await f.network.request(1).url?.path
        XCTAssertEqual(refreshURL, "/open/refreshToken")
        await f.network.finish(1, response: tokens(access: "new-access", refresh: "new-refresh"))
        await f.network.waitForCount(3)
        let bearer = await f.network.request(2).value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(bearer, "Bearer new-access")
        await f.network.finish(2, response: ["state": true])
        _ = try await write.value
        XCTAssertTrue(Keychain.load(f.tokenKey)?.contains("new-refresh") == true)
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
    private func saveTokens(access: String, refresh: String, key: String) {
        let value: [String: Any] = ["access": access, "refresh": refresh, "expiresAt": Date().addingTimeInterval(7200).timeIntervalSinceReferenceDate]
        let data = try! JSONSerialization.data(withJSONObject: value)
        Keychain.save(String(data: data, encoding: .utf8)!, for: key)
    }
    private func fixture() -> OpenSessionFixture {
        let suffix = UUID().uuidString
        let clientKey = "test.open.client.\(suffix)", tokenKey = "test.open.tokens.\(suffix)"
        Keychain.save("app-a", for: clientKey)
        let network = OpenSessionNetwork()
        return OpenSessionFixture(client: Direct115Open(clientKey: clientKey, tokenKey: tokenKey, transport: network.send), network: network, clientKey: clientKey, tokenKey: tokenKey)
    }
}

private struct OpenSessionFixture {
    let client: Direct115Open
    let network: OpenSessionNetwork
    let clientKey: String
    let tokenKey: String
    func cleanUp() { Keychain.delete(clientKey); Keychain.delete(tokenKey) }
}

private actor OpenSessionNetwork {
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }
    func request(_ index: Int) -> URLRequest { requests[index] }
    func send(_ request: URLRequest, allowStateZero: Bool) async throws -> [String: Any] {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiting.filter { requests.count >= $0.0 }
            waiting.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func finish(_ index: Int, response: [String: Any]) {
        pending.removeValue(forKey: index)?.resume(returning: response)
    }
}
