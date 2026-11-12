import CryptoKit
import ImageIO
import Nuke
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

/// 图片原始数据的磁盘目录。日常读写和清理由 Nuke 的 DataCache 负责（同一个目录、同一套文件名）；
/// 这里只留给界面预览往缓存里预先放图，以及测试用。
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

    static func name(for url: URL) -> String { name(forKey: url.absoluteString) }

    /// 文件名 = 地址的 SHA-256。Nuke 的磁盘缓存用同一套文件名，所以两边读写的是同一批文件。
    static func name(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
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

/// 海报和横幅的下载、缩小、缓存。底层是 Nuke（下载合并、限流、按优先级排队、内存与磁盘两级缓存、
/// 后台用 ImageIO 直接生成缩略图并完成解码）；这一层只保留 HPlayer 自己的规矩：
/// - 按图床加请求头（有的图床要 Referer，否则回 403）；
/// - 错误页（状态码 200 但内容是网页）不当图片存；
/// - 临时错误（5xx、限流、超时、图床突发 403）重试两次，404 这类不重试；
/// - 同一张图不同尺寸共用一份原始数据，内存里按尺寸分开存；
/// - 磁盘缓存沿用原来的目录和文件名，升级后已经下过的封面不用重下。
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let nuke: Nuke.ImagePipeline
    private let dataCache: Nuke.DataCache?
    private let headers: @Sendable (URL) -> [String: String]
    /// 首页精选这种「整批替换」的预取：新的一批来了，旧的一批没用了就取消。
    private let batchPrefetcher: Nuke.ImagePrefetcher
    /// 列表往下滑时的「提前取后面几张」：只增不换，排队太长时丢掉最早的。
    private let aheadPrefetcher: Nuke.ImagePrefetcher
    private let lock = NSLock()
    private var batch: [Nuke.ImageRequest] = []
    private var ahead: [String] = []
    private var aheadRequests: [String: Nuke.ImageRequest] = [:]
    /// 预取队列最多留这么多张，滑得很快时最早排进去、已经用不上的那些会被取消。
    static let aheadLimit = 36

    init(
        directory: URL? = ImageDiskStore.defaultDirectory,
        session: URLSession? = nil,
        headers: @escaping @Sendable (URL) -> [String: String] = { JavBusSource.imageHeaders(for: $0) }
    ) {
        self.headers = headers
        let configuration: URLSessionConfiguration
        if let session {
            configuration = session.configuration
        } else {
            configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.httpMaximumConnectionsPerHost = 6
        }
        // 磁盘缓存由 Nuke 的 DataCache 负责，不让系统的 URLCache 再存一份。
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let loader = Nuke.DataLoader(configuration: configuration, validate: { response in
            if let error = Nuke.DataLoader.validate(response: response) { return error }
            // 有的服务器对不存在的图片回 200 加一张网页，直接在这里拦下，不往下解码、更不存盘。
            if let http = response as? HTTPURLResponse,
               let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               type.hasPrefix("text/html") || type.contains("json") {
                return NotAnImageResponse()
            }
            return nil
        })

        var config = Nuke.ImagePipeline.Configuration(dataLoader: loader)
        let cache: Nuke.DataCache? = directory.flatMap { directory in
            try? Nuke.DataCache(path: directory, filenameGenerator: { ImageDiskStore.name(forKey: $0) })
        }
        cache?.sizeLimit = 400 << 20
        config.dataCache = cache
        config.dataCachePolicy = .storeOriginalData
        config.imageCache = Nuke.ImageCache(costLimit: 160 << 20)
        config.isTaskCoalescingEnabled = true
        config.isRateLimiterEnabled = true
        dataCache = cache
        nuke = Nuke.ImagePipeline(configuration: config, delegate: ImagePipelineRules())
        batchPrefetcher = Nuke.ImagePrefetcher(pipeline: nuke, destination: .memoryCache, maxConcurrentRequestCount: 3)
        aheadPrefetcher = Nuke.ImagePrefetcher(pipeline: nuke, destination: .memoryCache, maxConcurrentRequestCount: 2)
        aheadPrefetcher.priority = .veryLow
    }

    // MARK: 请求

    private func request(_ url: URL, maxPixel: Int, priority: Nuke.ImageRequest.Priority = .normal) -> Nuke.ImageRequest {
        var urlRequest = URLRequest(url: url)
        for (field, value) in headers(url) { urlRequest.setValue(value, forHTTPHeaderField: field) }
        var request = Nuke.ImageRequest(urlRequest: urlRequest, priority: priority)
        // ImageIO 直接从原始数据生成缩略图：不先解出整张大图再缩，省内存也快；比原图小时不放大。
        request.thumbnail = Nuke.ImageRequest.ThumbnailOptions(maxPixelSize: Float(maxPixel))
        return request
    }

    private static func priority(_ value: TaskPriority) -> Nuke.ImageRequest.Priority {
        if value.rawValue >= TaskPriority.high.rawValue { return .high }
        if value.rawValue >= TaskPriority.medium.rawValue { return .normal }
        if value.rawValue >= TaskPriority.utility.rawValue { return .low }
        return .veryLow
    }

    /// 内存缓存里这个尺寸的图；没有就是 nil。可以在主线程同步调用。
    func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        nuke.cache[self.request(url, maxPixel: maxPixel)]?.image
    }

    func hasOnDisk(_ url: URL) -> Bool {
        dataCache?.containsData(for: url.absoluteString) ?? false
    }

    /// 把还在内存里排队的磁盘写入落盘（测试和退到后台时用）。
    func flushDiskCache() { dataCache?.flush() }

    func image(_ url: URL, maxPixel: Int, priority: TaskPriority = .userInitiated) async -> UIImage? {
        let request = self.request(url, maxPixel: maxPixel, priority: Self.priority(priority))
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return nil }
            do {
                return try await nuke.image(for: request)
            } catch let failure {
                let error = (failure as? Nuke.ImagePipeline.Error) ?? .cancelled
                guard !Task.isCancelled, Self.shouldRetry(error) else {
                    if Self.isUndecodable(error) {
                        // 原始数据按「不带缩略图选项」的请求存的，删的时候也要用同一个键
                        var original = request
                        original.thumbnail = nil
                        nuke.cache.removeCachedData(for: original)
                    }
                    return nil
                }
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: attempt == 0 ? 700_000_000 : 1_800_000_000) }
        }
        return nil
    }

    /// 404 之类重试也不会好；服务器出错、被限流、超时、断网，以及图床对突发请求回的 403 才再试。
    private static func shouldRetry(_ error: Nuke.ImagePipeline.Error) -> Bool {
        guard case let .dataLoadingFailed(underlying) = error else { return false }
        if let status = underlying as? Nuke.DataLoader.Error, case let .statusCodeUnacceptable(code) = status {
            return code >= 500 || [403, 408, 429].contains(code)
        }
        if underlying is NotAnImageResponse { return false }
        if let urlError = underlying as? URLError { return urlError.code != .cancelled }
        return !(underlying is CancellationError)
    }

    /// 存下来的数据解不出图（写坏了、或者当年存的是错误页）：删掉，下次重新下载，而不是永远失败。
    private static func isUndecodable(_ error: Nuke.ImagePipeline.Error) -> Bool {
        switch error {
        case .decodingFailed, .decoderNotRegistered, .dataIsEmpty: return true
        default: return false
        }
    }

    // MARK: 预取

    /// 提前把这些图片放进内存缓存，滑到时直接有图。每次调用都替换上一批：首页刷新得很频繁，
    /// 过期的一批不必继续排队（还没被别处用到的下载会被取消）。顺序就是传进来的顺序。
    func prefetch(_ requests: [ImageRequest]) {
        let next = requests.map { self.request($0.url, maxPixel: $0.maxPixel, priority: .low) }
        lock.lock()
        let previous = batch
        batch = next
        lock.unlock()
        if !previous.isEmpty { batchPrefetcher.stopPrefetching(with: previous) }
        if !next.isEmpty { batchPrefetcher.startPrefetching(with: next) }
    }

    /// 列表里一张卡片出现时，顺手把后面几张的封面取回来。已经在内存里、或者已经在排队的不会重复取。
    func prefetchAhead(_ requests: [ImageRequest]) {
        enqueueAhead(requests.map { item -> AheadItem in
            AheadItem(key: "\(item.maxPixel)|\(item.url.absoluteString)",
                      make: { self.request(item.url, maxPixel: item.maxPixel, priority: .veryLow) })
        })
    }

    /// 同上，用于自定义来源的图片（见 image(id:maxPixel:load:)）。
    func prefetchAhead(ids: [(id: String, load: @Sendable () async throws -> Data)], maxPixel: Int) {
        enqueueAhead(ids.map { item -> AheadItem in
            AheadItem(key: "\(maxPixel)|\(item.id)",
                      make: { self.request(id: item.id, maxPixel: maxPixel, priority: .veryLow, load: item.load) })
        })
    }

    private struct AheadItem {
        let key: String
        let make: () -> Nuke.ImageRequest
    }

    private func enqueueAhead(_ items: [AheadItem]) {
        var added: [Nuke.ImageRequest] = []
        var dropped: [Nuke.ImageRequest] = []
        lock.lock()
        for item in items where aheadRequests[item.key] == nil {
            let request = item.make()
            guard nuke.cache[request] == nil else { continue }
            aheadRequests[item.key] = request
            ahead.append(item.key)
            added.append(request)
        }
        while ahead.count > Self.aheadLimit {
            let key = ahead.removeFirst()
            if let request = aheadRequests.removeValue(forKey: key) { dropped.append(request) }
        }
        lock.unlock()
        if !dropped.isEmpty { aheadPrefetcher.stopPrefetching(with: dropped) }
        if !added.isEmpty { aheadPrefetcher.startPrefetching(with: added) }
    }

    // MARK: 自定义来源

    /// 不能直接下载的图（例如要先解密的短剧封面）：由 load 取回图片数据，缓存、缩图、后台解码照常交给 Nuke，
    /// 解好的数据也存盘，下次打开不用再取。id 要能唯一代表这张图。
    private func request(id: String, maxPixel: Int, priority: Nuke.ImageRequest.Priority = .normal,
                         load: @escaping @Sendable () async throws -> Data) -> Nuke.ImageRequest {
        var request = Nuke.ImageRequest(id: id, data: load, priority: priority)
        request.thumbnail = Nuke.ImageRequest.ThumbnailOptions(maxPixelSize: Float(maxPixel))
        return request
    }

    func cached(id: String, maxPixel: Int) -> UIImage? {
        nuke.cache[self.request(id: id, maxPixel: maxPixel, load: { Data() })]?.image
    }

    func image(id: String, maxPixel: Int, priority: TaskPriority = .userInitiated,
               load: @escaping @Sendable () async throws -> Data) async -> UIImage? {
        let request = self.request(id: id, maxPixel: maxPixel, priority: Self.priority(priority), load: load)
        guard !Task.isCancelled else { return nil }
        return try? await nuke.image(for: request)
    }

    // MARK: 解码工具

    static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

