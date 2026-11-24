import XCTest
@testable import HPlayer

final class MagnetCoverFallbackTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [String] = []
        func add(_ code: String) { lock.lock(); codes.append(code); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return codes }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var date: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    func testFoundCoversAreLookedUpOnce() async throws {
        let calls = Calls()
        let cover = try XCTUnwrap(URL(string: "https://pics.example/cawb00079pl.jpg"))
        let fallback = MagnetCoverFallback(lookup: { code in calls.add(code); return cover })
        let first = await fallback.url(for: "cawb-079")
        let second = await fallback.url(for: "CAWB-079")
        XCTAssertEqual(first, cover)
        XCTAssertEqual(second, cover)
        XCTAssertEqual(calls.all, ["CAWB-079"], "The same code must not be looked up twice, whatever its case")
    }

    func testMissesAreRememberedForAWhileThenRetried() async throws {
        let calls = Calls()
        let clock = Clock()
        let fallback = MagnetCoverFallback(now: { clock.date }, lookup: { code in calls.add(code); return nil })
        let first = await fallback.url(for: "ZOOO-313")
        let again = await fallback.url(for: "ZOOO-313")
        XCTAssertNil(first)
        XCTAssertNil(again)
        XCTAssertEqual(calls.all.count, 1, "A miss is remembered so scrolling does not hammer the image service")

        clock.advance(MagnetCoverFallback.missLifetime + 1)
        _ = await fallback.url(for: "ZOOO-313")
        XCTAssertEqual(calls.all.count, 2, "New releases get covers a few days later, so a miss expires")
    }

    func testConcurrentRequestsShareOneLookup() async throws {
        let calls = Calls()
        let cover = try XCTUnwrap(URL(string: "https://pics.example/a.jpg"))
        let fallback = MagnetCoverFallback(lookup: { code in
            calls.add(code)
            try? await Task.sleep(nanoseconds: 100_000_000)
            return cover
        })
        async let one = fallback.url(for: "ARTV-083")
        async let two = fallback.url(for: "ARTV-083")
        let results = await [one, two]
        XCTAssertEqual(results, [cover, cover])
        XCTAssertEqual(calls.all.count, 1)
    }

    func testCancelledLookupIsNotCachedAsMiss() async throws {
        let calls = Calls()
        let fallback = MagnetCoverFallback(lookup: { code in
            calls.add(code)
            try? await Task.sleep(nanoseconds: 150_000_000)
            return nil
        })

        let pending = Task { await fallback.url(for: "CANC-001") }
        try await Task.sleep(nanoseconds: 30_000_000)
        pending.cancel()
        let cancelledResult = await pending.value
        XCTAssertNil(cancelledResult)

        _ = await fallback.url(for: "CANC-001")
        XCTAssertEqual(calls.all.count, 2, "中途取消的探测不得记为未命中缓存")
    }

    func testDiskCachePersistsAcrossInstancesAndSupportsSyncRead() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-fallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let cover = try XCTUnwrap(URL(string: "https://pics.example/disk001pl.jpg"))
        let firstCalls = Calls()
        let first = MagnetCoverFallback(cacheFile: tempFile, lookup: { code in
            firstCalls.add(code)
            return cover
        })
        let resolved = await first.url(for: "disk-001")
        XCTAssertEqual(resolved, cover)
        XCTAssertEqual(first.cachedURL(for: "DISK-001"), cover)

        let secondCalls = Calls()
        let second = MagnetCoverFallback(cacheFile: tempFile, lookup: { code in
            secondCalls.add(code)
            return nil
        })
        XCTAssertEqual(second.cachedURL(for: "disk-001"), cover)
        let restored = await second.url(for: "DISK-001")
        XCTAssertEqual(restored, cover)
        XCTAssertTrue(secondCalls.all.isEmpty, "命中磁盘缓存后不应再次探测")
    }
}
