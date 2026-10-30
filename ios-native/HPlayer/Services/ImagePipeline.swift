import ImageIO
import SwiftUI
import UIKit

/// 海报和横幅的下载、缩小、缓存。
/// 系统的 AsyncImage 会把几百万像素的原图交给主线程解码，列表一滚就卡；
/// 这里在后台按显示尺寸缩小并完成解码，再放进内存缓存，主线程只负责显示。
actor ImagePipeline {
    static let shared = ImagePipeline()

    nonisolated private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        cache.totalCostLimit = 120 << 20
    }

    nonisolated private static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let session = session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  !Task.isCancelled else { return nil }
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

    nonisolated private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// 从 ImagePipeline 取图：缓存里有就第一帧直接显示，没有就后台加载后淡入。
struct PipelineImage<Content: View>: View {
    let url: URL?
    let maxPixel: Int
    let content: (UIImage?) -> Content
    @State private var image: UIImage?

    init(url: URL?, maxPixel: Int, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.url = url
        self.maxPixel = maxPixel
        self.content = content
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        content(image)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
                image = nil
                let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { image = loaded }
            }
    }
}
