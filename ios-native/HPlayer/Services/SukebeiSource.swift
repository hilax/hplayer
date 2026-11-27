import CryptoKit
import Foundation

/// Sukebei 聚合开关设置，默认关闭。
enum SukebeiSettings {
    static let enabledKey = "hplayer.magnet.sukebei.enabled"

    static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { setEnabled(newValue, in: .standard) }
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

enum SukebeiError: LocalizedError {
    case invalidURL
    case serverError(Int)
    case network(Error)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 Sukebei 请求地址"
        case let .serverError(code):
            return "Sukebei 服务器响应异常（\(code)）"
        case let .network(err):
            return "Sukebei 网络请求失败：\(err.userMessage)"
        case .parseFailed:
            return "Sukebei RSS 解析失败"
        }
    }
}

/// Sukebei Nyaa RSS 解析出来的单条种子记录。
struct SukebeiRSSItem: Equatable, Hashable, Sendable, Codable {
    let title: String
    let infoHash: String
    let size: String
    let date: String?
    let seeders: Int?
    let leechers: Int?
    let categoryId: String?
}

/// Sukebei Nyaa RSS 客户端与解析器（无 Cloudflare，直接提供 infoHash 与做种数）。
final class SukebeiSource: @unchecked Sendable {
    static let shared = SukebeiSource(cacheDirectory: defaultCacheDirectory)

    static let defaultHost = "https://sukebei.nyaa.si"
    static let realLifeVideosCategory = "2_2"
    static let diskCacheMaxAge: TimeInterval = 24 * 60 * 60

