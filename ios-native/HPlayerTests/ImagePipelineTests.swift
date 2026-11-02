import UIKit
import XCTest
@testable import HPlayer

final class ImagePipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePipelineTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        HeldImageURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makePipeline() -> ImagePipeline {
        ImagePipeline(directory: directory, session: RoutedURLProtocol.session())
    }

    func testOneDownloadServesEverySizeAndNeverUpscales() async throws {
        let data = png(width: 200, height: 100)
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Type": "image/png"], body: data) }
        let url = try XCTUnwrap(URL(string: "https://images.example/cover.png"))
        let pipeline = makePipeline()
        let largeImage = await pipeline.image(url, maxPixel: 1280)
        let smallImage = await pipeline.image(url, maxPixel: 50)
        let large = try XCTUnwrap(largeImage)
        let small = try XCTUnwrap(smallImage)
        XCTAssertEqual(large.size.width * large.scale, 200, "A small source must not be enlarged to the target size")
        XCTAssertEqual(small.size.width * small.scale, 50)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 1, "Different sizes of one URL share a single download")
        XCTAssertNotNil(pipeline.cached(url, maxPixel: 50))
        XCTAssertNil(pipeline.cached(url, maxPixel: 600))
    }

    func testDownloadedImagesSurviveARestartWithoutTheNetwork() async throws {
        let data = png(width: 80, height: 120)
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Type": "image/png"], body: data) }
        let url = try XCTUnwrap(URL(string: "https://images.example/poster.png"))
        let first = makePipeline()
        _ = await first.image(url, maxPixel: 600)
        XCTAssertTrue(first.hasOnDisk(url))

        RoutedURLProtocol.install { _ in .init(status: 500) }
        let relaunched = makePipeline()
        let image = await relaunched.image(url, maxPixel: 600)
        XCTAssertNotNil(image, "A cover downloaded earlier must load from disk even when the network is down")
        XCTAssertTrue(RoutedURLProtocol.requests().isEmpty)
    }

    func testMissingImagesAreNotRetriedButServerErrorsAreRetriedOnce() async throws {
        let notFound = try XCTUnwrap(URL(string: "https://images.example/missing.jpg"))
        RoutedURLProtocol.install { _ in .init(status: 404) }
        let missing = await makePipeline().image(notFound, maxPixel: 600)
        XCTAssertNil(missing)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 1)

        let broken = try XCTUnwrap(URL(string: "https://images.example/broken.jpg"))
        RoutedURLProtocol.install { _ in .init(status: 503) }
        let failed = await makePipeline().image(broken, maxPixel: 600)
        XCTAssertNil(failed)
        XCTAssertEqual(RoutedURLProtocol.requests().count, 2)
    }

    func testAnErrorPageWithStatus200IsNotKeptAsAnImage() async throws {
        let url = try XCTUnwrap(URL(string: "https://images.example/gateway.jpg"))
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>blocked</html>".utf8)) }
        let pipeline = makePipeline()
        let image = await pipeline.image(url, maxPixel: 600)
        XCTAssertNil(image)
        XCTAssertFalse(pipeline.hasOnDisk(url))
    }

    func testPrefetchFillsTheMemoryCacheBeforeCoversAreShown() async throws {
        let data = png(width: 60, height: 90)
        RoutedURLProtocol.install { _ in .init(status: 200, headers: ["Content-Type": "image/png"], body: data) }
        let urls = try (0..<5).map { try XCTUnwrap(URL(string: "https://images.example/p\($0).png")) }
        let pipeline = makePipeline()
        pipeline.prefetch(urls.map { ImageRequest(url: $0, maxPixel: 600) })
        for _ in 0..<200 {
            if urls.allSatisfy({ pipeline.cached($0, maxPixel: 600) != nil }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(urls.allSatisfy { pipeline.cached($0, maxPixel: 600) != nil }, "Prefetched covers must be in memory before they are shown")
        XCTAssertEqual(RoutedURLProtocol.requests().count, 5)
    }

    func testReplacingPrefetchCancelsAnUnusedDownload() async throws {
        HeldImageURLProtocol.reset()
        let url = try XCTUnwrap(URL(string: "https://images.example/old.png"))
        defer { HeldImageURLProtocol.complete(url, data: Data()) }
        let pipeline = ImagePipeline(directory: directory, session: HeldImageURLProtocol.session())
        pipeline.prefetch([ImageRequest(url: url, maxPixel: 600)])
        let started = await eventually { HeldImageURLProtocol.requestCount(for: url) == 1 }
        guard started else { XCTFail("Prefetch did not start"); return }

        pipeline.prefetch([])
        let cancelled = await eventually { HeldImageURLProtocol.cancelCount(for: url) == 1 }
        XCTAssertTrue(cancelled, "An obsolete prefetch with no consumers must cancel its URLSession request")
    }

    func testCancellingPrefetchKeepsDownloadUsedAtAnotherSize() async throws {
        HeldImageURLProtocol.reset()
        let url = try XCTUnwrap(URL(string: "https://images.example/shared.png"))
        let pipeline = ImagePipeline(directory: directory, session: HeldImageURLProtocol.session())
        pipeline.prefetch([ImageRequest(url: url, maxPixel: 600)])
        let started = await eventually { HeldImageURLProtocol.requestCount(for: url) == 1 }
        guard started else { XCTFail("Prefetch did not start"); return }
        let visible = Task { await pipeline.image(url, maxPixel: 1280) }
        defer { visible.cancel(); HeldImageURLProtocol.complete(url, data: Data()) }
        let shared = await eventually { await pipeline.waitingConsumersForTesting(url, maxPixel: 1280).data == 2 }
        guard shared else { XCTFail("Different image sizes should share the in-flight download"); return }

        pipeline.prefetch([])
        let detached = await eventually { await pipeline.waitingConsumersForTesting(url, maxPixel: 1280).data == 1 }
        XCTAssertTrue(detached)
        XCTAssertEqual(HeldImageURLProtocol.cancelCount(for: url), 0)
        HeldImageURLProtocol.complete(url, data: png(width: 80, height: 120))
        let image = await visible.value
        XCTAssertNotNil(image)
        XCTAssertEqual(HeldImageURLProtocol.requestCount(for: url), 1)
    }

    func testCancellingOneOfTwoConsumersKeepsTheSharedImageRequest() async throws {
        HeldImageURLProtocol.reset()
        let url = try XCTUnwrap(URL(string: "https://images.example/same-size.png"))
        let pipeline = ImagePipeline(directory: directory, session: HeldImageURLProtocol.session())
        let first = Task { await pipeline.image(url, maxPixel: 600) }
        defer { first.cancel(); HeldImageURLProtocol.complete(url, data: Data()) }
        let started = await eventually { HeldImageURLProtocol.requestCount(for: url) == 1 }
        guard started else { XCTFail("Image request did not start"); return }
        let second = Task { await pipeline.image(url, maxPixel: 600) }
        defer { second.cancel() }
        let shared = await eventually { await pipeline.waitingConsumersForTesting(url, maxPixel: 600).images == 2 }
        guard shared else { XCTFail("The image request was not shared"); return }

        first.cancel()
        let detached = await eventually { await pipeline.waitingConsumersForTesting(url, maxPixel: 600).images == 1 }
        XCTAssertTrue(detached)
        XCTAssertEqual(HeldImageURLProtocol.cancelCount(for: url), 0)
        let firstFinished = expectation(description: "cancelled consumer returns before the shared download")
        Task {
            let result = await first.value
            XCTAssertNil(result)
            firstFinished.fulfill()
        }
        await fulfillment(of: [firstFinished], timeout: 1)
        HeldImageURLProtocol.complete(url, data: png(width: 80, height: 120))
        let secondResult = await second.value
        XCTAssertNotNil(secondResult)
        XCTAssertEqual(HeldImageURLProtocol.requestCount(for: url), 1)
    }

    func testCancelledFlightCannotRemoveAReplacementForTheSameImage() async throws {
        HeldImageURLProtocol.reset()
        let url = try XCTUnwrap(URL(string: "https://images.example/replacement.png"))
        let pipeline = ImagePipeline(directory: directory, session: HeldImageURLProtocol.session())
        let first = Task { await pipeline.image(url, maxPixel: 600) }
        defer { first.cancel(); HeldImageURLProtocol.complete(url, data: Data()) }
        let started = await eventually { HeldImageURLProtocol.requestCount(for: url) == 1 }
        guard started else { XCTFail("First request did not start"); return }
        first.cancel()
        let cancelled = await eventually { HeldImageURLProtocol.cancelCount(for: url) == 1 }
        guard cancelled else { XCTFail("First request did not cancel"); return }

        let replacement = Task { await pipeline.image(url, maxPixel: 600) }
        defer { replacement.cancel() }
        let restarted = await eventually { HeldImageURLProtocol.requestCount(for: url) == 2 }
        guard restarted else { XCTFail("Replacement request did not start"); return }
        HeldImageURLProtocol.complete(url, data: png(width: 80, height: 120))
        let image = await replacement.value
        XCTAssertNotNil(image)
        XCTAssertEqual(HeldImageURLProtocol.requestCount(for: url), 2)
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testDiskTrimDropsTheOldestFilesFirst() throws {
        let store = ImageDiskStore(directory: directory)
        let urls = try (0..<3).map { try XCTUnwrap(URL(string: "https://images.example/t\($0).png")) }
        let data = png(width: 20, height: 20)
        for (index, url) in urls.enumerated() {
            store.write(data, for: url)
            let file = directory.appendingPathComponent(ImageDiskStore.name(for: url))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: file.path)
        }
        let size = data.count
        store.trim(limit: size * 2, target: size)
        XCTAssertFalse(store.contains(urls[0]))
        XCTAssertFalse(store.contains(urls[1]))
        XCTAssertTrue(store.contains(urls[2]), "The newest file is the one kept")
    }
}

/// Holds requests until the test completes or cancels them, so shared-consumer races are deterministic.
private final class HeldImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URL] = []
    private static var cancellations: [URL] = []
    private static var pending: [ObjectIdentifier: HeldImageURLProtocol] = [:]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
        cancellations = []
        pending = [:]
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0 == url }.count
    }

    static func cancelCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return cancellations.filter { $0 == url }.count
    }

    static func complete(_ url: URL, data: Data) {
        lock.lock()
        let matching = pending.values.filter { $0.request.url == url }
        for item in matching { pending.removeValue(forKey: ObjectIdentifier(item)) }
        lock.unlock()
        for item in matching {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: data)
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let url = request.url { Self.requests.append(url) }
        Self.pending[ObjectIdentifier(self)] = self
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if Self.pending.removeValue(forKey: ObjectIdentifier(self)) != nil, let url = request.url {
            Self.cancellations.append(url)
        }
    }
}
