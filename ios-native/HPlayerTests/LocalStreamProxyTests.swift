import Darwin
import XCTest
@testable import HPlayer

final class LocalStreamProxyTests: XCTestCase {
    private func makeLoopbackListener() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 4), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    func testAcceptsReportsWhetherSomethingIsActuallyListening() throws {
        let listener = try makeLoopbackListener()
        XCTAssertTrue(LocalStreamProxy.accepts(port: listener.port))
        close(listener.descriptor)
        XCTAssertFalse(LocalStreamProxy.accepts(port: listener.port))
    }

    /// 系统收走监听端口、监听对象却还显示「就绪」时，下一次取地址要重建监听，而不是继续给出连不上的端口。
    func testRebuildsTheListenerWhenTheRecordedPortIsDead() async throws {
        let proxy = LocalStreamProxy()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.m3u8"))
        let firstResult = await proxy.localURL(for: upstream, headers: [:])
        let first = try XCTUnwrap(firstResult)
        let firstPort = try XCTUnwrap(first.port)
        XCTAssertTrue(LocalStreamProxy.accepts(port: UInt16(firstPort)))
        XCTAssertTrue(proxy.statusText.contains("端口"))

        proxy.simulateStalePortForTesting()
        XCTAssertTrue(proxy.statusText.contains("被拒绝"))

        let secondResult = await proxy.localURL(for: upstream, headers: [:])
        let second = try XCTUnwrap(secondResult)
        let secondPort = try XCTUnwrap(second.port)
        XCTAssertTrue(LocalStreamProxy.accepts(port: UInt16(secondPort)), "The rebuilt relay must accept connections")
        XCTAssertTrue(proxy.statusText.contains("端口"))
    }

    func testConcurrentOpensShareOneListener() async throws {
        let proxy = LocalStreamProxy()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        async let first = proxy.localURL(for: upstream, headers: ["User-Agent": "one"])
        async let second = proxy.localURL(for: upstream, headers: ["User-Agent": "two"])
        let results = await (first, second)
        let firstURL = try XCTUnwrap(results.0)
        let secondURL = try XCTUnwrap(results.1)
        XCTAssertEqual(firstURL.port, secondURL.port)
        XCTAssertNotEqual(firstURL.path, secondURL.path, "Each set of request headers needs its own profile")
        XCTAssertTrue(LocalStreamProxy.accepts(port: UInt16(try XCTUnwrap(firstURL.port))))
    }

    @MainActor
    func testCancellingDuringPortProbeReturnsWithoutWaitingForTheProbe() async throws {
        let proxy = LocalStreamProxy()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let initial = await proxy.localURL(for: upstream, headers: [:])
        XCTAssertNotNil(initial)

        let probeStarted = expectation(description: "port probe started")
        let releaseProbe = DispatchSemaphore(value: 0)
        proxy.setPortProbeForTesting { port in
            probeStarted.fulfill()
            _ = releaseProbe.wait(timeout: .now() + 3)
            return LocalStreamProxy.accepts(port: port)
        }
        defer { releaseProbe.signal() }
        let waiting = Task { await proxy.localURL(for: upstream, headers: [:]) }
        await fulfillment(of: [probeStarted], timeout: 1)
        let other = Task { await proxy.localURL(for: upstream, headers: [:]) }
        defer { waiting.cancel(); other.cancel() }
        for _ in 0..<100 {
            if proxy.listenerWaiterCountForTesting() == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(proxy.listenerWaiterCountForTesting(), 2)
        waiting.cancel()

        let completed = expectation(description: "cancelled open completed")
        Task {
            let value = await waiting.value
            XCTAssertNil(value)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        releaseProbe.signal()
        let otherResult = await other.value
        XCTAssertNotNil(otherResult, "Cancelling one open must not cancel another open sharing the listener")
    }

    // MARK: 上游出错：重试和续传

    private struct Fetched {
        var status = 0
        var head = ""
        var body = Data()
    }

    /// 像 mpv 一样直接向中转发一个 HTTP 请求，读到对方关闭连接为止（读不到数据 15 秒后放弃）。
    private func fetch(_ url: URL, range: String?) throws -> Fetched {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(try XCTUnwrap(url.port)).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var request = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "\r\n"
        let bytes = Array(request.utf8)
        XCTAssertEqual(send(descriptor, bytes, bytes.count, 0), bytes.count)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let capacity = buffer.count
        while true {
            let count = recv(descriptor, &buffer, capacity, 0)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        let separator = try XCTUnwrap(received.range(of: Data("\r\n\r\n".utf8)), "中转没有返回完整的响应头")
        let head = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return Fetched(status: status, head: head, body: Data(received[separator.upperBound...]))
    }

    private func relayURL(_ proxy: LocalStreamProxy, upstream: URL? = nil) async throws -> URL {
        let upstream = try upstream ?? XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let local = await proxy.localURL(for: upstream, headers: [:])
        return try XCTUnwrap(local)
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    /// 下载到一半被对方掐断：中转自己带上 Range 从断开的位置接着下，mpv 收到的是一条完整的响应。
    /// 用真正的 TCP 连接模拟（发一半就关 socket），走的是和线上一样的 URLSession 网络栈。
    func testResumesFromTheBreakPointWhenUpstreamDropsMidDownload() async throws {
        let total = 200_000
        let cut = 80_000
        let full = pattern(total)
        let server = try ScriptedHTTPServer([
            .send(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(cut))),
            .send(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes \(cut)-\(total - 1)/\(total)", "Content-Length": "\(total - cut)"], body: Data(full.suffix(total - cut))),
        ])
        defer { server.stop() }
        let proxy = LocalStreamProxy()
        proxy.setRetryDelaysForTesting([0.05, 0.05])

        let local = try await relayURL(proxy, upstream: server.url)
        let fetched = try fetch(local, range: "bytes=0-\(total - 1)")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        let detail = "head=\(fetched.head)\n上游收到的 Range：\(server.receivedRanges())\n\(history)"
        XCTAssertEqual(fetched.status, 206, detail)
        XCTAssertEqual(fetched.body.count, total, "断开前后的数据要接得上，不多不少；\(detail)")
        XCTAssertTrue(fetched.body == full, "长度对了，内容也要和原文件一样；\(detail)")
        XCTAssertEqual(server.receivedRanges(), ["bytes=0-\(total - 1)", "bytes=\(cut)-\(total - 1)"], detail)
        XCTAssertTrue(history.contains("从 \(cut) 字节接着下"), detail)
    }

    /// 连不上（对方拒绝连接）：等一会儿再试，不要马上给 mpv 一个 502
    func testRetriesWhenUpstreamRefusesTheConnection() async throws {
        let body = pattern(300)
        ScriptedUpstream.install([
            .fail(.cannotConnectToHost),
            .fail(.cannotConnectToHost),
            .reply(status: 200, headers: ["Content-Length": "300"], body: body),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRetryDelaysForTesting([0.05, 0.05, 0.05])

        let local = try await relayURL(proxy)
        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 200)
        XCTAssertEqual(fetched.body, body)
        XCTAssertEqual(ScriptedUpstream.receivedRanges().count, 3)
    }

    /// 一直连不上：重试用完才给 mpv 502，诊断里要有错误码（排查是被拒绝、不可达还是超时）
    func testGivesUpAfterTheRetriesAreUsedUpAndRecordsWhy() async throws {
        ScriptedUpstream.install([.fail(.cannotConnectToHost), .fail(.cannotConnectToHost), .fail(.cannotConnectToHost)])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRetryDelaysForTesting([0.02, 0.02])

        let local = try await relayURL(proxy)
        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 502)
        XCTAssertEqual(ScriptedUpstream.receivedRanges().count, 3, "第一次加两次重试")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertTrue(history.contains("NSURLErrorDomain -1004"), history)
        XCTAssertTrue(history.contains("重试 2 次都没成功"), history)
    }

    /// 115 偶尔返回 503/502：重试，不把错误页当成视频交给 mpv
    func testRetriesGatewayErrorsBeforeAnswering() async throws {
        ScriptedUpstream.install([
            .reply(status: 503, headers: [:], body: Data("busy".utf8)),
            .reply(status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8)),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRetryDelaysForTesting([0.05, 0.05])

        let local = try await relayURL(proxy)
        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 200)
        XCTAssertEqual(fetched.body, Data("hello".utf8))
    }

    /// 上游不肯从断开的位置接上（直接重发了整个文件）：不能把重复的数据拼进去，断开让 mpv 自己处理
    func testRefusesToSpliceWhenUpstreamCannotResumeAtTheBreakPoint() async throws {
        let total = 200_000
        let cut = 80_000
        let full = pattern(total)
        let server = try ScriptedHTTPServer([
            .send(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(cut))),
            .send(status: 200, headers: ["Content-Type": "video/mp4", "Content-Length": "\(total)"], body: full),
        ])
        defer { server.stop() }
        let proxy = LocalStreamProxy()
        proxy.setRetryDelaysForTesting([0.05])

        let local = try await relayURL(proxy, upstream: server.url)
        let fetched = try fetch(local, range: "bytes=0-\(total - 1)")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        let detail = "head=\(fetched.head)\n上游收到的 Range：\(server.receivedRanges())\n\(history)"
        XCTAssertEqual(fetched.body.count, cut, "只该有断开之前那 \(cut) 字节；\(detail)")
        XCTAssertTrue(fetched.body == Data(full.prefix(cut)), "收到的内容必须是断开之前的原样数据；\(detail)")
        XCTAssertTrue(history.contains("续传失败"), detail)
    }

    /// 115 的地址过期了（上游回 403）：中转用登记的办法换新地址重发，mpv 拿到的是正常的视频
    func testRenewsAnExpiredAddressBeforeAnswering() async throws {
        let fresh = try XCTUnwrap(URL(string: "https://example.com/b/fresh.mp4"))
        ScriptedUpstream.install([
            .reply(status: 403, headers: [:], body: Data("expired".utf8)),
            .reply(status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8)),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let calls = RenewCounter()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let relayed = await proxy.localURL(for: upstream, headers: [:], renew: { calls.increment(); return fresh })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: nil)
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertEqual(fetched.status, 200, history)
        XCTAssertEqual(fetched.body, Data("hello".utf8))
        XCTAssertEqual(ScriptedUpstream.receivedURLs(), [upstream, fresh])
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(history.contains("已换新地址"), history)
    }

    /// 换来的新地址马上也被拒：不是过期的问题，不反复换，照实告诉 mpv
    func testDoesNotLoopWhenTheFreshAddressIsAlsoRefused() async throws {
        let fresh = try XCTUnwrap(URL(string: "https://example.com/b/fresh.mp4"))
        ScriptedUpstream.install([
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8)),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let calls = RenewCounter()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let relayed = await proxy.localURL(for: upstream, headers: [:], renew: { calls.increment(); return fresh })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 403)
        XCTAssertEqual(ScriptedUpstream.receivedURLs().count, 2)
        XCTAssertEqual(calls.value, 1)
    }

    /// 看到一半地址过期：断开后续传被 403 拒绝，换新地址后从断开的字节接着下，内容拼起来和原文件一样
    func testResumesWithAFreshAddressWhenTheOldOneExpiresMidDownload() async throws {
        let total = 200_000
        let cut = 80_000
        let full = pattern(total)
        let server = try ScriptedHTTPServer([
            .send(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(cut))),
            .send(status: 403, headers: ["Content-Length": "0"], body: Data()),
            .send(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes \(cut)-\(total - 1)/\(total)", "Content-Length": "\(total - cut)"], body: Data(full.suffix(total - cut))),
        ])
        defer { server.stop() }
        let proxy = LocalStreamProxy()
        proxy.setRetryDelaysForTesting([0.05, 0.05])
        let fresh = try XCTUnwrap(URL(string: server.url.absoluteString + "?fresh=1"))
        let relayed = await proxy.localURL(for: server.url, headers: [:], renew: { fresh })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: "bytes=0-\(total - 1)")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        let detail = "head=\(fetched.head)\nRange：\(server.receivedRanges())\n路径：\(server.receivedTargets())\n\(history)"
        XCTAssertEqual(fetched.status, 206, detail)
        XCTAssertTrue(fetched.body == full, "换地址前后的内容要接得上；\(detail)")
        XCTAssertEqual(server.receivedRanges(), ["bytes=0-\(total - 1)", "bytes=\(cut)-\(total - 1)", "bytes=\(cut)-\(total - 1)"], detail)
        XCTAssertEqual(server.receivedTargets().last, "/a/video.mp4?fresh=1", detail)
    }
}

