import Foundation

/// 磁力页封面的兜底：JavBus 对刚登记的新片，小图和大图常常都还没上传（一直回 404，重试没用）。
/// 这时按番号去 DMM 的图片服务找官方封面。只发送番号。
/// 结果按番号缓存在内存与磁盘：找到的持久化保存；没找到的隔一段时间再查（新片可能过几天才有封面）；
/// 列表滑出屏幕时同步取消孤立请求，避免挤占探测队列。
actor MagnetCoverFallback {
    static let shared = MagnetCoverFallback(cacheFile: defaultCacheFile)

    typealias Lookup = @Sendable (String) async -> URL?

    static let missLifetime: TimeInterval = 15 * 60
    static let maxDiskEntries = 500

    static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HPlayerCoverFallback.json")
    }

    private struct DiskPayload: Codable {
        var order: [String]
        var urls: [String: String]
    }

    private struct RunningEntry {
        let id: UUID
        let task: Task<URL?, Never>
    }

    private final class SyncURLStore: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: URL] = [:]

        func url(for key: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func set(_ url: URL, for key: String) {
            lock.lock()
            entries[key] = url
            lock.unlock()
        }

        func replaceAll(_ map: [String: URL]) {
            lock.lock()
            entries = map
            lock.unlock()
        }
    }

    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private let cacheFile: URL?
    private let syncStore = SyncURLStore()

    private var found: [String: URL] = [:]
    private var foundOrder: [String] = []
    private var missed: [String: Date] = [:]
    private var running: [String: RunningEntry] = [:]
    private var activeCallers: [String: Set<UUID>] = [:]

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        cacheFile: URL? = nil,
        lookup: @escaping Lookup = { code in
            guard let poster = await DMMClient.shared.lookupCover(code)?.posterURL else { return nil }
            return URL(string: poster)
        }
    ) {
        self.now = now
        self.cacheFile = cacheFile
        self.lookup = lookup

        if let cacheFile,
           let data = try? Data(contentsOf: cacheFile),
           let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) {
            var restored: [String: URL] = [:]
            var restoredOrder: [String] = []
            for code in payload.order {
                let key = code.uppercased()
                if let raw = payload.urls[key] ?? payload.urls[code], let url = URL(string: raw), restored[key] == nil {
                    restored[key] = url
                    restoredOrder.append(key)
                }
            }
            for (rawCode, rawURL) in payload.urls {
                let key = rawCode.uppercased()
                if restored[key] == nil, let url = URL(string: rawURL) {
                    restored[key] = url
                    restoredOrder.append(key)
                }
            }
            self.found = restored
            self.foundOrder = restoredOrder
            self.syncStore.replaceAll(restored)
        }
    }

    /// 同步读取已命中的封面地址，视图初始化首帧即可展示，不闪烁灰色占位。
    nonisolated func cachedURL(for code: String) -> URL? {
        let key = code.uppercased()
        guard !key.isEmpty else { return nil }
        return syncStore.url(for: key)
    }

    func url(for code: String) async -> URL? {
        let key = code.uppercased()
        guard !key.isEmpty, !Task.isCancelled else { return nil }
        if let hit = found[key] { return hit }
        if let time = missed[key], now().timeIntervalSince(time) < Self.missLifetime { return nil }

        let callerID = UUID()
        activeCallers[key, default: []].insert(callerID)

        let entry: RunningEntry
        if let existing = running[key] {
            entry = existing
        } else {
            let entryID = UUID()
            let lookup = self.lookup
            let task = Task<URL?, Never> { [self] in
                let result = await lookup(key)
                await self.finishLookup(key: key, entryID: entryID, result: result, wasCancelled: Task.isCancelled)
                return Task.isCancelled ? nil : result
            }
            entry = RunningEntry(id: entryID, task: task)
            running[key] = entry
        }

        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.cancelCaller(callerID, key: key, entryID: entry.id) }
        }

        finishCaller(callerID, key: key)
        return Task.isCancelled ? nil : result
    }

    private func finishCaller(_ callerID: UUID, key: String) {
        guard var callers = activeCallers[key] else { return }
        callers.remove(callerID)
        activeCallers[key] = callers.isEmpty ? nil : callers
    }

    private func cancelCaller(_ callerID: UUID, key: String, entryID: UUID) {
        guard var callers = activeCallers[key] else { return }
        callers.remove(callerID)
        if callers.isEmpty {
            activeCallers[key] = nil
            if running[key]?.id == entryID {
                running[key]?.task.cancel()
                running[key] = nil
            }
        } else {
            activeCallers[key] = callers
        }
    }

    private func finishLookup(key: String, entryID: UUID, result: URL?, wasCancelled: Bool) {
        if running[key]?.id == entryID {
            running[key] = nil
        }
        if let result {
            found[key] = result
            syncStore.set(result, for: key)
            missed[key] = nil
            foundOrder.removeAll { $0 == key }
            foundOrder.append(key)
            if foundOrder.count > Self.maxDiskEntries {
                let overflow = foundOrder.count - Self.maxDiskEntries
                let evicted = foundOrder.prefix(overflow)
                for oldKey in evicted {
                    found[oldKey] = nil
                }
                foundOrder.removeFirst(overflow)
                syncStore.replaceAll(found)
            }
            persistFound()
        } else if !wasCancelled {
            missed[key] = now()
        }
    }

    private func persistFound() {
        guard let cacheFile else { return }
        if let dir = cacheFile.deletingLastPathComponent() as URL? {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let payload = DiskPayload(
            order: foundOrder,
            urls: found.mapValues(\.absoluteString)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
