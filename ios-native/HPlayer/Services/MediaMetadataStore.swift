import CryptoKit
import Foundation

struct MediaMetadata: Codable, Identifiable, Hashable {
    let imdbID: String
    let type: String
    let title: String
    let year: String
    let posterURL: String
    let backgroundURL: String
    let logoURL: String
    let overview: String
    let rating: String
    let genres: [String]
    let country: String
    var season: Int?
    var episode: Int?
    var matchedByHash = false
    /// 原名（番组计划的日文/中文原名、TMDB 的原始片名），和 title 一样时为空
    var originalTitle: String? = nil
    /// 资料来源，见 MetadataSource；旧数据没有这个字段，都来自 IMDb（Cinemeta）
    var source: String? = nil
    /// 用户手动匹配的结果，清理旧缓存时不会动它
    var manual: Bool? = nil
    /// 演员名（目前来自 R18.dev），用来把同一演员的影片归成合集
    var performers: [String]? = nil

    var id: String { imdbID }
    var isSeries: Bool { type == "series" }
    var sourceKind: MetadataSource { source.flatMap(MetadataSource.init(rawValue:)) ?? .cinemeta }
    /// 评分前面带上来源：IMDb 8.0、Bangumi 7.4、TMDB 7.9
    var ratingLabel: String { rating.isEmpty ? "" : "\(sourceKind.ratingPrefix) \(rating)" }
    /// 只把可远程加载的封面放进海报墙；无封面的手动选择仍会保留在匹配缓存里。
    var hasUsablePoster: Bool {
        guard let url = URL(string: posterURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return true
    }
}

@MainActor
final class MediaMetadataStore: ObservableObject {
    @Published private(set) var metadataByMediaID: [String: MediaMetadata] = [:] { didSet { revision &+= 1 } }
    /// 每次匹配结果变化加一，页面用它判断是否需要重算，不必比较整个字典。
    private(set) var revision = 0
    private(set) var resolvingIDs: Set<String> = []
    private var bufferedResults: [String: MediaMetadata] = [:]
    private var lastPublishAt = Date()
    @Published private(set) var isMatching = false
    @Published private(set) var completedScanCount = 0
    @Published private(set) var lastCompletedAt: Date?

    private let storageKey = "hplayer.mediaMetadata.v3"
    private let legacyStorageKey = "hplayer.mediaMetadata.v2"
    private let defaults: UserDefaults
    private let lookup: (MediaNameParser.ParsedName) async -> MediaMetadata?
    private var hashCache: [String: MediaMetadata] = [:]
    private var titleCache: [String: MediaMetadata] = [:]
    /// 本机文件未变化时直接复用完整 SHA1，不在每次启动时重新读取几 GB 的视频。
    private var localFingerprints: [String: String] = [:]
    /// 用户点了「取消匹配」的片名和文件，不再自动识别
    private var ignored: Set<String> = []
    /// 自动识别没找到的片名和时间，半天内不重复去搜
    private var missed: [String: Date] = [:]
    private var pendingMedia: [LibraryMedia] = []
    private var pendingIndex = 0
    private var syncTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var validMediaIDs: Set<String> = []
    private var retryVersions: [String: Int] = [:]
    private struct NameInfo {
        let parsed: MediaNameParser.ParsedName
        let catalogKey: String?
        let legacyKey: String
        /// 番号只在开启番号匹配后才参与缓存，关闭时与以往完全一致。
        var key: String { AdultMetadataSettings.isEnabled ? (catalogKey ?? legacyKey) : legacyKey }
    }
    private var nameCache: [String: NameInfo] = [:]
    private var cacheDirty = false
    private var saveTask: Task<Void, Never>?

    private let concurrency: Int

    init(
        defaults: UserDefaults = .standard,
        concurrency: Int = 1,
        lookup: @escaping (MediaNameParser.ParsedName) async -> MediaMetadata? = { await MetadataSearch.shared.lookup($0) }
    ) {
        self.defaults = defaults
        self.lookup = lookup
        self.concurrency = max(1, concurrency)
        load()
    }