private final class RenewCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// 假的 115 服务器（不经过网络）：按顺序给每个请求一个剧本（连不上、返回状态码），并记下每次请求带的 Range。
private final class ScriptedUpstream: URLProtocol {
    enum Step {
        case fail(URLError.Code)
        case reply(status: Int, headers: [String: String], body: Data)
    }

    private static let lock = NSLock()
    private static var steps: [Step] = []
    private static var ranges: [String?] = []
    private static var urls: [URL] = []

    static func install(_ steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        self.steps = steps
        ranges = []
        urls = []
    }

    static func receivedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    static func receivedRanges() -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return ranges
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        if let url = request.url { Self.urls.append(url) }
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
        }
    }

    override func stopLoading() {}
}

/// 本机的假 115 服务器：真正的 TCP 连接，按剧本一次回应一个请求。
/// 响应内容比 Content-Length 声明的短，再关掉连接，就是「下载到一半被掐断」。
private final class ScriptedHTTPServer: @unchecked Sendable {
    enum Reply {
        case send(status: Int, headers: [String: String], body: Data)
    }

    private let listener: Int32
    private let port: UInt16
    private let lock = NSLock()
    private var replies: [Reply]
    private var ranges: [String?] = []
    private var targets: [String] = []
    private var stopped = false

    var url: URL { URL(string: "http://127.0.0.1:\(port)/a/video.mp4")! }

