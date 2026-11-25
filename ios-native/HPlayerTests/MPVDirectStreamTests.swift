import Foundation
import Libmpv
import QuartzCore
import XCTest
@testable import HPlayer

final class MPVDirectStreamTests: XCTestCase {
    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 13 + 7) % 251) })
    }

    private func readAll(from handle: Direct115StreamHandle, chunkBytes: Int = 4096) -> Data {
        var output = Data()
        var buffer = [CChar](repeating: 0, count: chunkBytes)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                handle.read(into: ptr.baseAddress!, maxBytes: chunkBytes)
            }
            if n <= 0 { break }
            output.append(Data(bytes: buffer, count: Int(n)))
        }
        return output
    }

    private func readExact(_ count: Int, from handle: Direct115StreamHandle) -> Data {
        var output = Data()
        var buffer = [CChar](repeating: 0, count: max(1, count))
        while output.count < count {
            let need = count - output.count
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                handle.read(into: ptr.baseAddress!, maxBytes: need)
            }
            if n <= 0 { break }
            output.append(Data(bytes: buffer, count: Int(n)))
        }
        return output
    }

    /// 基本流读/总长/分段拉取/EOF：16 MiB 分段（测试用 4000 B）无回环 TCP 直接喂给 mpv。
    func testDirectStreamReadsMultiChunkSizeAndSeekSeamlessly() throws {
        let total = 10_000
        let full = pattern(total)
        DirectStreamMockProtocol.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-3999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[0..<4000])),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 4000-7999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[4000..<8000])),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 8000-9999/\(total)",
                "Content-Length": "2000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[8000..<10000])),
        ])

        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        store.setChunkSizeForTesting(4_000)
        let stream = Direct115ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://cdn.115cdn.net/movie.mp4")),
            userAgent: Direct115Client.userAgent,
            cookie: "UID=1_test"
        )
        let uri = store.register(stream: stream, streamID: "p115:direct-basic")
        XCTAssertEqual(uri.scheme, Direct115StreamStore.scheme)
        XCTAssertTrue(uri.lastPathComponent.hasSuffix(".mp4"))

        let handle = try XCTUnwrap(store.openHandle(token: try XCTUnwrap(uri.host)))
        defer { handle.close() }

        XCTAssertEqual(handle.seek(to: 0), 0)
        XCTAssertEqual(handle.size(), Int64(total))
        let received = readAll(from: handle, chunkBytes: 2048)
        XCTAssertEqual(received, full)
        XCTAssertEqual(DirectStreamMockProtocol.receivedRanges(), ["bytes=0-3999", "bytes=4000-7999", "bytes=8000-9999"])
    }

    /// 随机跳转命中片头块缓存时零上游请求；缓冲区内小幅前跳同样零网络中断。
    func testDirectStreamServesCachedHeadAndInBufferSeekWithoutExtraRequests() throws {
        let total = 8_000
        let full = pattern(total)
        DirectStreamMockProtocol.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/x-matroska",
                "Content-Range": "bytes 0-7999/\(total)",
                "Content-Length": "\(total)",
                "Accept-Ranges": "bytes",
            ], body: full),
        ])

        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        store.setChunkSizeForTesting(16_000)
        let stream = Direct115ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://cdn.115cdn.net/test.mkv")),
            userAgent: Direct115Client.userAgent,
            cookie: "UID=1_test"
        )
        let uri = store.register(stream: stream, streamID: "p115:direct-seek")
        let handle = try XCTUnwrap(store.openHandle(token: try XCTUnwrap(uri.host)))
        defer { handle.close() }

        XCTAssertEqual(handle.size(), Int64(total))
        let firstPart = readExact(1000, from: handle)
        XCTAssertEqual(firstPart, Data(full[0..<1000]))

        // 缓冲区内前跳 2000 字节：零新请求
        XCTAssertEqual(handle.seek(to: 3000), 3000)
        let midPart = readExact(1000, from: handle)
        XCTAssertEqual(midPart, Data(full[3000..<4000]))

        // 回跳到片头：直接命中共享块缓存，零新请求
        XCTAssertEqual(handle.seek(to: 0), 0)
        let headAgain = readExact(512, from: handle)
        XCTAssertEqual(headAgain, Data(full[0..<512]))
        XCTAssertEqual(DirectStreamMockProtocol.receivedRanges().count, 1)
    }

    /// `cancel()` 从另一线程调用时必须立刻解除阻塞中的 `read()`，杜绝切集或 seek 死锁。
    func testCancelImmediatelyUnblocksPendingRead() throws {
        DirectStreamMockProtocol.install([
            .hold(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-99999/100000",
                "Content-Length": "100000",
                "Accept-Ranges": "bytes",
            ], body: Data()),
        ])
        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        store.setStallTimeoutForTesting(0)
        let stream = Direct115ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://cdn.115cdn.net/block.mp4")),
            userAgent: Direct115Client.userAgent,
            cookie: ""
        )
        let uri = store.register(stream: stream, streamID: "p115:cancel-test")
        let handle = try XCTUnwrap(store.openHandle(token: try XCTUnwrap(uri.host)))
        defer { handle.close() }

        let unblocked = expectation(description: "read unblocked by cancel")
        var readResult: Int64 = 999
        DispatchQueue.global().async {
            var buf = [CChar](repeating: 0, count: 1024)
            readResult = buf.withUnsafeMutableBufferPointer { handle.read(into: $0.baseAddress!, maxBytes: 1024) }
            unblocked.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            handle.cancel()
        }
        wait(for: [unblocked], timeout: 2.0)
        XCTAssertEqual(readResult, -1)
    }

    /// 403 续链时同时更新直链 URL 与新签发的 User-Agent / Cookie，并在同一条流内无缝从断点续传。
    func test403RenewalUpdatesURLAndBoundHeadersMidStream() throws {
        let total = 8_000
        let full = pattern(total)
        let oldURL = try XCTUnwrap(URL(string: "https://old.115cdn.net/video.mp4"))
        let newURL = try XCTUnwrap(URL(string: "https://new.115cdn.net/video.mp4"))
        DirectStreamMockProtocol.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-3999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[0..<4000])),
            // 下一段返回 403 -> 触发续链并携带新 UA 与新 Cookie
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 4000-7999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[4000..<8000])),
        ])

        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        store.setChunkSizeForTesting(4_000)
        store.setLookaheadTriggerRatioForTesting(0) // 禁用预取以精确验证主连接 403 续链
        let initial = Direct115ResolvedStream(url: oldURL, userAgent: Direct115Client.userAgent, cookie: "UID=old")
        let renewed = Direct115ResolvedStream(
            url: newURL,
            userAgent: Direct115Client.androidDownloadUserAgent,
            cookie: "UID=old; acw_tc=fresh"
        )
        let uri = store.register(stream: initial, streamID: "p115:renew-headers", renew: { renewed })
        let handle = try XCTUnwrap(store.openHandle(token: try XCTUnwrap(uri.host)))
        defer { handle.close() }

        let received = readAll(from: handle, chunkBytes: 4096)
        XCTAssertEqual(received, full)
        let requests = DirectStreamMockProtocol.receivedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.url, newURL)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "User-Agent"), Direct115Client.androidDownloadUserAgent)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Cookie"), "UID=old; acw_tc=fresh")
        XCTAssertEqual(store.currentUpstream(for: uri), renewed)
    }

    /// 进程内滑动预取遇到 403 时自动降级为单连接，不打断主数据读取。
    func testDirectStreamLookaheadDowngradesOn403() throws {
        let total = 12_000
        let full = pattern(total)
        DirectStreamMockProtocol.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-3999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[0..<4000])),
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 4000-7999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[4000..<8000])),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 8000-11999/\(total)",
                "Content-Length": "4000",
                "Accept-Ranges": "bytes",
            ], body: Data(full[8000..<12000])),
        ])

        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        store.setChunkSizeForTesting(4_000)
        store.setLookaheadTriggerRatioForTesting(0.5)
        let stream = Direct115ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://cdn.115cdn.net/la.mp4")),
            userAgent: Direct115Client.userAgent,
            cookie: ""
        )
        let uri = store.register(stream: stream, streamID: "p115:direct-la-403")
        let handle = try XCTUnwrap(store.openHandle(token: try XCTUnwrap(uri.host)))
        defer { handle.close() }

        let received = readAll(from: handle, chunkBytes: 4096)
        XCTAssertEqual(received, full)
        XCTAssertTrue(store.isLookaheadSuppressedForTesting(streamKey: "p115:direct-la-403"))
    }

    /// 真实 `MPVEngine` 可以在无图层状态预初始化（供 `MPVEnginePool` 预热）并成功注册 `hplayer115://` 协议，随后绑定 Metal 图层。
    @MainActor
    func testMPVEngineInitializesWithoutLayerForPoolAndRegistersDirectProtocol() throws {
        let options = PlaybackController.defaultEngineOptions(decoding: .hardware, cacheStorageMode: .memory)
        let engine = MPVEngine(options: options, layer: nil)
        XCTAssertNotNil(engine, "预热池需要在没有 CAMetalLayer 时初始化空闲 MPVEngine")
        let layer = MPVMetalLayer()
        engine?.attach(layer: layer)
        XCTAssertEqual(engine?.flag("idle-active"), true)
        engine?.destroy()
    }

    /// 端到端验证：真实 `MPVEngine` 通过 `mpv_stream_cb_add_ro` 打开 `hplayer115://` 地址，
    /// 真实触发 C 回调链路（open → seek(0) → size → read → close）读取上游字节流。
    @MainActor
    func testRealMPVEngineOpensHPlayer115ProtocolViaStreamCallback() async throws {
        let payload = pattern(16_384)
        DirectStreamMockProtocol.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-\(payload.count - 1)/\(payload.count)",
                "Content-Length": "\(payload.count)",
                "Accept-Ranges": "bytes",
            ], body: payload),
        ])
        let store = Direct115StreamStore(protocolClasses: [DirectStreamMockProtocol.self])
        let stream = Direct115ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://cdn.115cdn.net/e2e.mp4")),
            userAgent: Direct115Client.userAgent,
            cookie: "UID=e2e"
        )
        let uri = store.register(stream: stream, streamID: "p115:e2e-mpv")

        let engine = try XCTUnwrap(MPVEngine(
            options: [
                ("config", "no"),
                ("load-scripts", "no"),
                ("ytdl", "no"),
                ("idle", "yes"),
                ("vo", "null"),
                ("ao", "null"),
            ],
            layer: nil,
            directStreamStore: store
        ))
        defer { engine.destroy() }

        let endExp = expectation(description: "mpv finished probing hplayer115 stream")
        var fulfilled = false
        engine.onEvent = { event in
            if case .endFile = event, !fulfilled {
                fulfilled = true
                endExp.fulfill()
            }
        }
        _ = await engine.commandAsync(["loadfile", uri.absoluteString, "replace"])
        await fulfillment(of: [endExp], timeout: 5.0)

        let requests = DirectStreamMockProtocol.receivedRequests()
        XCTAssertGreaterThanOrEqual(requests.count, 1, "真实 libmpv 必须通过 hplayer115:// 回调触发至少一次上游 Range 读取")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://cdn.115cdn.net/e2e.mp4")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "UID=e2e")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "User-Agent"), Direct115Client.userAgent)
    }
}

private final class DirectStreamMockProtocol: URLProtocol {
    enum Step {
        case fail(URLError.Code)
        case reply(status: Int, headers: [String: String], body: Data)
        case hold(status: Int, headers: [String: String], body: Data)
    }

    private static let lock = NSLock()
    private static var steps: [Step] = []
    private static var requests: [URLRequest] = []

    static func install(_ steps: [Step]) {
        lock.lock()
        defer { lock.unlock() }
        self.steps = steps
        self.requests = []
    }

    static func receivedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func receivedRanges() -> [String?] {
        receivedRequests().map { $0.value(forHTTPHeaderField: "Range") }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let step: Step? = Self.steps.isEmpty ? nil : Self.steps.removeFirst()
        Self.lock.unlock()

        guard let step else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .reply(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .hold(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        }
    }

    override func stopLoading() {}
}