    /// 首帧同步恢复已有封面。这里只查已保存的片名、115 SHA1 和本机文件签名，不访问网络或读取视频内容。
    func hydrate(files: [LibraryMedia]) {
        let validIDs = Set(files.map(\.id))
        validMediaIDs = validIDs
        if nameCache.count > max(256, files.count * 2) {
            let names = Set(files.map(\.name))
            nameCache = nameCache.filter { names.contains($0.key) }
        }
        var restored: [String: MediaMetadata] = [:]
        for file in files {
            if let metadata = cachedMetadata(for: file) { restored[file.id] = metadata }
        }
        if metadataByMediaID != restored { metadataByMediaID = restored }
    }

    /// 用户在扫描页点了暂停或停止后，自动匹配不再自行重启，直到用户再次开始扫描或重新匹配。
    private(set) var stoppedByUser = false

    func stopByUser() {
        stoppedByUser = true
        pause()
    }

    func resumeAutomatic() { stoppedByUser = false }

    func sync(files: [LibraryMedia]) {
        hydrate(files: files)
        guard !stoppedByUser else { return }
        pendingMedia = files.filter { metadataByMediaID[$0.id] == nil && shouldResolve($0) }
        pendingIndex = 0
        guard syncTask == nil else { return }
        guard !pendingMedia.isEmpty else { finishScan(); return }
        scanGeneration += 1
        let generation = scanGeneration
        isMatching = true
        syncTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    group.addTask { @MainActor [weak self] in await self?.matchWorker(generation) }
                }
            }
            guard isCurrent(generation) else { return }
            publishBuffered()
            pendingMedia = []
            pendingIndex = 0
            syncTask = nil
            finishScan()
        }
    }

    private var inFlightKeys = Set<String>()

    /// 几个工作线程同时匹配不同的片名；同一个片名（例如同一部剧的各集）一次只查一份，
    /// 其余等第一份查完后直接用缓存，不会重复请求。
    private func matchWorker(_ generation: Int) async {
        var deferred = 0
        while isCurrent(generation), pendingIndex < pendingMedia.count {
            let file = pendingMedia[pendingIndex]
            pendingIndex += 1
            guard metadataByMediaID[file.id] == nil else { continue }
            let key = titleKey(file.name)
            if inFlightKeys.contains(key) {
                pendingMedia.append(file)
                deferred += 1
                // 剩下的全是正在查的片名：稍等一下再回来，别空转。
                if deferred > pendingMedia.count - pendingIndex { deferred = 0; try? await Task.sleep(nanoseconds: 150_000_000) }
                continue
            }
            deferred = 0
            inFlightKeys.insert(key)
            resolvingIDs.insert(file.id)
            let metadata = await resolve(file, generation: generation)
            inFlightKeys.remove(key)
            guard isCurrent(generation) else { return }
            if let metadata, validMediaIDs.contains(file.id), metadataByMediaID[file.id] == nil {
                bufferedResults[file.id] = metadata
            }
            resolvingIDs.remove(file.id)
            // 每匹配一部就发布一次会让首页整页重算、界面卡死；攒一批再一起更新。
            if bufferedResults.count >= 20 || Date().timeIntervalSince(lastPublishAt) >= 1.5 { publishBuffered() }
            await Task.yield()
        }
    }

    private func publishBuffered() {
        lastPublishAt = Date()
        guard !bufferedResults.isEmpty else { return }
        var merged = metadataByMediaID
        for (id, value) in bufferedResults where validMediaIDs.contains(id) && merged[id] == nil { merged[id] = value }
        bufferedResults = [:]
        metadataByMediaID = merged
    }

    /// 退到后台时立即停止自动查找。旧请求即使晚回来，也不能写入缓存或失败等待时间。
    func pause() {
        publishBuffered()
        scanGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        pendingMedia = []
        pendingIndex = 0
        resolvingIDs = []
        isMatching = false
        flushSave()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == scanGeneration && !Task.isCancelled
    }

    /// 用户主动重新扫描时，不沿用上一次失败的 12 小时等待；已手动取消匹配的文件仍然保持取消。
    func retryFailed(files: [LibraryMedia]) {
        stoppedByUser = false
        for file in files {
            let key = titleKey(file.name)
            missed.removeValue(forKey: key)
            retryVersions[key, default: 0] += 1
        }
        save()
        sync(files: files)
    }

    private func finishScan() {
        flushSave()
        isMatching = false
        lastCompletedAt = Date()
        completedScanCount += 1
    }

    private func shouldResolve(_ file: LibraryMedia) -> Bool {
        let info = nameInfo(file.name)
        let key = info.key
        if ignored.contains(key) || ignored.contains(info.legacyKey) || cachedFingerprint(file).map(ignored.contains) == true { return false }
        if let last = missed[key], Date().timeIntervalSince(last) < 12 * 3600 { return false }
        return true
    }

    private func cachedMetadata(for file: LibraryMedia) -> MediaMetadata? {
        let info = nameInfo(file.name)
        let key = info.key
        guard !ignored.contains(key), !ignored.contains(info.legacyKey) else { return nil }
        let parsed = info.parsed
        if let hash = cachedFingerprint(file) {
            guard !ignored.contains(hash) else { return nil }
            if var cached = hashCache[hash], cached.hasUsablePoster || cached.manual == true {
                cached.matchedByHash = true
                return withEpisode(cached, parsed)
            }
        }
        if var cached = titleCache[key], cached.hasUsablePoster || cached.manual == true {
            cached.matchedByHash = false
            return withEpisode(cached, parsed)
        }
        // 未开启番号匹配时保留旧缓存；开启后只沿用旧版的手动选择，不拿普通片名猜番号。
        if key != info.legacyKey, var cached = titleCache[info.legacyKey],
           (cached.manual == true || !AdultMetadataSettings.isEnabled),
           (cached.hasUsablePoster || cached.manual == true) {
            cached.matchedByHash = false
            return withEpisode(cached, parsed)
        }
        return nil
    }

    func match(_ metadata: MediaMetadata, to file: LibraryMedia) async {
        var value = metadata
        value.matchedByHash = false
        value.manual = true
        // 一部剧的每一集各记各的集数
        if value.isSeries {
            let parsed = nameInfo(file.name).parsed
            value.season = parsed.season ?? (parsed.episode == nil ? nil : 1)
            value.episode = parsed.episode
        }
        let key = titleKey(file.name)
        metadataByMediaID[file.id] = value
        titleCache[key] = value
        ignored.remove(key)
        ignored.remove(nameInfo(file.name).legacyKey)
        missed.removeValue(forKey: key)
        // 封面先保存，补算本机文件 SHA1 时即使退出 App，下次仍能立即恢复手动匹配。
        save(immediately: true)
        if let hash = await fingerprint(file) {
            guard titleCache[key] == value, !ignored.contains(key) else { return }
            hashCache[hash] = value
            ignored.remove(hash)
        }
        save(immediately: true)
    }

    /// 取消匹配：去掉封面和资料，以后也不再自动识别这个片名，可以随时重新手动匹配
    func unmatch(_ file: LibraryMedia) async {
        let key = titleKey(file.name)
        metadataByMediaID.removeValue(forKey: file.id)
        titleCache.removeValue(forKey: key)
        ignored.insert(key)
        save(immediately: true)
        if let hash = await fingerprint(file) {
            guard ignored.contains(key) else { return }
            hashCache.removeValue(forKey: hash)
            ignored.insert(hash)
        }
        save(immediately: true)
    }

    private func titleKey(_ filename: String) -> String {
        nameInfo(filename).key
    }

    private func nameInfo(_ filename: String) -> NameInfo {
        if let cached = nameCache[filename] { return cached }
        let parsed = MediaNameParser.parse(filename)
        let legacyKey = "\(MediaNameParser.cacheKey(parsed.title))|\(parsed.year ?? "")|\(parsed.season != nil || parsed.episode != nil ? "series" : "movie")"
        let value = NameInfo(parsed: parsed, catalogKey: parsed.catalogCode.map { "av:\($0)" }, legacyKey: legacyKey)
        nameCache[filename] = value
        return value
    }

    private func cachedFingerprint(_ file: LibraryMedia) -> String? {
        if file.sha1.count == 40, file.sha1.allSatisfy(\.isHexDigit) { return "sha1:\(file.sha1.lowercased())" }
        guard let signature = localSignature(file) else { return nil }
        return localFingerprints[signature]
    }

    private func localSignature(_ file: LibraryMedia) -> String? {
        guard let url = file.localURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    private func fingerprint(_ file: LibraryMedia, generation: Int? = nil) async -> String? {
        if let cached = cachedFingerprint(file) { return cached }
        guard let localURL = file.localURL, let signature = localSignature(file),
              let hash = await MediaFingerprint.make(for: localURL), !Task.isCancelled,
              generation.map({ $0 == scanGeneration }) ?? true,
              localSignature(file) == signature else { return nil }
        let value = "sha1:\(hash)"
        localFingerprints[signature] = value
        save()
        return value
    }

    private func resolve(_ file: LibraryMedia, generation: Int) async -> MediaMetadata? {
        if let cached = cachedMetadata(for: file) { return cached }
        guard shouldResolve(file), isCurrent(generation) else { return nil }
        let hash = await fingerprint(file, generation: generation)
        guard isCurrent(generation) else { return nil }
        let key = titleKey(file.name)
        if ignored.contains(key) || ignored.contains(nameInfo(file.name).legacyKey) || hash.map(ignored.contains) == true { return nil }
        let parsed = nameInfo(file.name).parsed
        if let hash, var cached = hashCache[hash], cached.hasUsablePoster || cached.manual == true {
            cached.matchedByHash = true
            return withEpisode(cached, parsed)
        }
        if var cached = titleCache[key], cached.hasUsablePoster || cached.manual == true {
            cached.matchedByHash = false
            if let hash { hashCache[hash] = cached; save() }
            return withEpisode(cached, parsed)
        }
        if let last = missed[key], Date().timeIntervalSince(last) < 12 * 3600 { return nil }
        let retryVersion = retryVersions[key, default: 0]
        let metadata = parsed.title.isEmpty ? nil : await lookup(parsed)
        guard isCurrent(generation) else { return nil }
        // 网络查找期间可能已手动匹配或取消，不能让晚回来的自动结果覆盖用户选择。
        if ignored.contains(key) || ignored.contains(nameInfo(file.name).legacyKey) || hash.map(ignored.contains) == true { return nil }
        if let cached = cachedMetadata(for: file) { return cached }
        guard let metadata, metadata.hasUsablePoster else {
            // 用户在本次请求等待期间点了重扫：现有请求结束后再查一次，不并发请求同一个来源。
            guard retryVersions[key, default: 0] == retryVersion else { return nil }
            missed[key] = Date()
            save()
            return nil
        }
        titleCache[key] = metadata
        missed.removeValue(forKey: key)
        if let hash { hashCache[hash] = metadata }
        save()
        return metadata
    }

    /// 缓存里存的是第一次识别时那一集的集数，换成当前文件自己的
    private func withEpisode(_ metadata: MediaMetadata, _ parsed: MediaNameParser.ParsedName) -> MediaMetadata {
        guard metadata.isSeries else { return metadata }
        var value = metadata
        value.season = parsed.season ?? (parsed.episode == nil ? nil : 1)
        value.episode = parsed.episode
        return value
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(CachePayload.self, from: data) {
            hashCache = payload.hash
            titleCache = payload.title
            ignored = payload.ignored ?? []
            missed = payload.missed ?? [:]
            localFingerprints = payload.localFingerprints ?? [:]
            discardPosterlessAutomaticMatches()
            return
        }
        // 第一次用新版：旧版对中文片名会直接取第一个搜索结果，配错的不少。
        // 只留下片名对得上的旧结果，其余的换新的识别方式重新识别。
        guard let data = defaults.data(forKey: legacyStorageKey),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return
        }
        titleCache = payload.title.filter { key, metadata in
            let title = key.components(separatedBy: "|").first ?? ""
            return MetadataScoring.titleScore(names: MetadataScoring.names(of: metadata), queries: [title]) >= 120
        }
        let kept = Set(titleCache.values.map(\.imdbID))
        hashCache = payload.hash.filter { kept.contains($0.value.imdbID) }
        discardPosterlessAutomaticMatches()
        save(immediately: true)
    }

    private func discardPosterlessAutomaticMatches() {
        let invalidKeys = titleCache.filter { !$0.value.hasUsablePoster && $0.value.manual != true }.map(\.key)
        for key in invalidKeys {
            titleCache.removeValue(forKey: key)
            missed.removeValue(forKey: key)
        }
        let oldHashCount = hashCache.count
        hashCache = hashCache.filter { $0.value.hasUsablePoster || $0.value.manual == true }
        if !invalidKeys.isEmpty || oldHashCount != hashCache.count { save() }
    }

    /// 连续识别多个文件时最多每 0.75 秒写一份快照，避免每一集都编码整份资料缓存。
    private func save(immediately: Bool = false) {
        cacheDirty = true
        if immediately { flushSave(); return }
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard cacheDirty else { return }
        let payload = CachePayload(hash: hashCache, title: titleCache, ignored: ignored, missed: missed, localFingerprints: localFingerprints)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
        cacheDirty = false
    }

    private struct CachePayload: Codable {
        let hash: [String: MediaMetadata]
        let title: [String: MediaMetadata]
        var ignored: Set<String>? = nil
        var missed: [String: Date]? = nil
        var localFingerprints: [String: String]? = nil
    }
}