    static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SukebeiRSSCache", isDirectory: true)
    }

    private struct DiskCacheEntry: Codable {
        let savedAt: Date
        let items: [SukebeiRSSItem]
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<[SukebeiRSSItem], Error>
    }

    private let session: URLSession
    private let host: String
    private let cacheLifetime: TimeInterval
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let cacheLock = NSLock()
    private var cache: [String: (time: Date, items: [SukebeiRSSItem])] = [:]
    private var inFlight: [String: InFlightEntry] = [:]

    init(
        session: URLSession? = nil,
        host: String = defaultHost,
        cacheLifetime: TimeInterval = 180,
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.host = host
        self.cacheLifetime = cacheLifetime
        self.cacheDirectory = cacheDirectory
        self.now = now
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        if let session {
            self.session = session
        } else {
            // 使用 default 配置保留 TLS 会话票据与 HTTP keep-alive 连接池，显著降低多次查询握手延迟；
            // 关闭 Cookie 与系统 URLCache，只由自己的磁盘与 TTL 缓存管理。
            let config = URLSessionConfiguration.default
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 4
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - URL 构建

    static func makeRSSURL(
        host: String = defaultHost,
        query: String? = nil,
        category: String = realLifeVideosCategory
    ) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, var components = URLComponents(string: trimmedHost),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        var queryItems = [
            URLQueryItem(name: "page", value: "rss"),
            URLQueryItem(name: "c", value: category),
        ]
        if let query {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                queryItems.append(URLQueryItem(name: "q", value: trimmedQuery))
            }
        }
        components.queryItems = queryItems
        return components.url
    }

    // MARK: - RSS 网络请求、磁盘 SWR 缓存与并发去重

    private func diskCacheFile(for key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let raw = key.isEmpty ? "__global__" : key
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hash).json")
    }

    private func readDiskEntry(for key: String) -> DiskCacheEntry? {
        guard let file = diskCacheFile(for: key),
              let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(DiskCacheEntry.self, from: data),
              now().timeIntervalSince(entry.savedAt) < Self.diskCacheMaxAge else {
            return nil
        }
        return entry
    }

    private func writeDiskEntry(_ items: [SukebeiRSSItem], savedAt: Date, for key: String) {
        guard let file = diskCacheFile(for: key),
              let data = try? JSONEncoder().encode(DiskCacheEntry(savedAt: savedAt, items: items)) else {
            return
        }
        try? data.write(to: file, options: .atomic)
    }

    private func cachedItems(for key: String) -> [SukebeiRSSItem]? {
        cacheLock.lock()
        if let entry = cache[key], now().timeIntervalSince(entry.time) < cacheLifetime {
            cacheLock.unlock()
            return entry.items
        }
        cacheLock.unlock()

        guard let disk = readDiskEntry(for: key),
              now().timeIntervalSince(disk.savedAt) < cacheLifetime else {
            return nil
        }
        cacheLock.lock()
        cache[key] = (disk.savedAt, disk.items)
        cacheLock.unlock()
        return disk.items
    }

    func staleCachedItems(for query: String? = nil) -> [SukebeiRSSItem]? {
        let key = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cacheLock.lock()
        if let entry = cache[key], now().timeIntervalSince(entry.time) < Self.diskCacheMaxAge {
            cacheLock.unlock()
            return entry.items
        }
        cacheLock.unlock()
        return readDiskEntry(for: key)?.items
    }

    /// 同步读取本地可用缓存（含超过 180 秒 TTL 但仍在 24 小时内的旧缓存），供首屏先出结果再后台静默更新。
    func cachedLatest() -> [MagnetSearchItem] {
        guard let entries = staleCachedItems(for: nil) else { return [] }
        return Self.groupMovies(from: entries)
    }

    func cachedStudio(_ studio: MagnetStudio) -> [MagnetSearchItem] {
        guard let entries = staleCachedItems(for: studio.sukebeiQuery) else { return [] }
        return Self.groupMovies(from: entries, allowedPrefixes: Set(studio.sukebeiPrefixes))
    }

    private func storeItems(_ items: [SukebeiRSSItem], for key: String) {
        let savedAt = now()
        cacheLock.lock()
        cache[key] = (savedAt, items)
        cacheLock.unlock()
        writeDiskEntry(items, savedAt: savedAt, for: key)
    }

    func fetchRSS(query: String? = nil, forceRefresh: Bool = false) async throws -> [SukebeiRSSItem] {
        try Task.checkCancellation()
        let trimmedQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !forceRefresh, let cached = cachedItems(for: trimmedQuery) {
            return cached
        }

        let task: Task<[SukebeiRSSItem], Error>
        cacheLock.lock()
        if !forceRefresh,
           let entry = cache[trimmedQuery],
           now().timeIntervalSince(entry.time) < cacheLifetime {
            cacheLock.unlock()
            return entry.items
        }
        if !forceRefresh, let existing = inFlight[trimmedQuery] {
            task = existing.task
            cacheLock.unlock()
        } else {
            let token = UUID()
            let created = Task<[SukebeiRSSItem], Error> { [self] in
                defer {
                    self.cacheLock.lock()
                    if self.inFlight[trimmedQuery]?.id == token {
                        self.inFlight[trimmedQuery] = nil
                    }
                    self.cacheLock.unlock()
                }
                return try await self.performFetchRSS(trimmedQuery: trimmedQuery)
            }
            inFlight[trimmedQuery] = InFlightEntry(id: token, task: created)
            task = created
            cacheLock.unlock()
        }

        let items = try await task.value
        try Task.checkCancellation()
        return items
    }

    private func performFetchRSS(trimmedQuery: String) async throws -> [SukebeiRSSItem] {
        guard let url = Self.makeRSSURL(host: host, query: trimmedQuery.isEmpty ? nil : trimmedQuery) else {
            throw SukebeiError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        req.setValue(JavBusSource.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SukebeiError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SukebeiError.serverError(http.statusCode)
        }

        let items = try Self.parseRSS(data)
        storeItems(items, for: trimmedQuery)
        return items
    }

    // MARK: - 业务接口

    /// 最新出种（Real Life - Videos 全局前 75 条按番号聚合）。
    func fetchLatest(forceRefresh: Bool = false) async throws -> [MagnetSearchItem] {
        let entries = try await fetchRSS(query: nil, forceRefresh: forceRefresh)
        return Self.groupMovies(from: entries)
    }

    /// 某家片商在 Sukebei 上刚出种的新作（严格按该片商现役番号前缀过滤）。
    func fetchStudio(_ studio: MagnetStudio, forceRefresh: Bool = false) async throws -> [MagnetSearchItem] {
        let entries = try await fetchRSS(query: studio.sukebeiQuery, forceRefresh: forceRefresh)
        return Self.groupMovies(from: entries, allowedPrefixes: Set(studio.sukebeiPrefixes))
    }

    /// 关键词或番号搜索。
    func search(keyword: String, forceRefresh: Bool = false) async throws -> [MagnetSearchItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let code = AVCatalogCode.extract(trimmed) {
            let query = "\(code)|\(code.replacingOccurrences(of: "-", with: ""))"
            let entries = try await fetchRSS(query: query, forceRefresh: forceRefresh)
            let filtered = entries.filter { AVCatalogCode.extract($0.title) == code }
            return Self.groupMovies(from: filtered)
        }
        let entries = try await fetchRSS(query: trimmed, forceRefresh: forceRefresh)
        return Self.groupMovies(from: entries)
    }

    /// 按番号查磁力列表。
    func fetchMagnets(code: String, forceRefresh: Bool = false) async throws -> [MagnetTorrentItem] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let matching: [SukebeiRSSItem]
        if let canonical = AVCatalogCode.extract(trimmed) {
            let query = "\(canonical)|\(canonical.replacingOccurrences(of: "-", with: ""))"
            let entries = try await fetchRSS(query: query, forceRefresh: forceRefresh)
            matching = entries.filter { AVCatalogCode.extract($0.title) == canonical }
        } else {
            let entries = try await fetchRSS(query: trimmed, forceRefresh: forceRefresh)
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            let regex = try? NSRegularExpression(
                pattern: "(?:^|[^A-Za-z0-9])\(escaped)(?!\\d)",
                options: [.caseInsensitive]
            )
            matching = entries.filter { item in
                guard let regex else { return item.title.localizedCaseInsensitiveContains(trimmed) }
                let range = NSRange(item.title.startIndex..<item.title.endIndex, in: item.title)
                return regex.firstMatch(in: item.title, range: range) != nil
            }
        }
        return MagnetAggregator.sortMagnets(matching.map(Self.toTorrentItem))
    }

    // MARK: - RSS XML 解析

    static func parseRSS(_ data: Data) throws -> [SukebeiRSSItem] {
        guard !data.isEmpty else { throw SukebeiError.parseFailed }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let delegate = RSSParserDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRSSRoot else {
            throw SukebeiError.parseFailed
        }
        return delegate.items
    }

    private final class RSSParserDelegate: NSObject, XMLParserDelegate {
        var items: [SukebeiRSSItem] = []
        var sawRSSRoot = false

        private var inItem = false
        private var currentElement = ""
        private var currentText = ""

        private var title = ""
        private var infoHash = ""
        private var size = ""
        private var pubDate = ""
        private var seeders = ""
        private var leechers = ""
        private var categoryId = ""

        private static func localName(_ elementName: String) -> String {
            elementName.split(separator: ":").last.map { $0.lowercased() } ?? elementName.lowercased()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let local = Self.localName(elementName)
            if local == "rss" || local == "channel" {
                sawRSSRoot = true
            }
            if local == "item" {
                inItem = true
                title = ""
                infoHash = ""
                size = ""
                pubDate = ""
                seeders = ""
                leechers = ""
                categoryId = ""
            }
            if inItem {
                currentElement = local
                currentText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem {
                currentText.append(string)
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inItem, let text = String(data: CDATABlock, encoding: .utf8) {
                currentText.append(text)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard inItem else { return }
            let local = Self.localName(elementName)
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            switch local {
            case "title":
                if title.isEmpty { title = trimmed }
            case "infohash":
                if infoHash.isEmpty { infoHash = trimmed }
            case "size":
                if size.isEmpty { size = trimmed }
            case "pubdate":
                if pubDate.isEmpty { pubDate = trimmed }
            case "seeders":
                if seeders.isEmpty { seeders = trimmed }
            case "leechers":
                if leechers.isEmpty { leechers = trimmed }
            case "categoryid":
                if categoryId.isEmpty { categoryId = trimmed }
            case "item":
                let normalizedHash = infoHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalizedHash.count == 40, normalizedHash.allSatisfy({ $0.isHexDigit }) {
                    items.append(SukebeiRSSItem(
                        title: title,
                        infoHash: normalizedHash,
                        size: size,
                        date: SukebeiSource.parsePubDate(pubDate),
                        seeders: Int(seeders),
                        leechers: Int(leechers),
                        categoryId: categoryId.isEmpty ? nil : categoryId
                    ))
                }
                inItem = false
            default:
                break
            }
            currentElement = ""
            currentText = ""
        }
    }

    // MARK: - 日期、磁力链接、标签与标题清理

    private static let dateLock = NSLock()
    private static let pubDateParsers: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let pubDateOutput: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parsePubDate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        dateLock.lock()
        defer { dateLock.unlock() }
        for parser in pubDateParsers {
            if let date = parser.date(from: trimmed) {
                return pubDateOutput.string(from: date)
            }
        }
        return nil
    }

    static func makeMagnetURL(infoHash: String, title: String) -> String {
        MagnetLink(
            infoHash: infoHash.lowercased(),
            isV2Only: false,
            displayName: title,
            trackers: [],
            extras: []
        ).uri
    }

    private static let codeSubtitleRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])[a-z]{2,8}[-_]?[0-9]{3,5}[-_]?(?:ch|uc|c)(?![a-z0-9])"#
    )
    private static let hdRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])(?:4k|2160p|1080p|fhd|uhd|60fps|hd)(?![a-z0-9])"#
    )

    static func hasSubtitles(in title: String) -> Bool {
        if title.contains("无字幕") || title.contains("無字幕") {
            return false
        }
        let lower = title.lowercased()
        let markers = ["中文字幕", "中字", "字幕", "[cn]", "[chs]", "[cht]", "ch-sub", "cn-sub", "chinese sub"]
        if markers.contains(where: { lower.contains($0) }) {
            return true
        }
        guard let regex = codeSubtitleRegex else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, range: range) != nil
    }

    static func isHD(in title: String) -> Bool {
        if title.contains("高清") {
            return true
        }
        guard let regex = hdRegex else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, range: range) != nil
    }

    private static let cleanupRegexes: [NSRegularExpression] = {
        let patterns = [
            // 1. 视频扩展名
            #"(?i)\.(?:mp4|mkv|avi|wmv|ts|iso)(?=$|[\s\]】)）])"#,
            // 2. 网址、带括号的广告域名或 site@ 前缀
            #"(?i)https?://[^\s\]】)）]+"#,
            #"(?i)(?:\[|【|\(|（)?\s*(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|cc|tv|xyz|top|vip|club|info|app|biz|live|site|fun|cn|ru|tk|pw|ws|xxx|work|link|online|store|red|me|to|in|co|io|us|la|one|pro|jp|tw|hk)\s*(?:\]|】|\)|）|@|-)?"#,
            #"[^\s@\[\]【】()（）]+@"#,
            // 3. 技术/发布标签
            #"(?i)(?:\[|【)?\s*(?:中文字幕|中字|chinese\s*sub|ch-sub|cn-sub|cn|chs|cht)\s*(?:\]|】)?"#,
            #"(?i)(?<![a-z0-9])(?:1080p|2160p|720p|4k|fhd|uhd|hd|60fps|hevc|h264|h265|x264|x265|aac|mp4|mkv|uncensored|leaked|leak)(?![a-z0-9])"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let emptyBracketsRegex = try? NSRegularExpression(pattern: #"\[\s*\]|【\s*】|\(\s*\)|（\s*）"#)

    private static func cleanedTitleAndIsDescriptive(
        from rawTitle: String,
        code: String,
        size: String,
        hasSubtitles: Bool,
        isHD: Bool
    ) -> (title: String, isDescriptive: Bool) {
        var text = rawTitle
        for regex in cleanupRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }

        // 去掉番号本身及其版本后缀（如 SONE-456-C / SONE456CH）
        let parts = code.split(separator: "-", maxSplits: 1)
        if parts.count == 2, let number = Int(parts[1]) {
            let prefix = NSRegularExpression.escapedPattern(for: String(parts[0]))
            let pattern = "(?i)(?:\\[|【|\\(|（)?(?<![a-z0-9])\(prefix)[-_ ]?0*\(number)(?:[-_]?(?:ch|uc|hd|c|u|a|b))?(?![a-z0-9])(?:\\]|】|\\)|）)?"
            if let codeRegex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = codeRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
        }

        if let emptyBracketsRegex {
            for _ in 0..<2 {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = emptyBracketsRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
        }

        let edgeJunk = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-_.|/·:：,，[]【】()（）"))
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: edgeJunk)

        let meaningful = collapsed.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        if collapsed.count >= 2, !meaningful.isEmpty {
            return (collapsed, true)
        }

        let summary = [
            hasSubtitles ? "中文字幕" : nil,
            isHD ? "高清" : nil,
            (!size.isEmpty && size != "未知大小") ? size : nil,
        ]
            .compactMap { $0 }
            .joined(separator: " · ")

        return (summary.isEmpty ? code : summary, false)
    }

    static func displayTitle(
        from rawTitle: String,
        code: String,
        size: String,
        hasSubtitles: Bool,
        isHD: Bool
    ) -> String {
        cleanedTitleAndIsDescriptive(
            from: rawTitle,
            code: code,
            size: size,
            hasSubtitles: hasSubtitles,
            isHD: isHD
        ).title
    }

    static func toTorrentItem(_ entry: SukebeiRSSItem) -> MagnetTorrentItem {
        let sizeText = entry.size.trimmingCharacters(in: .whitespacesAndNewlines)
        return MagnetTorrentItem(
            magnetURL: makeMagnetURL(infoHash: entry.infoHash, title: entry.title),
            name: entry.title,
            size: sizeText.isEmpty ? "未知大小" : sizeText,
            date: entry.date,
            isHD: isHD(in: entry.title),
            hasSubtitles: hasSubtitles(in: entry.title),
            seeders: entry.seeders,
            source: "Sukebei"
        )
    }

    static func groupMovies(
        from entries: [SukebeiRSSItem],
        allowedPrefixes: Set<String>? = nil
    ) -> [MagnetSearchItem] {
        var order: [String] = []
        var grouped: [String: [SukebeiRSSItem]] = [:]

        for entry in entries {
            guard let code = AVCatalogCode.extract(entry.title) else { continue }
            if let allowedPrefixes {
                let prefix = code.split(separator: "-").first.map(String.init) ?? ""
                guard allowedPrefixes.contains(prefix) else { continue }
            }
            if grouped[code] == nil {
                order.append(code)
            }
            grouped[code, default: []].append(entry)
        }

        return order.compactMap { code in
            guard let groupEntries = grouped[code], !groupEntries.isEmpty else { return nil }
            let torrents = MagnetAggregator.sortMagnets(groupEntries.map(toTorrentItem))

            var bestTitle: String?
            for entry in groupEntries {
                let sub = hasSubtitles(in: entry.title)
                let hd = isHD(in: entry.title)
                let size = entry.size.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = cleanedTitleAndIsDescriptive(
                    from: entry.title,
                    code: code,
                    size: size,
                    hasSubtitles: sub,
                    isHD: hd
                )
                if cleaned.isDescriptive {
                    bestTitle = cleaned.title
                    break
                }
                if bestTitle == nil {
                    bestTitle = cleaned.title
                }
            }

            let latestDate = groupEntries.compactMap(\.date).max()
            return MagnetSearchItem(
                id: "/\(code)",
                code: code,
                title: bestTitle ?? code,
                coverURL: nil,
                releaseDate: latestDate,
                detailPath: "/\(code)",
                stars: [],
                isFresh: true,
                prefetchedMagnets: torrents
            )
        }
    }
}
