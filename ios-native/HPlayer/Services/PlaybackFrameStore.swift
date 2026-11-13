import CoreImage
import CoreVideo
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 「继续观看」卡片的封面：停下来时那一刻的播放画面。
///
/// - 什么时候截：暂停、换集、退出播放页、App 退到后台（mpv 播放器在 `PlaybackController`，短剧在 `DramaEpisodePlayer`）。
/// - 截下来先缩到 720px 宽，在后台判断是不是黑场 / 纯色（转场、片头片尾）；是的话丢掉，保留上一张。
/// - 存在 Caches/HPlayerResumeFrames，按记录的键（`recent|…`、`magnet|…`）一条一张，最多 40 张，多了删最旧的。
/// - 卡片上优先显示这张图；没有时回落到片库海报、横图或 `ContinueArtworkStore` 找到的封面。
@MainActor
final class PlaybackFrameStore: ObservableObject {
    static let shared = PlaybackFrameStore()

    /// 每存一张图加一，卡片据此刷新
    @Published private(set) var revisions: [String: Int] = [:]

    private let cache = NSCache<NSString, UIImage>()
    private let directory: URL
    private static let limit = 40

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HPlayerResumeFrames", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache.countLimit = 24
    }

    // MARK: 键

    static func key(for source: PlaybackSource) -> String { "recent|" + RecentStore.key(for: source) }
    static func key(forMagnet infoHash: String) -> String { "magnet|" + infoHash.lowercased() }

    static func key(for target: ContinueEntry.Target) -> String {
        switch target {
        case .recent(let item): return "recent|" + RecentStore.key(of: item)
        case .magnet(let item): return key(forMagnet: item.infoHash)
        }
    }

    // MARK: 读

    func image(for key: String) -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: fileURL(for: key).path) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: 写

    /// mpv 截好的图片文件：后台缩小、判断黑场、存档，最后删掉临时文件。
    func ingest(file: URL, for key: String) {
        let target = fileURL(for: key)
        Task.detached(priority: .utility) { [weak self] in
            defer { try? FileManager.default.removeItem(at: file) }
            // mpv 的截图命令是同步写文件的；保险起见，文件还没出现时再等一会儿
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: file.path) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = ResumeFrameImaging.thumbnail(source) else { return }
            await self?.commit(image, to: target, key: key)
        }
    }

    /// AVPlayer（短剧）取到的一帧
    /// mpv 当前画面（`MPVEngine.videoFrameImage`）：后台缩小、判断黑场、存档。
    func ingest(image: CGImage, for key: String) {
        let target = fileURL(for: key)
        Task.detached(priority: .utility) { [weak self] in
            guard let scaled = ResumeFrameImaging.render(CIImage(cgImage: image)) else { return }
            await self?.commit(scaled, to: target, key: key)
        }
    }

    func ingest(pixelBuffer: CVPixelBuffer, for key: String) {
        let target = fileURL(for: key)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        Task.detached(priority: .utility) { [weak self] in
            guard let cgImage = ResumeFrameImaging.render(image) else { return }
            await self?.commit(cgImage, to: target, key: key)
        }
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: key))
        revisions[key] = nil
    }

    func removeAll() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revisions = [:]
    }

    private func commit(_ cgImage: CGImage, to target: URL, key: String) async {
        let directory = self.directory
        let limit = Self.limit
        let written: Bool = await Task.detached(priority: .utility) {
            // 黑场、纯色（转场、片头片尾、还没出画面）不要，保留上一张
            guard ResumeFrameImaging.isMeaningful(cgImage),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.78) else { return false }
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                return false
            }
            ResumeFrameImaging.prune(directory, limit: limit)
            return true
        }.value
        guard written else { return }
        cache.setObject(UIImage(cgImage: cgImage), forKey: key as NSString)
        revisions[key, default: 0] += 1
    }

    // MARK: 工具

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }
}

/// 截图的缩小、黑场判断、清理：都在后台线程做，不属于任何 actor。
enum ResumeFrameImaging {
    static let maxPixel: CGFloat = 720
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CIImage) -> CGImage? {
        let scale = min(1, maxPixel / max(image.extent.width, image.extent.height, 1))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 缩成 12×12 量一下：平均亮度太低（黑场）或几乎没有明暗变化（纯色、转场）都算没意义。
    static func isMeaningful(_ image: CGImage) -> Bool {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var values: [Double] = []
        values.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luma = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            values.append(luma / 255)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return mean > 0.06 && variance.squareRoot() > 0.025
    }

    static func prune(_ directory: URL, limit: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        sorted.dropFirst(limit).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
