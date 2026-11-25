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

    /// 换来的新地址马上也被拒：不是过期的问题（多半是同一个文件的连接太多），不反复换地址，
    /// 等一会儿用同一个新地址再试；等待次数用完才照实告诉 mpv
    func testWaitsInsteadOfRenewingAgainWhenTheFreshAddressIsAlsoRefused() async throws {
        let fresh = try XCTUnwrap(URL(string: "https://example.com/b/fresh.mp4"))
        ScriptedUpstream.install(Array(repeating: .reply(status: 403, headers: [:], body: Data()), count: 6))
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRefusalDelaysForTesting([0.05, 0.05])
        let calls = RenewCounter()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let relayed = await proxy.localURL(for: upstream, headers: [:], renew: { calls.increment(); return fresh })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 403)
        XCTAssertEqual(ScriptedUpstream.receivedURLs(), [upstream, fresh, fresh, fresh])
        XCTAssertEqual(calls.value, 1)
    }

    /// 新地址第一次被拒、等一会儿再试就通了（115 那边旧连接刚断开）：mpv 拿到正常的视频
    func testFreshAddressSucceedsAfterAShortWait() async throws {
        let fresh = try XCTUnwrap(URL(string: "https://example.com/b/fresh.mp4"))
        ScriptedUpstream.install([
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8)),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRefusalDelaysForTesting([0.05, 0.05])
        let calls = RenewCounter()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let relayed = await proxy.localURL(for: upstream, headers: [:], renew: { calls.increment(); return fresh })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: nil)
        XCTAssertEqual(fetched.status, 200, proxy.problemHistoryLines.joined(separator: "\n"))
        XCTAssertEqual(fetched.body, Data("hello".utf8))
        XCTAssertEqual(ScriptedUpstream.receivedURLs(), [upstream, fresh, fresh])
        XCTAssertEqual(calls.value, 1)
    }

    /// mpv 跳转：旧连接还开着就开新连接。中转先停掉旧连接的下载（115 同一个文件同时只认一两条），
    /// 新连接正常拿到内容；新连接结束后旧连接还没关，就从停下的位置接着下，内容拼起来和原文件一样。
    func testSeekingPausesTheOlderDownloadOfTheSameVideoAndResumesItLater() async throws {
        let total = 4000
        let full = pattern(total)
        ScriptedUpstream.install([
            // 带上 Content-Type：没有的话系统要先攒够一段内容猜类型，响应头迟迟不交给中转
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(1000))),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 2500-\(total - 1)/\(total)", "Content-Length": "\(total - 2500)"], body: Data(full.suffix(total - 2500))),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 1000-\(total - 1)/\(total)", "Content-Length": "\(total - 1000)"], body: Data(full.suffix(total - 1000))),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.mp4"))
        let relayed = await proxy.localURL(for: upstream, headers: [:], renew: { upstream })
        let local = try XCTUnwrap(relayed)

        // 旧连接：收到响应头和前 1000 字节，连接一直开着
        let older = try openStream(local, range: "bytes=0-\(total - 1)")
        defer { close(older) }
        var first = try readUntil(older, bodyBytes: 1000)

        // 新连接（跳转）
        let seeked = try fetch(local, range: "bytes=2500-\(total - 1)")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertEqual(seeked.status, 206, history)
        XCTAssertTrue(seeked.body == full.suffix(total - 2500), history)

        // 新连接结束：旧连接从 1000 字节接着下完
        first.append(try readToEnd(older))
        let body = try XCTUnwrap(first.range(of: Data("\r\n\r\n".utf8)).map { first[$0.upperBound...] })
        XCTAssertTrue(Data(body) == full, "旧连接接上后内容完整；\(proxy.problemHistoryLines.joined(separator: "\n"))")
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-\(total - 1)", "bytes=2500-\(total - 1)", "bytes=1000-\(total - 1)"])
        XCTAssertEqual(ScriptedUpstream.stoppedCount, 1, "The older download is stopped when the seek opens a new one")
    }

    private func openStream(_ url: URL, range: String) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
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
        let bytes = Array("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: \(range)\r\n\r\n".utf8)
        XCTAssertEqual(send(descriptor, bytes, bytes.count, 0), bytes.count)
        return descriptor
    }

    /// 读到响应头加上 `bodyBytes` 字节的内容为止
    private func readUntil(_ descriptor: Int32, bodyBytes: Int) throws -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let capacity = buffer.count
        while true {
            if let end = received.range(of: Data("\r\n\r\n".utf8)), received.count - end.upperBound >= bodyBytes {
                return received
            }
            let count = recv(descriptor, &buffer, capacity, 0)
            guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
            received.append(contentsOf: buffer[0..<count])
        }
    }

    private func readToEnd(_ descriptor: Int32) throws -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let capacity = buffer.count
        while true {
            let count = recv(descriptor, &buffer, capacity, 0)
            if count == 0 { return received }
            guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
            received.append(contentsOf: buffer[0..<count])
        }
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

    /// 上游连上后发了一半就永久假死：停滞看门狗在设定超时内主动掐断，并在同一个响应流里从断点续传。
    func testAbortsStalledUpstreamAndSplicesFromBreakPoint() async throws {
        let total = 10_000
        let cut = 3_000
        let full = pattern(total)
        ScriptedUpstream.install([
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(cut))),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes \(cut)-\(total - 1)/\(total)", "Content-Length": "\(total - cut)"], body: Data(full.suffix(total - cut))),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setRetryDelaysForTesting([0.05])
        proxy.setStallTimeoutForTesting(0.15, minSpeed: 0)

        let local = try await relayURL(proxy)
        let fetched = try fetch(local, range: "bytes=0-\(total - 1)")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertEqual(fetched.status, 206, history)
        XCTAssertTrue(fetched.body == full, history)
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-\(total - 1)", "bytes=\(cut)-\(total - 1)"], history)
        XCTAssertEqual(ScriptedUpstream.stoppedCount, 1)
        XCTAssertTrue(history.contains("无响应"), history)
    }

    /// 开放式 Range 请求会按分段大小逐段向 115 拉取并无感拼接成同一条响应返回给 mpv。
    func testSplitsOpenEndedRequestIntoBoundedChunksSeamlessly() async throws {
        let total = 10_000
        let full = pattern(total)
        ScriptedUpstream.install([
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3999/\(total)", "Content-Length": "4000"], body: Data(full[0..<4000])),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 4000-7999/\(total)", "Content-Length": "4000"], body: Data(full[4000..<8000])),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 8000-9999/\(total)", "Content-Length": "2000"], body: Data(full[8000..<10000])),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setChunkSizeForTesting(4_000)

        let local = try await relayURL(proxy)
        let fetched = try fetch(local, range: "bytes=0-")
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertEqual(fetched.status, 206, history)
        XCTAssertTrue(fetched.head.contains("Content-Length: 10000"), fetched.head)
        XCTAssertTrue(fetched.head.contains("Content-Range: bytes 0-9999/10000"), fetched.head)
        XCTAssertTrue(fetched.body == full)
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-3999", "bytes=4000-7999", "bytes=8000-9999"])
    }

    /// 头尾与热点缓存：重复探测（或小幅回跳）直接命中内存缓存，部分命中只向 115 拉取缺失后缀。
    func testServesCachedHeadAndHotBlocksWithoutTouchingUpstream() async throws {
        let total = 8_000
        let full = pattern(total)
        ScriptedUpstream.install([
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3999/\(total)", "Content-Length": "4000", "Accept-Ranges": "bytes"], body: Data(full[0..<4000])),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 4000-7999/\(total)", "Content-Length": "4000", "Accept-Ranges": "bytes"], body: Data(full[4000..<8000])),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setChunkSizeForTesting(100_000)

        let local = try await relayURL(proxy)
        let first = try fetch(local, range: "bytes=0-3999")
        XCTAssertEqual(first.status, 206)
        XCTAssertEqual(first.body, Data(full[0..<4000]))
        XCTAssertEqual(proxy.cachedByteCountForTesting(), 4_000)

        // 完全命中缓存：零上游请求
        let headHit = try fetch(local, range: "bytes=0-1999")
        XCTAssertEqual(headHit.status, 206)
        XCTAssertEqual(headHit.body, Data(full[0..<2000]))
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-3999"])

        // 前半段命中缓存 + 后半段接力拉取：上游只收到 4000-7999
        let partialHit = try fetch(local, range: "bytes=2000-7999")
        XCTAssertEqual(partialHit.status, 206)
        XCTAssertEqual(partialHit.body, Data(full[2000..<8000]))
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-3999", "bytes=4000-7999"])
    }

    /// 使用统一 streamID 时，换用全新 115 URL 重开同一视频仍会立即抢占旧连接，避免并发 403。
    func testStreamIDPreemptsOlderURLWhenAddressChanges() async throws {
        let total = 4_000
        let full = pattern(total)
        let url1 = try XCTUnwrap(URL(string: "https://cdn1.example.com/file.mp4?t=1"))
        let url2 = try XCTUnwrap(URL(string: "https://cdn2.example.com/file.mp4?t=2"))
        ScriptedUpstream.install([
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(500))),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 1000-\(total - 1)/\(total)", "Content-Length": "\(total - 1000)"], body: Data(full.suffix(total - 1000))),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let relayed1 = await proxy.localURL(for: url1, headers: [:], streamID: "p115:pick123", renew: { url1 })
        let local1 = try XCTUnwrap(relayed1)
        let older = try openStream(local1, range: "bytes=0-\(total - 1)")
        defer { close(older) }
        _ = try readUntil(older, bodyBytes: 500)

        let relayed2 = await proxy.localURL(for: url2, headers: [:], streamID: "p115:pick123", renew: { url2 })
        let local2 = try XCTUnwrap(relayed2)
        let fetched = try fetch(local2, range: "bytes=1000-\(total - 1)")
        XCTAssertEqual(fetched.status, 206)
        XCTAssertTrue(fetched.body == full.suffix(total - 1000))
        XCTAssertEqual(ScriptedUpstream.stoppedCount, 1, "同一 pickCode 用新地址重开时，旧连接必须被立刻掐断让位")
    }

    /// Tier-1 静默切换：上层检测到卡顿调用 refreshActiveUpstream，中转在不断开 mpv 响应流的情况下换新地址断点续传。
    func testRefreshActiveUpstreamSwitchesStalledNodeWithoutClosingClient() async throws {
        let total = 4_000
        let cut = 1_200
        let full = pattern(total)
        let url1 = try XCTUnwrap(URL(string: "https://cdn1.example.com/a.mp4"))
        let url2 = try XCTUnwrap(URL(string: "https://cdn2.example.com/a.mp4"))
        ScriptedUpstream.install([
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(cut))),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes \(cut)-\(total - 1)/\(total)", "Content-Length": "\(total - cut)"], body: Data(full.suffix(total - cut))),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let calls = RenewCounter()
        let relayed = await proxy.localURL(for: url1, headers: [:], streamID: "p115:tier1", renew: { calls.increment(); return url2 })
        let local = try XCTUnwrap(relayed)

        let client = try openStream(local, range: "bytes=0-\(total - 1)")
        defer { close(client) }
        var received = try readUntil(client, bodyBytes: cut)

        XCTAssertTrue(proxy.refreshActiveUpstream(for: local))
        received.append(try readToEnd(client))
        let body = try XCTUnwrap(received.range(of: Data("\r\n\r\n".utf8)).map { received[$0.upperBound...] })
        XCTAssertTrue(Data(body) == full, proxy.problemHistoryLines.joined(separator: "\n"))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(ScriptedUpstream.receivedURLs(), [url1, url2])
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-\(total - 1)", "bytes=\(cut)-\(total - 1)"])
    }

    func testAddressRefreshWaitsWithinDeadlineAndYieldsToLatestRange() async throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/original.mp4"))
        let fresh = try XCTUnwrap(URL(string: "https://example.com/refreshed.mp4"))
        let full = pattern(5000)
        let (addresses, releaseAddress) = AsyncStream<URL>.makeStream()
        defer { releaseAddress.finish() }
        let refreshing = expectation(description: "address refresh started")
        ScriptedUpstream.install([
            .reply(status: 403, headers: [:], body: Data()),
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 2000-4999/5000", "Content-Length": "3000"], body: Data(full[2000..<2500])),
            .reply(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-4999/5000", "Content-Length": "5000"], body: full),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        proxy.setStallTimeoutForTesting(0)
        let relayed = await proxy.localURL(for: original, headers: [:], streamID: "p115:seek", renew: {
            refreshing.fulfill()
            return await addresses.first(where: { _ in true }) ?? fresh
        })
        let local = try XCTUnwrap(relayed)
        let older = try openStream(local, range: "bytes=0-4999")
        defer { close(older) }
        await fulfillment(of: [refreshing], timeout: 2)
        XCTAssertTrue(proxy.isRecovering(for: local))
        XCTAssertFalse(proxy.isRecovering(for: local, at: ProcessInfo.processInfo.systemUptime + 10))

        let newer = try openStream(local, range: "bytes=2000-4999")
        defer { close(newer) }
        _ = try readUntil(newer, bodyBytes: 500)
        XCTAssertFalse(proxy.isRecovering(for: local), "A superseded Range must not delay recovery for the latest seek")
        releaseAddress.yield(fresh)
        releaseAddress.finish()
        for _ in 0..<100 {
            if proxy.problemHistoryLines.contains(where: { $0.contains("已换新地址") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ScriptedUpstream.receivedRanges(), ["bytes=0-4999", "bytes=2000-4999"])
        XCTAssertFalse(proxy.problemHistoryLines.contains { $0.contains("旧连接先停在 2500 字节") })

        shutdown(newer, SHUT_RDWR)
        let response = try readToEnd(older)
        XCTAssertEqual(Data(response.suffix(full.count)), full)
        XCTAssertEqual(ScriptedUpstream.receivedURLs(), [original, original, fresh])
    }

    /// m3u8 转码播放期间分片（.ts）返回 403：重拉最新 m3u8 列表，匹配同一分片的新签名地址重下，不能把 m3u8 文本塞给 .ts 请求。
    func testRefreshesM3U8PlaylistSegmentsWhenSegmentReturns403() async throws {
        let master1 = try XCTUnwrap(URL(string: "https://v.115.com/master1.m3u8"))
        let master2 = try XCTUnwrap(URL(string: "https://v.115.com/master2.m3u8"))
        let m3u8Body1 = "#EXTM3U\n#EXTINF:5.0,\nhttps://cdn.example.com/seg0.ts?sign=old\n"
        let m3u8Body2 = "#EXTM3U\n#EXTINF:5.0,\nhttps://cdn.example.com/seg0.ts?sign=fresh\n"
        let tsPayload = Data("TS-FRESH-SEGMENT-DATA".utf8)
        ScriptedUpstream.install([
            .reply(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(m3u8Body1.utf8)),
            .reply(status: 403, headers: [:], body: Data()),
            .reply(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(m3u8Body2.utf8)),
            .reply(status: 200, headers: ["Content-Type": "video/mp2t", "Content-Length": "\(tsPayload.count)"], body: tsPayload),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let relayed = await proxy.localURL(for: master1, headers: [:], streamID: "p115:hls", playlistRenew: { master2 })
        let local = try XCTUnwrap(relayed)

        let playlist = try fetch(local, range: nil)
        XCTAssertEqual(playlist.status, 200)
        let playlistText = String(decoding: playlist.body, as: UTF8.self)
        let segURLString = try XCTUnwrap(playlistText.components(separatedBy: "\n").first { $0.contains("seg0.ts") })
        let segURL = try XCTUnwrap(URL(string: segURLString))

        let segment = try fetch(segURL, range: nil)
        XCTAssertEqual(segment.status, 200, proxy.problemHistoryLines.joined(separator: "\n"))
        XCTAssertEqual(segment.body, tsPayload)
        XCTAssertEqual(ScriptedUpstream.receivedURLs().last?.absoluteString, "https://cdn.example.com/seg0.ts?sign=fresh")
    }

    /// 跨域名 302 跳转（离开 .115.com 到外部 CDN）时，中转的 URLSession 代理必须剥离 Cookie，且拒绝 HTTPS 降级到 HTTP。
    func testRedirectGuardStripsCookieOff115Domains() throws {
        let proxy = LocalStreamProxy()
        let dummySession = URLSession(configuration: .ephemeral)
        let task = dummySession.dataTask(with: URL(string: "https://cdn.115.com/video.mp4")!)
        let redirectReply = HTTPURLResponse(url: URL(string: "https://cdn.115.com/video.mp4")!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!

        // 跳转到外部 CDN：剥离 Cookie
        var offDomainReq = URLRequest(url: URL(string: "https://oss-cdn.example.com/video.mp4")!)
        offDomainReq.setValue("UID=secret", forHTTPHeaderField: "Cookie")
        offDomainReq.setValue("bytes=0-100", forHTTPHeaderField: "Range")
        var acceptedOffDomain: URLRequest?
        let exp1 = expectation(description: "off-domain redirect")
        proxy.urlSession(dummySession, task: task, willPerformHTTPRedirection: redirectReply, newRequest: offDomainReq) { req in
            acceptedOffDomain = req
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1)
        XCTAssertNil(acceptedOffDomain?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(acceptedOffDomain?.value(forHTTPHeaderField: "Range"), "bytes=0-100")

        // 跳转到 *.115.com：保留 Cookie
        var in115Req = URLRequest(url: URL(string: "https://vip.115.com/video.mp4")!)
        in115Req.setValue("UID=secret", forHTTPHeaderField: "Cookie")
        var acceptedIn115: URLRequest?
        let exp2 = expectation(description: "in-115 redirect")
        proxy.urlSession(dummySession, task: task, willPerformHTTPRedirection: redirectReply, newRequest: in115Req) { req in
            acceptedIn115 = req
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1)
        XCTAssertEqual(acceptedIn115?.value(forHTTPHeaderField: "Cookie"), "UID=secret")

        // 跳转到 *.115cdn.net：保留 Cookie
        var cdn115Req = URLRequest(url: URL(string: "https://node01.115cdn.net/video.mp4")!)
        cdn115Req.setValue("UID=secret", forHTTPHeaderField: "Cookie")
        var acceptedCDN115: URLRequest?
        let expCDN = expectation(description: "115cdn redirect")
        proxy.urlSession(dummySession, task: task, willPerformHTTPRedirection: redirectReply, newRequest: cdn115Req) { req in
            acceptedCDN115 = req
            expCDN.fulfill()
        }
        wait(for: [expCDN], timeout: 1)
        XCTAssertEqual(acceptedCDN115?.value(forHTTPHeaderField: "Cookie"), "UID=secret")

        // HTTPS -> HTTP 降级跳转：拒绝
        let downgradeReq = URLRequest(url: URL(string: "http://cdn.115.com/video.mp4")!)
        var acceptedDowngrade: URLRequest? = downgradeReq
        let exp3 = expectation(description: "downgrade blocked")
        proxy.urlSession(dummySession, task: task, willPerformHTTPRedirection: redirectReply, newRequest: downgradeReq) { req in
            acceptedDowngrade = req
            exp3.fulfill()
        }
        wait(for: [exp3], timeout: 1)
        XCTAssertNil(acceptedDowngrade)
    }

    /// 302 重定向到 CDN 节点后，若该节点被 403 拒绝，冷却判断必须仍以未重定向的直链地址为准，
    /// 不得因 `current != redirectedURL` 绕过冷却导致反复调用换链接口或死循环。
    func testRedirectedFreshAddressStillRespectsRenewalCooldown() async throws {
        let server = try ScriptedHTTPServer([
            // 1. 首次请求旧地址 -> 403，触发 renew 拿到 fresh
            .send(status: 403, headers: ["Content-Length": "0"], body: Data()),
            // 2. 请求 fresh -> 302 跳转到 /cdn/node1.mp4
            .send(status: 302, headers: ["Location": "/cdn/node1.mp4", "Content-Length": "0"], body: Data()),
            // 3. /cdn/node1.mp4 -> 403（命中冷却，按 refusalDelays 等待后重试 fresh，不再次调用 renew）
            .send(status: 403, headers: ["Content-Length": "0"], body: Data()),
            // 4. 退避后重试 fresh -> 302 跳转到 /cdn/node2.mp4
            .send(status: 302, headers: ["Location": "/cdn/node2.mp4", "Content-Length": "0"], body: Data()),
            // 5. /cdn/node2.mp4 -> 200 成功返回
            .send(status: 200, headers: ["Content-Type": "video/mp4", "Content-Length": "5"], body: Data("hello".utf8)),
        ])
        defer { server.stop() }

        let proxy = LocalStreamProxy()
        proxy.setRefusalDelaysForTesting([0.05, 0.05])
        let calls = RenewCounter()
        let fresh = try XCTUnwrap(URL(string: server.url.absoluteString + "?fresh=1"))
        let relayed = await proxy.localURL(for: server.url, headers: [:], streamID: "p115:redirect-test", renew: {
            calls.increment()
            return fresh
        })
        let local = try XCTUnwrap(relayed)

        let fetched = try fetch(local, range: nil)
        let history = proxy.problemHistoryLines.joined(separator: "\n")
        XCTAssertEqual(fetched.status, 200, history)
        XCTAssertEqual(fetched.body, Data("hello".utf8))
        XCTAssertEqual(calls.value, 1, "302 重定向后的 403 必须受换链冷却保护，只换一次地址；\(history)")
        XCTAssertEqual(server.receivedTargets(), [
            "/a/video.mp4",
            "/a/video.mp4?fresh=1",
            "/cdn/node1.mp4",
            "/a/video.mp4?fresh=1",
            "/cdn/node2.mp4",
        ])
    }

    /// 代理层近期正在高速接收字节时，应向看门狗报告流处于健康状态，避免误触切换节点。
    func testStreamHealthyOrRecoveringReflectsActiveTransfer() async throws {
        let total = 200_000
        let initialChunk = 65_536
        let full = pattern(total)
        ScriptedUpstream.install([
            .hold(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-\(total - 1)/\(total)", "Content-Length": "\(total)"], body: Data(full.prefix(initialChunk))),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/healthy.mp4"))
        let localURL = await proxy.localURL(for: upstream, headers: [:], streamID: "p115:healthy")
        let local = try XCTUnwrap(localURL)

        XCTAssertFalse(proxy.isStreamHealthyOrRecovering(for: local))
        let client = try openStream(local, range: "bytes=0-\(total - 1)")
        defer { close(client) }
        _ = try readUntil(client, bodyBytes: initialChunk)

        XCTAssertTrue(proxy.isStreamHealthyOrRecovering(for: local), "刚收到 64 KiB 有效数据时代理层应报告为健康")
    }

    private func mp4Box(type: String, size: Int64, extended: Bool = false) -> Data {
        var data = Data()
        if extended {
            var s1 = UInt32(1).bigEndian
            data.append(Data(bytes: &s1, count: 4))
            data.append(Data(type.utf8))
            var s64 = UInt64(size).bigEndian
            data.append(Data(bytes: &s64, count: 8))
        } else {
            var s32 = UInt32(size).bigEndian
            data.append(Data(bytes: &s32, count: 4))
            data.append(Data(type.utf8))
        }
        return data
    }

    func testMP4MoovProbeDetectsHeadAndTailMoov() {
        var faststart = mp4Box(type: "ftyp", size: 24)
        faststart.append(Data(repeating: 0, count: 16))
        faststart.append(mp4Box(type: "moov", size: 2048))
        XCTAssertEqual(MP4MoovProbe.inspect(prefix: faststart, totalSize: 10_000_000), .moovAtHead)

        var tailStandard = mp4Box(type: "ftyp", size: 24)
        tailStandard.append(Data(repeating: 0, count: 16))
        tailStandard.append(mp4Box(type: "mdat", size: 8_000_000))
        tailStandard.append(Data(repeating: 0, count: 64))
        XCTAssertEqual(
            MP4MoovProbe.inspect(prefix: tailStandard, totalSize: 8_500_024),
            .moovAtTail(start: 8_000_024, end: 8_500_023)
        )

        var tailLarge64 = mp4Box(type: "ftyp", size: 24)
        tailLarge64.append(Data(repeating: 0, count: 16))
        let largeMdatSize: Int64 = 5_000_000_000
        tailLarge64.append(mp4Box(type: "mdat", size: largeMdatSize, extended: true))
        tailLarge64.append(Data(repeating: 0, count: 64))
        XCTAssertEqual(
            MP4MoovProbe.inspect(prefix: tailLarge64, totalSize: largeMdatSize + 24 + 1_500_000),
            .moovAtTail(start: largeMdatSize + 24, end: largeMdatSize + 24 + 1_500_000 - 1)
        )

        XCTAssertEqual(MP4MoovProbe.inspect(prefix: Data(repeating: 0xAA, count: 128), totalSize: 10_000), .undetermined)
    }

    /// 预热检测到 MP4 的 moov 在文件尾部时，会自动拉取片头和尾部 moov 写入缓存，mpv 随后读取两段均为零上游请求。
    func testPrewarmPopulatesHeadAndTailMoovForInstantCacheHits() async throws {
        let total = 400_000
        let mdatStart = 24
        let mdatSize = 350_000
        let moovStart = mdatStart + mdatSize
        let moovSize = total - moovStart
        var full = Data()
        full.append(mp4Box(type: "ftyp", size: Int64(mdatStart)))
        full.append(Data(repeating: 0x11, count: mdatStart - 8))
        full.append(mp4Box(type: "mdat", size: Int64(mdatSize)))
        full.append(pattern(mdatSize - 8))
        full.append(mp4Box(type: "moov", size: Int64(moovSize)))
        full.append(pattern(moovSize - 8))
        XCTAssertEqual(full.count, total)

        let headEnd = min(total - 1, 256 * 1024 - 1)
        ScriptedUpstream.install([
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-\(headEnd)/\(total)",
                "Content-Length": "\(headEnd + 1)",
                "Accept-Ranges": "bytes",
            ], body: Data(full[0...headEnd])),
            .reply(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes \(moovStart)-\(total - 1)/\(total)",
                "Content-Length": "\(moovSize)",
                "Accept-Ranges": "bytes",
            ], body: Data(full[moovStart..<total])),
        ])
        let proxy = LocalStreamProxy(protocolClasses: [ScriptedUpstream.self])
        let upstream = try XCTUnwrap(URL(string: "https://cdn.example.com/movie.mp4"))
        proxy.prewarm(url: upstream, headers: [:], streamID: "p115:prewarm-moov", resume: true)

        for _ in 0..<100 {
            if ScriptedUpstream.receivedRanges().count >= 2 && proxy.cachedByteCountForTesting() >= moovSize + 65_536 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ScriptedUpstream.receivedRanges().count, 2)
        XCTAssertEqual(ScriptedUpstream.receivedRanges().last, "bytes=\(moovStart)-\(total - 1)")

        let relayed = await proxy.localURL(for: upstream, headers: [:], streamID: "p115:prewarm-moov")
        let local = try XCTUnwrap(relayed)
        let headResp = try fetch(local, range: "bytes=0-1023")
        XCTAssertEqual(headResp.status, 206)
        XCTAssertEqual(headResp.body, Data(full[0..<1024]))
        let moovResp = try fetch(local, range: "bytes=\(moovStart)-\(total - 1)")
        XCTAssertEqual(moovResp.status, 206)
        XCTAssertEqual(moovResp.body, Data(full[moovStart..<total]))
        XCTAssertEqual(ScriptedUpstream.receivedRanges().count, 2, "Head and tail moov must be served from cache without extra upstream requests")
    }

    /// 后台预热还在传输片头时 mpv 就发起了 bytes=0- 请求：直接接管在途连接并平滑续拉后续分段，不重复发 bytes=0- 请求。
    func testInFlightPrewarmIsAdoptedWithoutDuplicateUpstreamRequest() async throws {
        let total = 10_000
        let firstEnd = 4_999
        let full = pattern(total)
        let server = try ScriptedHTTPServer([
            .send(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 0-\(firstEnd)/\(total)",
                "Content-Length": "\(firstEnd + 1)",
                "Accept-Ranges": "bytes",
            ], body: Data(full[0...firstEnd])),
            .send(status: 206, headers: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes \(firstEnd + 1)-\(total - 1)/\(total)",
                "Content-Length": "\(total - firstEnd - 1)",
                "Accept-Ranges": "bytes",
            ], body: Data(full[(firstEnd + 1)..<total])),
        ])
        defer { server.stop() }
        let proxy = LocalStreamProxy()
        proxy.setChunkSizeForTesting(5_000)
        proxy.prewarm(url: server.url, headers: [:], streamID: "p115:adopt", resume: false)

        let relayed = await proxy.localURL(for: server.url, headers: [:], streamID: "p115:adopt")
        let local = try XCTUnwrap(relayed)
        let fetched = try fetch(local, range: "bytes=0-")
        XCTAssertEqual(fetched.status, 206)
        XCTAssertEqual(fetched.body, full)
        XCTAssertEqual(server.receivedRanges().count, 2, "Adopted prewarm must not duplicate the initial 0- range: \(server.receivedRanges())")
    }

    func testMKVCuesProbeDetectsSeekHeadCuesAndContainerIndexProbe() {
        // 构造一个最小合法 EBML Header + Segment + SeekHead（指向 Cues 相对偏移 50_000_000）
        func vint(_ value: UInt64) -> [UInt8] {
            if value < 0x7F { return [UInt8(0x80 | value)] }
            if value < 0x3FFF { return [UInt8(0x40 | (value >> 8)), UInt8(value & 0xFF)] }
            return [UInt8(0x20 | (value >> 16)), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
            id + vint(UInt64(payload.count)) + payload
        }
        let cuesPos: UInt32 = 50_000_000
        let posBytes: [UInt8] = [
            UInt8((cuesPos >> 24) & 0xFF),
            UInt8((cuesPos >> 16) & 0xFF),
            UInt8((cuesPos >> 8) & 0xFF),
            UInt8(cuesPos & 0xFF),
        ]
        let seekEntry = element([0x4D, 0xBB],
                                element([0x53, 0xAB], [0x1C, 0x53, 0xBB, 0x6B])
                                + element([0x53, 0xAC], posBytes))
        let seekHead = element([0x11, 0x4D, 0x9B, 0x74], seekEntry)
        let ebmlHeader = element([0x1A, 0x45, 0xDF, 0xA3], [0x42, 0x86, 0x81, 0x01])
        // Segment 未知长度（0x01FFFFFFFFFFFFFF）
        let segmentHeader: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let prefix = Data(ebmlHeader + segmentHeader + seekHead)
        let segDataStart = Int64(ebmlHeader.count + segmentHeader.count)
        let expectedStart = segDataStart + Int64(cuesPos)
        let totalSize: Int64 = expectedStart + 500_000

        XCTAssertEqual(
            MKVCuesProbe.inspect(prefix: prefix, totalSize: totalSize),
            .cuesAtTail(start: expectedStart, end: totalSize - 1)
        )
        XCTAssertEqual(
            ContainerIndexProbe.inspect(prefix: prefix, totalSize: totalSize),
            .indexAtTail(start: expectedStart, end: totalSize - 1, headBytesBeforeTailSwitch: 262_144)
        )

        // 没有 SeekHead 直接见到 Cluster 时回退到文件尾部 1.5 MiB
        let clusterHeader: [UInt8] = [0x1F, 0x43, 0xB6, 0x75, 0x81, 0x00]
        let noSeekHead = Data(ebmlHeader + segmentHeader + clusterHeader)
        let largeTotal: Int64 = 100_000_000
        XCTAssertEqual(
            MKVCuesProbe.inspect(prefix: noSeekHead, totalSize: largeTotal),
            .cuesAtTail(start: largeTotal - 1_572_864, end: largeTotal - 1)
        )
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
        /// 发出响应头和一部分内容，之后一直不结束（像一条还在下载的连接），直到被取消
        case hold(status: Int, headers: [String: String], body: Data)
    }

    private static let lock = NSLock()
    private static var steps: [Step] = []
    private static var ranges: [String?] = []
    private static var urls: [URL] = []
    private static var stops = 0

    static func install(_ steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        self.steps = steps
        ranges = []
        urls = []
        stops = 0
    }

    /// 被取消的 `.hold` 下载有几个
    static var stoppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    private var holding = false

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
        case .hold(let status, let headers, let body):
            holding = true
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        }
    }

    override func stopLoading() {
        guard holding else { return }
        holding = false
        Self.lock.lock()
        Self.stops += 1
        Self.lock.unlock()
    }
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
