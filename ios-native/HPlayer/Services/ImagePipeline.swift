import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// 一张要显示或预取的图片：地址加缩小后的最长边。同一张图在不同位置用不同尺寸，内存缓存按尺寸分开存，
/// 磁盘上只存一份原始数据。
struct ImageRequest: Hashable {
    let url: URL
    let maxPixel: Int
}

/// 各个位置用的缩小尺寸（最长边，单位像素）。预取和显示必须用同一个值，缓存才对得上。
enum ArtworkSize {
    static let poster = 600
    static let hero = 1280
    static let backdrop = 160
}

/// 图片原始数据的磁盘缓存。放在 Caches 里，系统缺空间时会自行清理；超过上限时按时间从旧到新删。
struct ImageDiskStore: Sendable {
    let directory: URL?

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HPlayerImages", isDirectory: true)
    }

    init(directory: URL?) {
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        self.directory = directory
    }

    static func name(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(for url: URL) -> URL? { directory?.appendingPathComponent(Self.name(for: url)) }

    func contains(_ url: URL) -> Bool {
        file(for: url).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func read(_ url: URL) -> Data? {
        guard let file = file(for: url), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // 写到一半被中断、或者当年存下来的是错误页，都不能留着，否则这张图永远加载不出来。
        guard ImagePipeline.isImage(data) else { try? FileManager.default.removeItem(at: file); return nil }
        return data
    }

    func write(_ data: Data, for url: URL) {
        guard let file = file(for: url) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// 超过 limit 就按修改时间从旧到新删，直到不超过 target。
    func trim(limit: Int = 400 << 20, target: Int = 300 << 20) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
              ) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// 海报和横幅的下载、缩小、缓存。
/// 系统的 AsyncImage 会把几百万像素的原图交给主线程解码，列表一滚就卡；
/// 这里在后台按显示尺寸缩小并完成解码，再放进内存缓存，主线程只负责显示。
/// 原始数据另存一份在磁盘上：重新打开 App 后封面直接从本地读，不用再从网上下载。
actor ImagePipeline {
    static let shared = ImagePipeline()

    nonisolated private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// 同一个地址的不同尺寸（横幅大图、背景小图、海报）共用一次下载。
    private var inFlightData: [URL: Task<Data?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private let session: URLSession
    private let disk: ImageDiskStore

    init(directory: URL? = ImageDiskStore.defaultDirectory, session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // 磁盘缓存由 ImageDiskStore 负责，不再让系统的 URLCache 重复存一份。
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: configuration)
        }
        disk = ImageDiskStore(directory: directory)
        cache.totalCostLimit = 160 << 20
        let store = disk
        Task.detached(priority: .background) { store.trim() }
    }

    nonisolated private static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    nonisolated func hasOnDisk(_ url: URL) -> Bool { disk.contains(url) }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
            guard let data = await self.data(for: url), !Task.isCancelled else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            let cost = Int(result.size.width * result.scale * result.size.height * result.scale) * 4
            cache.setObject(result, forKey: key as NSString, cost: cost)
        }
        return result
    }

    /// 原始图片数据：先看磁盘，没有再下载并存下来。
    private func data(for url: URL) async -> Data? {
        if let running = inFlightData[url] { return await running.value }
        let session = self.session
        let disk = self.disk
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let stored = disk.read(url) { return stored }
            for attempt in 0..<2 {
                guard !Task.isCancelled else { return nil }
                do {
                    let (data, response) = try await session.data(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    if (200..<300).contains(status) {
                        // 有的服务器对不存在的图片也回 200 加一张错误页，不能当作图片存下来。
                        guard Self.isImage(data) else { return nil }
                        disk.write(data, for: url)
                        return data
                    }
                    // 404、403 之类重试也不会好；只有服务器出错或被限流才再试一次。
                    if status < 500, status != 429 { return nil }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
                }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
            return nil
        }
        inFlightData[url] = task
        let data = await task.value
        inFlightData[url] = nil
        return data
    }

    // MARK: 预取

    /// 提前把这些图片放进内存缓存，滑到时直接有图，不用等下载。
    /// 每次调用都替换上一批：首页刷新得很频繁，不必让过期的一批继续排队。
    nonisolated func prefetch(_ requests: [ImageRequest]) {
        let pending = requests.filter { cached($0.url, maxPixel: $0.maxPixel) == nil }
        Task { await self.startPrefetch(pending) }
    }

    private func startPrefetch(_ requests: [ImageRequest]) {
        prefetchTask?.cancel()
        guard !requests.isEmpty else { prefetchTask = nil; return }
        prefetchTask = Task(priority: .utility) { await self.runPrefetch(requests) }
    }

    /// 同时最多下 3 张，顺序就是传进来的顺序（最先要用到的在最前面）。
    private func runPrefetch(_ requests: [ImageRequest]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<3 {
                guard let next = iterator.next() else { break }
                group.addTask { _ = await self.image(next.url, maxPixel: next.maxPixel) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { _ = await self.image(next.url, maxPixel: next.maxPixel) }
            }
        }
    }

    // MARK: 解码

    nonisolated static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // 原图比目标小就保持原样，不要放大：放大只会白占内存，画面也不会更清楚。
        var limit = maxPixel
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int, max(width, height) > 0 {
            limit = min(maxPixel, max(width, height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// 一张图当前的状态。加载中和失败要分开画：加载中只留一块底色，失败才画「空白海报」。
enum PipelineImagePhase {
    case loading
    case loaded(UIImage)
    case failed
}

/// 从 ImagePipeline 取图：缓存里有就第一帧直接显示，没有就后台加载后淡入。
/// 加载失败（网络抖动）时过几秒自动再试一次。
struct PipelineImage<Content: View>: View {
    let url: URL?
    let maxPixel: Int
    let content: (PipelineImagePhase) -> Content
    @State private var phase: PipelineImagePhase
    /// phase 里这张图对应的地址，用来判断视图重新出现时是否已经有图。
    @State private var shownURL: URL?

    init(url: URL?, maxPixel: Int, @ViewBuilder content: @escaping (PipelineImagePhase) -> Content) {
        self.url = url
        self.maxPixel = maxPixel
        self.content = content
        if let url {
            if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
                _phase = State(initialValue: .loaded(hit))
                _shownURL = State(initialValue: url)
            } else {
                _phase = State(initialValue: .loading)
                _shownURL = State(initialValue: nil)
            }
        } else {
            _phase = State(initialValue: .failed)
            _shownURL = State(initialValue: nil)
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard let url else { shownURL = nil; phase = .failed; return }
        if shownURL == url, case .loaded = phase { return }
        if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
            shownURL = url
            phase = .loaded(hit)
            return
        }
        shownURL = nil
        phase = .loading
        for attempt in 0..<2 {
            let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            if let loaded {
                shownURL = url
                withAnimation(.easeInOut(duration: 0.25)) { phase = .loaded(loaded) }
                return
            }
            phase = .failed
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }
}
