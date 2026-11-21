import Network
import SwiftUI
import UIKit
import XCTest
@testable import HPlayer

final class SeriesDetailBackdropTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var server: LocalTestImageServer?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeriesDetailBackdropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "hplayer.series-backdrop-test.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    @MainActor
    func testBackdropRevealNeverLeaksColoredEdgeAtBottomSeamInLightAndDarkModes() async throws {
        let scene = try requireScene()
        let imageServer = try LocalTestImageServer(
            backdropPNG: Self.solidPNG(width: 600, height: 400, color: .red),
            posterPNG: Self.solidPNG(width: 200, height: 300, color: UIColor(white: 0.5, alpha: 1)),
            backdropDelay: 0.04
        )
        server = imageServer

        for style in [UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark] {
            let token = UUID().uuidString
            let backdropURL = "http://127.0.0.1:\(imageServer.port)/backdrop-\(token).png"
            let posterURL = "http://127.0.0.1:\(imageServer.port)/poster-\(token).png"
            let env = makeEnvironment(posterURL: posterURL, backgroundURL: backdropURL)

            let root = NavigationStack {
                SeriesDetailView(seriesID: "tt-backdrop-test")
            }
            .environmentObject(env.appState)
            .environmentObject(env.library)
            .environmentObject(env.local)
            .environmentObject(env.metadata)
            .environmentObject(env.recents)
            .environmentObject(env.snapshots)

            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let samples = await sampleWindowFrames(window, duration: 1.0, intervalNanoseconds: 30_000_000)
            let label = style == .light ? "light" : "dark"

            let topRedDelta = samples.map { maxRedDelta(in: $0, pointRect: CGRect(x: window.bounds.width * 0.45, y: 55, width: 80, height: 30)) }.max() ?? 0
            XCTAssertGreaterThan(topRedDelta, 80, "\(label): expected red backdrop image to load and render in top hero region")

            let seamY: CGFloat = 264.0
            let seamHeight: CGFloat = 5.0
            for (idx, frame) in samples.enumerated() {
                let leak = maxRedDelta(
                    in: frame,
                    pointRect: CGRect(x: 0, y: seamY, width: window.bounds.width, height: seamHeight)
                )
                XCTAssertLessThanOrEqual(
                    leak, 10,
                    "\(label): backdrop leaked colored pixels across bottom seam at frame #\(idx) (redDelta=\(leak))"
                )
            }

            let settled = try XCTUnwrap(samples.last)
            let expectedBG: (r: Int, g: Int, b: Int) = style == .light ? (247, 247, 248) : (10, 10, 11)
            assertMatchesSolidColor(
                in: settled,
                pointRect: CGRect(x: 150, y: 264.5, width: max(40, window.bounds.width - 170), height: 4),
                expected: expectedBG,
                tolerance: 6,
                message: "\(label): settled seam right of poster must match Theme.pageBackground"
            )
        }
    }

    @MainActor
    func testBackdropSeamRemainsCleanDuringNavigationPushTransition() async throws {
        let scene = try requireScene()
        let imageServer = try LocalTestImageServer(
            backdropPNG: Self.solidPNG(width: 600, height: 400, color: .red),
            posterPNG: Self.solidPNG(width: 200, height: 300, color: UIColor(white: 0.5, alpha: 1)),
            backdropDelay: 0.03
        )
        server = imageServer

        let token = UUID().uuidString
        let backdropURL = "http://127.0.0.1:\(imageServer.port)/backdrop-push-\(token).png"
        let posterURL = "http://127.0.0.1:\(imageServer.port)/poster-push-\(token).png"
        let env = makeEnvironment(posterURL: posterURL, backgroundURL: backdropURL)
        let coordinator = PushCoordinator()

        let root = PushTestHost(coordinator: coordinator)
            .environmentObject(env.appState)
            .environmentObject(env.library)
            .environmentObject(env.local)
            .environmentObject(env.metadata)
            .environmentObject(env.recents)
            .environmentObject(env.snapshots)

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        coordinator.path.append("tt-backdrop-test")

        let samples = await sampleWindowFrames(window, duration: 1.1, intervalNanoseconds: 25_000_000)

        let topRedDelta = samples.map { maxRedDelta(in: $0, pointRect: CGRect(x: window.bounds.width * 0.5, y: 55, width: 80, height: 30)) }.max() ?? 0
        XCTAssertGreaterThan(topRedDelta, 80, "push: expected red backdrop image to load and render after navigation push")

        for (idx, frame) in samples.enumerated() {
            let leak = maxRedDelta(
                in: frame,
                pointRect: CGRect(x: 0, y: 264.0, width: window.bounds.width, height: 5.0)
            )
            XCTAssertLessThanOrEqual(
                leak, 10,
                "push: backdrop leaked colored pixels across bottom seam at frame #\(idx) (redDelta=\(leak))"
            )
        }
    }

    // MARK: - Helpers

    private struct TestEnvironment {
        let appState: AppState
        let library: MediaLibraryStore
        let local: LocalMediaStore
        let metadata: MediaMetadataStore
        let recents: RecentStore
        let snapshots: LibrarySnapshotStore
    }

    @MainActor
    private func makeEnvironment(posterURL: String, backgroundURL: String) -> TestEnvironment {
        let defaults = UserDefaults(suiteName: suiteName)!
        let appState = AppState(cookieLoader: { nil }, cookieValidator: { _ in }, cookieSaver: { _ in }, cookieRemover: {})
        let library = MediaLibraryStore(defaults: defaults)
        let local = LocalMediaStore(directory: tempDirectory)
        let metadata = MediaMetadataStore(defaults: defaults, lookup: { _ in nil })
        let recents = RecentStore(defaults: defaults)
        let snapshots = LibrarySnapshotStore()

        let media = LibraryMedia(local: LocalMedia(url: URL(fileURLWithPath: "/tmp/Series.S01E01.mp4"), size: 100, modified: .distantPast))
        let meta = MediaMetadata(
            imdbID: "tt-backdrop-test",
            type: "series",
            title: "测试剧集",
            year: "2026",
            posterURL: posterURL,
            backgroundURL: backgroundURL,
            logoURL: "",
            overview: "用于验证剧集详情页背景图底边不露出原图色边的测试简介。",
            rating: "",
            genres: [],
            country: "China",
            season: 1,
            episode: 1
        )
        snapshots.seed(HomeSnapshot(items: [HomeMediaItem(media: media, metadata: meta)]))
        return TestEnvironment(appState: appState, library: library, local: local, metadata: metadata, recents: recents, snapshots: snapshots)
    }

    @MainActor
    private func requireScene() throws -> UIWindowScene {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else {
            throw XCTSkip("No UIWindowScene available")
        }
        return scene
    }

    @MainActor
    private func sampleWindowFrames(_ window: UIWindow, duration: TimeInterval, intervalNanoseconds: UInt64) async -> [CapturedFrame] {
        let count = max(1, Int((duration * 1_000_000_000) / Double(intervalNanoseconds)))
        var frames: [CapturedFrame] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            if let captured = capture(window) {
                frames.append(captured)
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return frames
    }

    private struct CapturedFrame {
        let width: Int
        let height: Int
        let scale: CGFloat
        let rgba: [UInt8]
    }

    @MainActor
    private func capture(_ window: UIWindow) -> CapturedFrame? {
        let scale = window.screen.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedFrame(width: width, height: height, scale: scale, rgba: rgba)
    }

    private func pixelBounds(for pointRect: CGRect, in frame: CapturedFrame) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        let x0 = max(0, Int(floor(pointRect.minX * frame.scale)))
        let x1 = min(frame.width, Int(ceil(pointRect.maxX * frame.scale)))
        let y0 = max(0, Int(floor(pointRect.minY * frame.scale)))
        let y1 = min(frame.height, Int(ceil(pointRect.maxY * frame.scale)))
        return (x0, x1, y0, y1)
    }

    private func maxRedDelta(in frame: CapturedFrame, pointRect: CGRect) -> Int {
        let bounds = pixelBounds(for: pointRect, in: frame)
        guard bounds.x1 > bounds.x0, bounds.y1 > bounds.y0 else { return 0 }
        var maxDelta = 0
        for y in bounds.y0..<bounds.y1 {
            let rowStart = y * frame.width * 4
            for x in bounds.x0..<bounds.x1 {
                let offset = rowStart + x * 4
                let r = Int(frame.rgba[offset])
                let g = Int(frame.rgba[offset + 1])
                let b = Int(frame.rgba[offset + 2])
                let delta = r - max(g, b)
                if delta > maxDelta { maxDelta = delta }
            }
        }
        return maxDelta
    }

    private func assertMatchesSolidColor(
        in frame: CapturedFrame,
        pointRect: CGRect,
        expected: (r: Int, g: Int, b: Int),
        tolerance: Int,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bounds = pixelBounds(for: pointRect, in: frame)
        XCTAssertTrue(bounds.x1 > bounds.x0 && bounds.y1 > bounds.y0, "Empty pixel rect", file: file, line: line)
        for y in bounds.y0..<bounds.y1 {
            let rowStart = y * frame.width * 4
            for x in bounds.x0..<bounds.x1 {
                let offset = rowStart + x * 4
                let r = Int(frame.rgba[offset])
                let g = Int(frame.rgba[offset + 1])
                let b = Int(frame.rgba[offset + 2])
                if abs(r - expected.r) > tolerance || abs(g - expected.g) > tolerance || abs(b - expected.b) > tolerance {
                    XCTFail("\(message): pixel at (\(x), \(y)) was (\(r), \(g), \(b)), expected \(expected)", file: file, line: line)
                    return
                }
            }
        }
    }

    private static func solidPNG(width: Int, height: Int, color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

@MainActor
private final class PushCoordinator: ObservableObject {
    @Published var path = NavigationPath()
}

private struct PushTestHost: View {
    @ObservedObject var coordinator: PushCoordinator
    private let rootBar = RootNavigationBarState()

    var body: some View {
        NavigationStack(path: $coordinator.path) {
            Theme.pageBackground
                .ignoresSafeArea()
                .environment(\.rootNavigationBarState, rootBar)
                .rootNavigationBar(rootBar, depth: coordinator.path.count)
                .navigationDestination(for: String.self) { seriesID in
                    SeriesDetailView(seriesID: seriesID)
                }
        }
        .navigationButtonTint()
    }
}

private final class LocalTestImageServer {
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "hplayer.test-image-server")
    private let listener: NWListener
    private let backdropPNG: Data
    private let posterPNG: Data
    private let backdropDelay: TimeInterval

    init(backdropPNG: Data, posterPNG: Data, backdropDelay: TimeInterval) throws {
        self.backdropPNG = backdropPNG
        self.posterPNG = posterPNG
        self.backdropDelay = backdropDelay

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let readySemaphore = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                boundPort = listener.port?.rawValue ?? 0
                readySemaphore.signal()
            case .failed(let error):
                startError = error
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw XCTSkip("Timed out starting local test image server")
        }
        if let startError {
            listener.cancel()
            throw startError
        }
        guard boundPort != 0 else {
            listener.cancel()
            throw XCTSkip("Local test image server did not obtain a port")
        }
        self.port = boundPort
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let requestText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let isBackdrop = requestText.contains("/backdrop")
            let body = isBackdrop ? self.backdropPNG : self.posterPNG
            let delay = isBackdrop ? self.backdropDelay : 0

            let sendResponse = {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(body)
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }

            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay, execute: sendResponse)
            } else {
                sendResponse()
            }
        }
    }
}
