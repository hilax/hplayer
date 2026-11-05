import Foundation
import UIKit

/// 「下载到手机」里的一条下载记录
struct DownloadItem: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
    }

    let id: UUID
    let fileID: String
    let pickCode: String
    let name: String
    let isVideo: Bool
    var totalBytes: Int64
    /// 来源位置，例如「网盘 / 电影」
    var folderLabel: String
    var state: State
    var receivedBytes: Int64
    /// 失败原因，或暂停时的说明
    var message: String
    let addedAt: Date
    var finishedAt: Date?
    /// 下载完成后保存的文件名（可能因为重名而和网盘里的名字不同）
    var savedName: String?
    /// true：保存在「本地视频」里；false：保存在 App 的「下载」文件夹里
    var savedInLibrary: Bool

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

struct DownloadStorageSummary: Equatable {
    /// 「本地视频」占用的空间
    var libraryBytes: Int64
    var freeBytes: Int64?
    var totalBytes: Int64?
}

/// 加入下载队列的结果，用来告诉用户哪些没有加进去
struct DownloadEnqueueSummary: Equatable {
    var added = 0
    /// 已经在下载列表里
    var duplicates = 0
    /// 文件夹暂不支持下载
    var folders = 0
    /// 没有提取码，下载不了
    var unavailable = 0
}

// MARK: - 文字

enum DownloadFormat {
    /// 4.37 GB、948 MB、12.3 KB
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var number = Double(value)
        var index = 0
        while number >= 1024, index < units.count - 1 {
            number /= 1024
            index += 1
        }
        let decimals: Int
        if index == 0 { decimals = 0 } else if index >= 3 { decimals = 2 } else { decimals = number >= 100 ? 0 : 1 }
        return String(format: "%.\(decimals)f %@", number, units[index])
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func remaining(_ seconds: Int) -> String {
        if seconds < 60 { return "剩余不到 1 分钟" }
        if seconds < 3600 { return "剩余约 \(Int((Double(seconds) / 60).rounded())) 分钟" }
        if seconds < 48 * 3600 { return "剩余约 \(Int((Double(seconds) / 3600).rounded())) 小时" }
        return "剩余时间较长"
    }
}

// MARK: - 文件

