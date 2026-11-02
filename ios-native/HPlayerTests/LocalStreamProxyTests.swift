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
}
