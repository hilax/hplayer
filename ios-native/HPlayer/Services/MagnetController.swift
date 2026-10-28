import Foundation

/// 使用本机 BT 引擎和本机 HTTP 流，不依赖 HPlayer 服务器或 115 账号。
@MainActor
final class MagnetController: ObservableObject {
    @Published private(set) var files: [NuvioTorrentFile] = []
    let playback = VLCPlaybackController()
    @Published private(set) var ready = false
    @Published private(set) var working = false
    @Published private(set) var status = ""
    @Published private(set) var error = ""
    @Published private(set) var selectedIndex: UInt32?
    @Published private(set) var peerInfo = ""

    private var engine: NuvioEngine?
    private var torrentID: String?
    private var stream: NuvioStream?
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var monitor: Task<Void, Never>?

    static func supported(_ file: NuvioTorrentFile) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "webm", "flv"].contains((file.path as NSString).pathExtension.lowercased())
    }

    func start(_ raw: String) {
        let magnet = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: magnet), components.scheme?.lowercased() == "magnet",
              (components.queryItems ?? []).contains(where: {
                  let value = ($0.value ?? "").lowercased()
                  return $0.name.lowercased() == "xt" && (value.hasPrefix("urn:btih:") || value.hasPrefix("urn:btmh:"))
              }),
              magnet.utf8.count <= 8192 else {
            error = "请输入包含 BT 信息哈希的有效磁力链接。"
            return
        }
        guard !working else { return }
        close()
        working = true; status = "正在寻找节点并解析磁力链接…"; error = ""; files = []
        let previousCleanup = cleanup
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await previousCleanup?.value
                guard !Task.isCancelled else { return }
                let cache = try Self.cacheDirectory()
                let data = cache.appendingPathComponent("state", isDirectory: true)
                let pieces = cache.appendingPathComponent("pieces", isDirectory: true)
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
                let configuration = NuvioEngineConfiguration(dataDirectory: data, cacheDirectory: pieces,
                    memoryCacheCapacityBytes: 48 * 1024 * 1024, diskCacheCapacityBytes: 1024 * 1024 * 1024,
                    uploadMode: .limited(bytesPerSecond: 256 * 1024))
                let created = try await NuvioEngine.create(configuration: configuration)
                guard !Task.isCancelled else { await created.shutdown(); return }
                self.engine = created
                let torrent = try await Self.withTimeout(seconds: 90) { try await created.addMagnet(magnet) }
                guard !Task.isCancelled else { return }
                self.torrentID = torrent
                let entries = try await created.files(for: torrent)
                self.files = entries.filter {
                    ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "webm", "flv"].contains(($0.path as NSString).pathExtension.lowercased())
                }.sorted { $0.size > $1.size }
                guard !self.files.isEmpty else { throw APIError.server("这个磁力链接中没有找到视频文件。") }
                guard let first = self.files.first(where: Self.supported) else {
                    self.status = "已解析到视频，但没有可选的视频文件。"
                    self.working = false
                    return
                }
                try await self.prepare(first)
            } catch is CancellationError { return }
            catch { self.error = Self.describe(error); self.status = ""; self.working = false }
        }
    }

    func select(_ file: NuvioTorrentFile) {
        guard !working else { return }
        guard Self.supported(file) else { error = "当前文件格式暂不支持播放。"; return }
        working = true; error = ""
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await self.prepare(file) }
            catch is CancellationError { return }
            catch { self.error = Self.describe(error); self.status = ""; self.working = false }
        }
    }

    private func prepare(_ file: NuvioTorrentFile) async throws {
        guard let engine, let torrentID else { throw APIError.server("磁力任务已关闭") }
        status = "正在准备并缓冲视频…"
        playback.stop(detach: false)
        monitor?.cancel(); monitor = nil
        if let old = stream { try? await engine.stopStream(old.id); stream = nil }
        let next = try await engine.prepareStream(torrentID: torrentID, fileIndex: file.index)
        stream = next
        _ = try await engine.preloadStream(next, minimumContiguousBytes: min(next.fileSize, 1024 * 1024))
        guard !Task.isCancelled else { return }
        selectedIndex = file.index; status = "正在播放"; working = false; ready = true
        playback.open(next.url)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let stats = try? await engine.currentStats() {
                    self.peerInfo = "节点 \(stats.connectedPeers) · 下载 \(formatSize(Int(stats.downloadRateBytesPerSecond)))/秒"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func close() {
        let previousOperation = operation
        previousOperation?.cancel(); operation = nil
        monitor?.cancel(); monitor = nil
        playback.stop(); ready = false
        let oldEngine = engine, oldStream = stream, oldTorrent = torrentID
        engine = nil; stream = nil; torrentID = nil; selectedIndex = nil
        working = false; status = ""; peerInfo = ""; files = []; error = ""
        let previousCleanup = cleanup
        cleanup = Task {
            await previousCleanup?.value
            await previousOperation?.value
            if let oldEngine {
                if let oldStream { try? await oldEngine.stopStream(oldStream.id) }
                if let oldTorrent { try? await oldEngine.removeTorrent(oldTorrent) }
                await oldEngine.shutdown()
            }
        }
    }

    private static func cacheDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw APIError.server("无法创建本机缓存") }
        return caches.appendingPathComponent("HPlayerMagnet", isDirectory: true)
    }
    private static func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(nanoseconds: seconds * 1_000_000_000); throw APIError.server("磁力解析超时，可能没有可连接的节点。") }
            guard let first = try await group.next() else { throw APIError.server("磁力解析失败") }
            group.cancelAll()
            return first
        }
    }
    private static func describe(_ error: Error) -> String {
        if let value = error as? APIError { return value.localizedDescription }
        return "磁力播放未能完成：\(error.localizedDescription)"
    }
}
