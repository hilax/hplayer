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
    func testRebuildsTheListenerWhenTheRecordedPortIsDead() throws {
        let proxy = LocalStreamProxy()
        let upstream = try XCTUnwrap(URL(string: "https://example.com/a/video.m3u8"))
        let first = try XCTUnwrap(proxy.localURL(for: upstream, headers: [:]))
        let firstPort = try XCTUnwrap(first.port)
        XCTAssertTrue(LocalStreamProxy.accepts(port: UInt16(firstPort)))
        XCTAssertTrue(proxy.statusText.contains("可连接"))

        proxy.simulateStalePortForTesting()
        XCTAssertTrue(proxy.statusText.contains("被拒绝"))

        let second = try XCTUnwrap(proxy.localURL(for: upstream, headers: [:]))
        let secondPort = try XCTUnwrap(second.port)
        XCTAssertTrue(LocalStreamProxy.accepts(port: UInt16(secondPort)), "The rebuilt relay must accept connections")
        XCTAssertTrue(proxy.statusText.contains("可连接"))
    }
}
