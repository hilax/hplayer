import UIKit
import XCTest
@testable import HPlayer

final class ImagePipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePipelineTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
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