    init(_ replies: [Reply]) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        self.listener = descriptor
        self.port = UInt16(bigEndian: address.sin_port)
        self.replies = replies
        Thread.detachNewThread { [self] in serve() }
    }

    func receivedRanges() -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return ranges
    }

    /// 每次请求的路径（含查询串）
    func receivedTargets() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        defer { close(listener) }
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client >= 0 { handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, capacity, 0)
            if count <= 0 { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let range = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let target = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first?
            .split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.lock()
        ranges.append(range)
        targets.append(target)
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        guard let reply else { return }
        switch reply {
        case .send(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : status == 403 ? "Forbidden" : "OK")\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "Connection: close\r\n\r\n"
            let bytes = [UInt8](Data(head.utf8) + body)
            var offset = 0
            while offset < bytes.count {
                let sent = bytes.withUnsafeBytes { send(client, $0.baseAddress! + offset, bytes.count - offset, 0) }
                if sent <= 0 { return }
                offset += sent
            }
            // 响应头和一部分内容刚发出去、连接就紧跟着关掉的话，系统的网络层往往直接报「连接断了」，
            // 连已经收到的响应头都不交给 App。真实的断线是传了一阵子才发生的，所以短暂停一下再关，
            // 让中转先拿到响应头和前半段内容。
            let declared = headers["Content-Length"].flatMap { Int($0) } ?? body.count
            if body.count < declared { usleep(500_000) }
        }
    }
}