enum DownloadFiles {
    /// 把 115 上的文件名变成可以放在手机上的文件名：去掉路径分隔符和控制字符，不以点开头（否则会被当成隐藏文件），长度受限。
    static func safeFileName(_ raw: String, fallback: String = "下载文件") -> String {
        var name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return fallback }
        return limitedLength(name, maxBytes: 200)
    }

    private static func limitedLength(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let text = name as NSString
        let ext = text.pathExtension
        var stem = text.deletingPathExtension
        let reserved = ext.isEmpty ? 0 : ext.utf8.count + 1
        while stem.utf8.count + reserved > maxBytes, !stem.isEmpty { stem.removeLast() }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// 把下载好的文件移进目录。同一个磁盘上只是改名，不复制，几个 GB 的视频也是瞬间完成；重名时在后面加 (2)、(3)。
    static func move(_ source: URL, into directory: URL, preferredName: String, fileManager manager: FileManager = .default) throws -> URL {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = safeFileName(preferredName)
        let text = safe as NSString
        let stem = text.deletingPathExtension
        let ext = text.pathExtension
        for suffix in 1...10_000 {
            let name = suffix == 1 ? safe : (ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)")
            let destination = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { continue }
            do {
                try manager.moveItem(at: source, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

// MARK: - 管理器

/// 管理「下载到手机」：排队、同时下载几个、暂停/继续、失败重试，下载完成后放进「本地视频」。
///
/// 下载只在 App 打开时进行（原因见 RangeDownloader）：离开 App 后最多再下载约半分钟就会自动暂停，
/// 回到 App 时自动继续；中断的位置记在文件里，不会重新下载。
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    /// 正在下载的任务当前速度（字节/秒）
    @Published private(set) var speeds: [UUID: Double] = [:]

    /// 为一条下载生成带登录信息的请求。每次开始、续传都会重新生成，因为 115 的下载地址会过期。
    var requestProvider: (@MainActor (DownloadItem) async throws -> URLRequest)?
    /// 下载好的视频放进这个本地视频库；没有设置时放进默认的「本地视频」文件夹
    weak var media: LocalMediaStore?

    private let storeURL: URL
    private let partsDirectory: URL
    private let looseDirectory: URL
    private let maxConcurrent: Int
    private let protocolClasses: [AnyClass]?
    private let retryDelays: [TimeInterval]
    private let freeSpace: () -> Int64?
    /// 开始下载前给手机留的空间，不让下载把存储占满
    private let spaceMargin: Int64 = 100 * 1024 * 1024

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var samples: [UUID: [(time: TimeInterval, bytes: Int64)]] = [:]
    private var autoPaused = Set<UUID>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(storeURL: URL? = nil, partsDirectory: URL? = nil, looseDirectory: URL? = nil,
         maxConcurrent: Int = 2, protocolClasses: [AnyClass]? = nil,
         retryDelays: [TimeInterval] = [2, 5, 10], freeSpace: (() -> Int64?)? = nil) {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HPlayer", isDirectory: true)
        let parts = partsDirectory ?? support.appendingPathComponent("Downloads", isDirectory: true)
        self.partsDirectory = parts
        self.storeURL = storeURL ?? parts.appendingPathComponent("downloads.json")
        self.looseDirectory = looseDirectory
            ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        self.maxConcurrent = max(1, maxConcurrent)
        self.protocolClasses = protocolClasses
        self.retryDelays = retryDelays
        self.freeSpace = freeSpace ?? Self.availableSpace
        items = reconcile(load())
    }

    // MARK: 读取

    /// 没下完的：排队、下载中、已暂停、失败
    var unfinished: [DownloadItem] {
        items.filter { $0.state != .completed }.sorted { $0.addedAt < $1.addedAt }
    }

    var completed: [DownloadItem] {
        items.filter { $0.state == .completed }.sorted { ($0.finishedAt ?? $0.addedAt) > ($1.finishedAt ?? $1.addedAt) }
    }

    /// 还在占用连接的任务数（排队和下载中）
    var activeCount: Int {
        items.filter { $0.state == .queued || $0.state == .downloading }.count
    }

    func find(_ id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    func remainingSeconds(for item: DownloadItem) -> Int? {
        guard item.state == .downloading, let speed = speeds[item.id], speed >= 1, item.totalBytes > item.receivedBytes else { return nil }
        return Int(Double(item.totalBytes - item.receivedBytes) / speed)
    }

    /// 已经下载好的文件；被用户从「本地视频」里删掉后返回 nil
    func fileURL(for item: DownloadItem) -> URL? {
        guard item.state == .completed, let name = item.savedName else { return nil }
        let directory = item.savedInLibrary ? (media?.mediaDirectory ?? LocalMediaStore.defaultMediaDirectory) : looseDirectory
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func storageSummary() -> DownloadStorageSummary {
        let library = media?.files.reduce(Int64(0)) { $0 + Int64($1.size) } ?? 0
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return DownloadStorageSummary(libraryBytes: library, freeBytes: freeSpace(), totalBytes: values?.volumeTotalCapacity.map { Int64($0) })
    }

    // MARK: 操作

    /// 把文件加入下载队列。文件夹暂不支持，已经在列表里的不重复添加。
    @discardableResult
    func enqueue(_ files: [P115File], folderLabel: String) -> DownloadEnqueueSummary {
        var summary = DownloadEnqueueSummary()
        for file in files {
            if file.isDir {
                summary.folders += 1
                continue
            }
            guard !file.pickCode.isEmpty else {
                summary.unavailable += 1
                continue
            }
            if items.contains(where: { $0.pickCode == file.pickCode && $0.state != .completed }) {
                summary.duplicates += 1
                continue
            }
            items.append(DownloadItem(
                id: UUID(), fileID: file.id, pickCode: file.pickCode, name: file.name, isVideo: file.isVideo,
                totalBytes: Int64(max(0, file.size)), folderLabel: folderLabel, state: .queued, receivedBytes: 0,
                message: "", addedAt: Date(), finishedAt: nil, savedName: nil, savedInLibrary: false
            ))
            summary.added += 1
        }
        if summary.added > 0 {
            save()
            startNext()
        }
        return summary
    }

    func pause(_ id: UUID) {
        guard let index = indexOf(id), items[index].state == .downloading || items[index].state == .queued else { return }
        autoPaused.remove(id)
        stopRun(id)
        items[index].state = .paused
        items[index].message = "已暂停"
        speeds[id] = nil
        samples[id] = nil
        save()
        startNext()
        refreshIdleTimer()
    }

    /// 继续已暂停的任务，或者重试失败的任务；已有的部分不会重新下载
    func resume(_ id: UUID) {
        guard let index = indexOf(id), items[index].state == .paused || items[index].state == .failed else { return }
        items[index].state = .queued
        items[index].message = ""
        save()
        startNext()
    }

    func pauseAll() {
        for item in items where item.state == .downloading || item.state == .queued { pause(item.id) }
    }

    func resumeAll() {
        for item in items where item.state == .paused || item.state == .failed { resume(item.id) }
    }

    /// 删除一条下载：没下完的丢掉已下载的部分；下完的把手机上的文件一起删掉（不影响网盘里的文件）
    func delete(_ id: UUID) {
        guard let item = find(id) else { return }
        stopRun(id)
        try? FileManager.default.removeItem(at: partURL(id))
        if item.state == .completed, let url = fileURL(for: item) {
            try? FileManager.default.removeItem(at: url)
            if item.savedInLibrary { media?.refresh() }
        }
        removeRecord(id)
    }

    /// 只清除已完成的记录，下载好的文件仍然保留
    func clearCompletedRecords() {
        guard items.contains(where: { $0.state == .completed }) else { return }
        items.removeAll { $0.state == .completed }
        save()
    }

    #if DEBUG
    /// 界面预览用：直接放入几条下载记录和速度，不会开始真正的下载，也不会写入磁盘
    func setItemsForPreview(_ preview: [DownloadItem], speeds previewSpeeds: [UUID: Double] = [:]) {
        items = preview
        speeds = previewSpeeds
    }
    #endif

    // MARK: 前后台

    func sceneDidEnterBackground() {
        guard backgroundTask == .invalid, activeCount > 0 else { return }
        // 向系统多要一小段时间；时间到了就暂停，回到 App 再继续
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "app.hplayer.downloads") { [weak self] in
            Task { @MainActor in self?.suspendForBackground() }
        }
    }

    func sceneDidBecomeActive() {
        endBackgroundTask()
        let ids = autoPaused
        autoPaused.removeAll()
        for id in ids { resume(id) }
        refreshIdleTimer()
    }

    private func suspendForBackground() {
        for item in items where item.state == .downloading || item.state == .queued {
            pause(item.id)
            autoPaused.insert(item.id)
            if let index = indexOf(item.id) { items[index].message = "已暂停，回到 App 后自动继续" }
        }
        save()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 下载期间不让屏幕自动锁定：锁屏后下载就会暂停
    private func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = items.contains { $0.state == .downloading }
    }

    // MARK: 排队与下载

    private func startNext() {
        let running = items.filter { $0.state == .downloading }.count
        var slots = maxConcurrent - running
        guard slots > 0 else { return }
        for item in items.filter({ $0.state == .queued }).sorted(by: { $0.addedAt < $1.addedAt }) where slots > 0 {
            begin(item.id)
            slots -= 1
        }
        refreshIdleTimer()
    }

    private func begin(_ id: UUID) {
        guard tasks[id] == nil, let index = indexOf(id) else { return }
        items[index].state = .downloading
        items[index].message = ""
        samples[id] = []
        speeds[id] = nil
        let token = UUID()
        tokens[id] = token
        tasks[id] = Task { [weak self] in
            await self?.run(id, token: token)
        }
    }

    private func stopRun(_ id: UUID) {
        tokens[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func run(_ id: UUID, token: UUID) async {
        defer { runEnded(id, token: token) }
        var attempt = 0
        var refreshedAddress = false
        var restartedFromScratch = false
        while !Task.isCancelled {
            guard tokens[id] == token, let current = find(id), current.state == .downloading else { return }
            do {
                guard let provider = requestProvider else { throw APIError.server("请先登录 115") }
                try preflight(current)
                let request = try await provider(current)
                try Task.checkCancellation()
                let downloader = RangeDownloader(request: request, partURL: partURL(id), protocolClasses: protocolClasses) { [weak self] received, total in
                    Task { @MainActor in self?.recordProgress(id, token: token, received: received, total: total) }
                }
                let bytes = try await downloader.run()
                try Task.checkCancellation()
                complete(id, token: token, bytes: bytes)
                return
            } catch is CancellationError {
                return
            } catch let failure as RangeDownloader.Failure {
                if failure == .expired, !refreshedAddress {
                    // 地址过期了：换一个新地址再来一次
                    refreshedAddress = true
                    continue
                }
                if failure == .rangeRejected, !restartedFromScratch {
                    restartedFromScratch = true
                    try? FileManager.default.removeItem(at: partURL(id))
                    resetProgress(id)
                    continue
                }
                if failure.isRetryable, attempt < retryDelays.count {
                    let delay = retryDelays[attempt]
                    attempt += 1
                    note(id, token: token, "网络不稳定，\(Int(delay)) 秒后重试（\(attempt)/\(retryDelays.count)）")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                fail(id, token: token, failure.localizedDescription)
                return
            } catch {
                if Self.isTransient(error), attempt < retryDelays.count {
                    let delay = retryDelays[attempt]
                    attempt += 1
                    note(id, token: token, "网络不稳定，\(Int(delay)) 秒后重试（\(attempt)/\(retryDelays.count)）")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                fail(id, token: token, error.localizedDescription)
                return
            }
        }
    }

    private func runEnded(_ id: UUID, token: UUID) {
        guard tokens[id] == token else { return }
        tokens[id] = nil
        tasks[id] = nil
        samples[id] = nil
        speeds[id] = nil
        startNext()
        refreshIdleTimer()
        if activeCount == 0 { endBackgroundTask() }
    }

    /// 开始前检查手机剩余空间，不够就直接告诉用户，而不是下到一半写不进去
    private func preflight(_ item: DownloadItem) throws {
        let needed = max(0, item.totalBytes - partSize(item.id))
        guard needed > 0, let free = freeSpace() else { return }
        guard free >= needed + spaceMargin else {
            throw APIError.server("手机存储空间不足：还需要 \(DownloadFormat.bytes(needed))，现在只剩 \(DownloadFormat.bytes(max(0, free)))")
        }
    }

    private func recordProgress(_ id: UUID, token: UUID, received: Int64, total: Int64?) {
        guard tokens[id] == token, let index = indexOf(id), items[index].state == .downloading else { return }
        items[index].receivedBytes = received
        if let total, total > 0 { items[index].totalBytes = total }
        let now = ProcessInfo.processInfo.systemUptime
        var window = samples[id] ?? []
        window.append((now, received))
        window.removeAll { now - $0.time > 5 }
        samples[id] = window
        if let first = window.first, let last = window.last, last.time - first.time >= 1, last.bytes >= first.bytes {
            speeds[id] = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
    }

    private func note(_ id: UUID, token: UUID, _ message: String) {
        guard tokens[id] == token, let index = indexOf(id) else { return }
        items[index].message = message
    }

    private func resetProgress(_ id: UUID) {
        guard let index = indexOf(id) else { return }
        items[index].receivedBytes = 0
        samples[id] = []
        speeds[id] = nil
    }

    private func complete(_ id: UUID, token: UUID, bytes: Int64) {
        guard tokens[id] == token, let index = indexOf(id) else { return }
        let item = items[index]
        do {
            let ext = (item.name as NSString).pathExtension
            let saved: URL
            let inLibrary: Bool
            if item.isVideo, LocalMediaStore.supportsVideoExtension(ext) {
                let directory = media?.mediaDirectory ?? LocalMediaStore.defaultMediaDirectory
                saved = try DownloadFiles.move(partURL(id), into: directory, preferredName: item.name)
                inLibrary = true
            } else {
                saved = try DownloadFiles.move(partURL(id), into: looseDirectory, preferredName: item.name)
                inLibrary = false
            }
            items[index].state = .completed
            items[index].receivedBytes = bytes
            items[index].totalBytes = max(item.totalBytes, bytes)
            items[index].finishedAt = Date()
            items[index].savedName = saved.lastPathComponent
            items[index].savedInLibrary = inLibrary
            items[index].message = ""
            if inLibrary { media?.refresh() }
        } catch {
            items[index].state = .failed
            items[index].message = "保存文件失败：\(error.localizedDescription)"
        }
        save()
    }

    private func fail(_ id: UUID, token: UUID, _ message: String) {
        guard tokens[id] == token, let index = indexOf(id) else { return }
        items[index].state = .failed
        items[index].message = message
        items[index].receivedBytes = partSize(id)
        save()
    }

    // MARK: 存储

    private func indexOf(_ id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func removeRecord(_ id: UUID) {
        items.removeAll { $0.id == id }
        speeds[id] = nil
        samples[id] = nil
        autoPaused.remove(id)
        save()
        startNext()
        refreshIdleTimer()
    }

    private func partURL(_ id: UUID) -> URL {
        partsDirectory.appendingPathComponent("\(id.uuidString).part")
    }

    private func partSize(_ id: UUID) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: partURL(id).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([DownloadItem].self, from: data)) ?? []
    }

    /// 上次退出时还在下载或排队的，现在都是「已暂停」；已下载的字节数以文件的实际大小为准
    private func reconcile(_ loaded: [DownloadItem]) -> [DownloadItem] {
        loaded.map { stored in
            var item = stored
            switch item.state {
            case .queued, .downloading:
                item.state = .paused
                item.message = "已暂停"
                item.receivedBytes = partSize(item.id)
            case .paused, .failed:
                item.receivedBytes = partSize(item.id)
            case .completed:
                break
            }
            return item
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(items).write(to: storeURL, options: .atomic)
            // 下载记录和半成品是可以重新下载的，不必占用 iCloud 备份
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = partsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? directory.setResourceValues(values)
        } catch {
            // 记录写不进去也不影响正在进行的下载
        }
    }

    // MARK: 工具

    private nonisolated static func availableSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        if let http = error as? Direct115HTTPError { return http.statusCode == 429 || (500...599).contains(http.statusCode) }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