enum MediaFingerprint {
    static func make(for url: URL) async -> String? {
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            // 大文件只取开头和结尾各 4MB 加上大小，整部读完要几十秒到几分钟。
            if let size = try? handle.seekToEnd(), size > 64 * 1024 * 1024 {
                let chunk = 4 * 1024 * 1024
                do {
                    try handle.seek(toOffset: 0)
                    if let head = try handle.read(upToCount: chunk) { hash.update(data: head) }
                    try handle.seek(toOffset: size - UInt64(chunk))
                    if let tail = try handle.read(upToCount: chunk) { hash.update(data: tail) }
                    hash.update(data: Data(String(size).utf8))
                    return hash.finalize().map { String(format: "%02x", $0) }.joined()
                } catch { return nil }
            }
            do {
                try handle.seek(toOffset: 0)
                while !Task.isCancelled {
                    guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else {
                        return hash.finalize().map { String(format: "%02x", $0) }.joined()
                    }
                    hash.update(data: data)
                }
            } catch { }
            return nil
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
}

enum MediaNameParser {
    struct ParsedName {
        let title: String
        let year: String?
        let season: Int?
        let episode: Int?
        /// 从原始文件名提取，避免方括号和字幕组清理时丢失番号。
        let catalogCode: String?

        /// 片名里的中文部分：「鬼谜东宫 The East Palace」里的「鬼谜东宫」
        var chineseTitle: String? {
            let words = title.split(separator: " ").map(String.init)
            let hanIndexes = words.indices.filter { MediaNameParser.containsHan(words[$0]) }
            guard let first = hanIndexes.first, let last = hanIndexes.last else { return nil }
            var end = last
            // 「流浪地球 2」这样紧跟在中文后面的续集编号一起带上
            if end + 1 < words.count, words[end + 1].count <= 2, words[end + 1].allSatisfy(\.isNumber) { end += 1 }
            return words[first...end].joined(separator: " ")
        }