/// 服务器回的不是图片（网页、JSON）。
private struct NotAnImageResponse: Error {}

/// 存盘前再看一眼：不是图片的数据一律不存，避免一张图因为存了错误页而永远加载不出来。
private final class ImagePipelineRules: Nuke.ImagePipeline.Delegate {
    func willCache(data: Data, image: Nuke.ImageContainer?, for request: Nuke.ImageRequest,
                   pipeline: Nuke.ImagePipeline, completion: @escaping (Data?) -> Void) {
        completion(ImagePipeline.isImage(data) ? data : nil)
    }
}

/// 一张图当前的状态。加载中和失败要分开画：加载中只留一块底色，失败才画「空白海报」。
enum PipelineImagePhase {
    case loading
    case loaded(UIImage)
    case failed
}

/// 从 ImagePipeline 取图：缓存里有就第一帧直接显示，没有就后台加载后淡入。
/// 加载失败（网络抖动、图床限流）时隔几秒自动再试，最多再试两次；之后视图重新滑进屏幕还会再取。
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
        for attempt in 0..<3 {
            let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            if let loaded {
                shownURL = url
                withAnimation(ArtworkReveal.animation) { phase = .loaded(loaded) }
                return
            }
            phase = .failed
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 3_000_000_000 : 8_000_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }
}