        /// 片名里的英文部分：「鬼谜东宫 The East Palace」里的「The East Palace」
        var latinTitle: String? {
            let words = title.split(separator: " ").map(String.init).filter { !MediaNameParser.containsHan($0) }
            let joined = words.joined(separator: " ")
            return joined.filter(\.isLetter).count >= 3 ? joined : nil
        }

        /// 搜索时依次用中文名、英文名、完整片名
        var searchTitles: [String] {
            var seen = Set<String>()
            return [chineseTitle, latinTitle, title].compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        var looksLikeSeries: Bool { season != nil || episode != nil }
    }

    static func containsHan(_ text: String) -> Bool {
        text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: ParsedName] = [:]

    /// 解析要跑十几个正则，首页每次刷新都会对整个片库调用；结果按文件名缓存。
    static func parse(_ filename: String) -> ParsedName {
        cacheLock.lock()
        if let cached = parseCache[filename] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let value = parseUncached(filename)
        cacheLock.lock()
        if parseCache.count > 30_000 { parseCache.removeAll(keepingCapacity: true) }
        parseCache[filename] = value
        cacheLock.unlock()
        return value
    }

    static func parseUncached(_ filename: String) -> ParsedName {
        let extensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "ts", "webm", "flv", "wmv", "m2ts", "mpg", "mpeg", "rmvb", "iso"]
        var value = extensions.contains((filename as NSString).pathExtension.lowercased()) ? (filename as NSString).deletingPathExtension : filename
        // 网址水印、字幕组和下载站的标记：【www.xxx.com】、[某某字幕组]、[电影天堂www.dytt.com]
        value = value.replacingOccurrences(of: #"(?i)[\[【(（][^\]】)）]*(?:www|\.com|\.net|\.cc|\.org|\.tv|字幕|压制|下载|首发|论坛|bbs|高清)[^\]】)）]*[\]】)）]"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\bwww\.[a-z0-9-]+\.[a-z]{2,4}\b"#, with: " ", options: .regularExpression)
        // 动漫字幕组的命名：[组名] 片名 - 05 [1080p] 或 [组名][片名][05]，开头那一组方括号是组名。
        // 「[仙逆][Renegade Immortal][05]」这种第一组就是片名的不去掉
        if let range = value.range(of: #"^\s*\[[^\]]+\]"#, options: .regularExpression) {
            let group = String(value[range])
            let rest = value[range.upperBound...]
            let looksLikeGroup = group.range(of: #"(?i)(raws?|subs?|字幕|组|組|社|fansub|studio|&|-)"#, options: .regularExpression) != nil
            let titleFollows = rest.trimmingCharacters(in: .whitespaces).first.map { $0 != "[" } ?? false
            if looksLikeGroup || (titleFollows && rest.contains("[")) { value = String(rest) }
        }
        let bracketEpisode = capture(#"\[(\d{1,3})(?:v\d)?\]"#, in: value)
        value = value.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "[()\\[\\]【】（）《》]", with: " ", options: .regularExpression)

        let seasonEpisode = capture(#"(?i)\bS(\d{1,2})\s?E(\d{1,4})\b"#, in: value)
        let chineseEpisode = capture(#"第\s*(\d{1,4})\s*[集话話]"#, in: value)
        let episodeOnly = capture(#"(?i)\bEP?\s?(\d{1,4})\b"#, in: value)
        let dashEpisode = capture(#"(?:^|\s)-\s(\d{1,3})(?:v\d)?(?:\s|$)"#, in: value)
        let seasonOnly = capture(#"(?i)\b(?:S|Season\s?)(\d{1,2})\b"#, in: value)
        let chineseSeason = capture(#"第\s*([一二三四五六七八九十\d]{1,3})\s*季"#, in: value)
        let season = seasonEpisode.first.flatMap(Int.init)
            ?? seasonOnly.first.flatMap(Int.init) ?? chineseSeason.first.flatMap(chineseNumber)
        let episode = seasonEpisode.dropFirst().first.flatMap(Int.init)
            ?? chineseEpisode.first.flatMap(Int.init) ?? episodeOnly.first.flatMap(Int.init)
            ?? bracketEpisode.first.flatMap(Int.init) ?? dashEpisode.first.flatMap(Int.init)

        let year = capture(#"\b(19\d{2}|20\d{2})\b"#, in: value).first
        var releaseMarkers = [
            #"(?i)\bS\d{1,2}\s?E\d{1,4}\b"#,
            #"(?i)\bEP?\s?\d{1,4}\b"#,
            #"(?i)\b(?:S|Season\s?)\d{1,2}\b"#,
            #"第\s*[一二三四五六七八九十\d]{1,3}\s*季"#,
            #"(?:^|\s)-\s\d{1,3}(?:v\d)?(?:\s|$)"#,
            #"(?i)\b(?:NF|AMZN|DSNP|HMAX|ATVP|iTunes|HQ|60fps|120fps|1080i|AV1|VP9|FLAC|Opus|SDR|DV)\b"#,
            #"(?:国语中字|国粤双语|中英双字|中英字幕|双语字幕|内封字幕|内嵌字幕|特效字幕|全\d{1,4}集|更新至)"#,
            #"(?i)\b(?:19|20)\d{2}\b"#,
            #"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd)\b"#,
            #"(?i)\b(?:WEB[- ]?DL|WEBRip|BluRay|BDRip|HDTV|HDRip|DVDRip)\b"#,
            #"(?i)\b(?:H\.?264|H\.?265|HEVC|AVC|x264|x265)\b"#,
            #"(?i)\b(?:AAC|DDP?|AC3|DTS|TrueHD|Atmos)\b"#,
            #"(?i)\b(?:10bit|8bit|HDR10\+?|DoVi|Dolby Vision)\b"#,
            #"(?i)\b(?:REPACK|PROPER|REMUX|MULTi|CHS|CHT|简中|繁中|中字|国语|粤语)\b"#,
            #"(?i)\b(?:BlackTV|HDSWEB|Pure|CHD|WiKi|CMCT)\b"#,
            #"第\s*\d{1,4}\s*[集话話]"#,
        ]

        // [仙逆][Renegade Immortal][05]：方括号里的集数去掉方括号后成了单独的数字，从它开始都不算片名
        if let number = bracketEpisode.first {
            releaseMarkers.append(#"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: number) + #"(?:v\d)?(?=\s|$)"#)
        }
        var cutoff = value.endIndex
        for marker in releaseMarkers {
            if let range = value.range(of: marker, options: .regularExpression),
               range.lowerBound < cutoff {
                cutoff = range.lowerBound
            }
        }
        value = String(value[..<cutoff])
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—")))

        return ParsedName(
            title: value.isEmpty ? (filename as NSString).deletingPathExtension : value,
            year: year,
            season: season,
            episode: episode,
            catalogCode: AVCatalogCode.extract(filename)
        )
    }

    /// 「二」「十二」「3」这样的季数
    private static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text == "十" { return 10 }
        if text.hasPrefix("十"), let last = text.last, let unit = digits[last] { return 10 + unit }
        if text.count == 1, let first = text.first { return digits[first] }
        if text.count == 2, let first = text.first, text.last == "十", let tens = digits[first] { return tens * 10 }
        if text.count == 3, let first = text.first, let last = text.last, let tens = digits[first], let unit = digits[last] { return tens * 10 + unit }
        return nil
    }

    static func cacheKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}]+"#, with: "", options: .regularExpression)
    }

    private static func capture(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}

actor CinemetaClient {
    static let shared = CinemetaClient()
    private var endpoint: String {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["HPLAYER_METADATA_TEST_ENDPOINT"] { return value }
        #endif
        return "https://v3-cinemeta.strem.io"
    }

    /// 电影和剧集一起搜，结果交给 MetadataSearch 打分
    func search(_ title: String) async -> [MediaMetadata] {
        async let movies = search(title: title, type: "movie")
        async let series = search(title: title, type: "series")
        let results = await (movies, series)
        return (results.0 + results.1).map { item in
            var metadata = MediaMetadata(imdbID: item.id, type: item.type, title: item.name,
                year: extractYear(item.releaseInfo), posterURL: item.poster,
                backgroundURL: item.background, logoURL: "", overview: "", rating: "",
                genres: [], country: "", season: nil, episode: nil)
            metadata.source = MetadataSource.cinemeta.rawValue
            return metadata
        }
    }

    /// 自动匹配选中以后，再补上简介、评分、Logo 这些搜索结果里没有的资料
    func withDetail(_ metadata: MediaMetadata) async -> MediaMetadata {
        guard let detail = await detail(type: metadata.type, id: metadata.imdbID) else { return metadata }
        var value = MediaMetadata(
            imdbID: metadata.imdbID,
            type: metadata.type,
            title: detail.name.nonEmpty ?? metadata.title,
            year: extractYear(detail.releaseInfo ?? "").nonEmpty ?? metadata.year,
            posterURL: detail.poster.nonEmpty ?? metadata.posterURL,
            backgroundURL: detail.background.nonEmpty ?? metadata.backgroundURL,
            logoURL: detail.logo ?? "",
            overview: detail.description ?? "",
            rating: detail.imdbRating ?? "",
            genres: detail.genres ?? [],
            country: detail.country ?? "",
            season: metadata.season,
            episode: metadata.episode
        )
        value.source = MetadataSource.cinemeta.rawValue
        return value
    }

    private func search(title: String, type: String) async -> [CinemetaSearchItem] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(endpoint)/catalog/\(type)/top/search=\(encoded.replacingOccurrences(of: " ", with: "%20")).json") else {
            return []
        }
        guard let envelope: CinemetaSearchEnvelope = await request(url) else { return [] }
        return envelope.metas.filter { !$0.id.isEmpty && !$0.name.isEmpty }
    }

    private func detail(type: String, id: String) async -> CinemetaDetail? {
        guard let url = URL(string: "\(endpoint)/meta/\(type)/\(id).json"),
              let envelope: CinemetaDetailEnvelope = await request(url) else {
            return nil
        }
        return envelope.meta
    }

    private func request<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HPlayer/1.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func extractYear(_ value: String) -> String {
        value.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? ""
    }

    private struct CinemetaSearchEnvelope: Decodable {
        let metas: [CinemetaSearchItem]
    }

    private struct CinemetaSearchItem: Decodable {
        let id: String
        let type: String
        let name: String
        let poster: String
        let background: String
        let releaseInfo: String

        enum CodingKeys: String, CodingKey {
            case id, type, name, poster, background, releaseInfo
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            poster = try container.decodeIfPresent(String.self, forKey: .poster) ?? ""
            background = try container.decodeIfPresent(String.self, forKey: .background) ?? ""
            releaseInfo = try container.decodeIfPresent(String.self, forKey: .releaseInfo) ?? ""
        }
    }

    private struct CinemetaDetailEnvelope: Decodable {
        let meta: CinemetaDetail
    }

    private struct CinemetaDetail: Decodable {
        let name: String
        let poster: String
        let background: String
        let logo: String?
        let description: String?
        let genres: [String]?
        let releaseInfo: String?
        let imdbRating: String?
        let country: String?

        enum CodingKeys: String, CodingKey {
            case name, poster, background, logo, description, genres, releaseInfo, imdbRating, country
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            poster = try container.decodeIfPresent(String.self, forKey: .poster) ?? ""
            background = try container.decodeIfPresent(String.self, forKey: .background) ?? ""
            logo = try container.decodeIfPresent(String.self, forKey: .logo)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            genres = try container.decodeIfPresent([String].self, forKey: .genres)
            releaseInfo = try container.decodeIfPresent(String.self, forKey: .releaseInfo)
            imdbRating = try container.decodeIfPresent(String.self, forKey: .imdbRating)
            country = try container.decodeIfPresent(String.self, forKey: .country)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
