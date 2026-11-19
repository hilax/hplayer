import CoreFoundation
import CoreText
import CryptoKit
import Foundation

// MARK: - 在线字幕偏好设置

/// 「我的 › 播放」与播放页共用的免费在线字幕偏好。
enum OnlineSubtitlePrefs {
    static let autoMatchKey = "player.autoOnlineSubtitle"
    static let sourceXunleiKey = "player.onlineSubtitle.xunlei"
    static let sourceSubtitleCatKey = "player.onlineSubtitle.subtitlecat"
    static let sourceShooterKey = "player.onlineSubtitle.shooter"
    static let sourceOpenSubtitlesKey = "player.onlineSubtitle.opensubtitles"

    static var autoMatchEnabled: Bool {
        get { readBool(autoMatchKey, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: autoMatchKey) }
    }

    static func isSourceEnabled(_ source: OnlineSubtitleSource) -> Bool {
        readBool(source.preferenceKey, defaultValue: true)
    }

    static func setSourceEnabled(_ source: OnlineSubtitleSource, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: source.preferenceKey)
    }

    static var enabledSources: [OnlineSubtitleSource] {
        OnlineSubtitleSource.allCases.filter { isSourceEnabled($0) }
    }

    static var summaryText: String {
        let count = enabledSources.count
        if count == 0 { return "未启用" }
        if count == OnlineSubtitleSource.allCases.count { return "全部免费来源" }
        return "\(count) 个来源"
    }

    private static func readBool(_ key: String, defaultValue: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }
}

// MARK: - 数据模型

enum OnlineSubtitleSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case xunlei
    case subtitlecat
    case shooter
    case opensubtitles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xunlei: return "迅雷字幕库"
        case .subtitlecat: return "SubtitleCat"
        case .shooter: return "射手网"
        case .opensubtitles: return "OpenSubtitles"
        }
    }

    var shortTitle: String {
        switch self {
        case .xunlei: return "迅雷"
        case .subtitlecat: return "SubtitleCat"
        case .shooter: return "射手"
        case .opensubtitles: return "OpenSub"
        }
    }

    var subtitle: String {
        switch self {
        case .xunlei: return "支持视频哈希与片名搜索，中文字幕覆盖影视、动漫及部分番号"
        case .subtitlecat: return "免费直出简繁中文字幕，重点覆盖 AV 番号与外语影片"
        case .shooter: return "通过视频 4 点指纹与文件名精确匹配字幕"
        case .opensubtitles: return "匹配电影、剧集与日韩番剧的公开字幕库"
        }
    }

    var preferenceKey: String {
        switch self {
        case .xunlei: return OnlineSubtitlePrefs.sourceXunleiKey
        case .subtitlecat: return OnlineSubtitlePrefs.sourceSubtitleCatKey
        case .shooter: return OnlineSubtitlePrefs.sourceShooterKey
        case .opensubtitles: return OnlineSubtitlePrefs.sourceOpenSubtitlesKey
        }
    }
}

struct OnlineSubtitleCandidate: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let languageLabel: String
    let format: String
    let source: OnlineSubtitleSource
    let downloadURL: URL
    let matchedByHash: Bool
    let durationSeconds: Double?
    let score: Int

    var isChinese: Bool {
        let lower = languageLabel.lowercased()
        return lower.contains("中") || lower.contains("简") || lower.contains("繁") || lower.contains("双语")
    }

    var trackTitle: String {
        "\(languageLabel) · \(source.shortTitle)"
    }

    var trackLanguageCode: String {
        let lower = languageLabel.lowercased()
        if lower.contains("简") || lower.contains("双语") { return "chs" }
        if lower.contains("繁") { return "cht" }
        if lower.contains("中") { return "chi" }
        if lower.contains("日") { return "jpn" }
        if lower.contains("英") { return "eng" }
        return "und"
    }

    var detailLine: String {
        var parts = [languageLabel, source.shortTitle]
        if matchedByHash { parts.append("哈希精准") }
        if !format.isEmpty { parts.append(format.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

struct OnlineSubtitleContext: Sendable {
    let rawTitle: String
    let streamURL: URL
    let knownFileSize: Int64?
    let durationSeconds: Double?
    let fallbackIdentifier: String?
    let imdbID: String?
    let isAdultVideo: Bool

    init(
        rawTitle: String,
        streamURL: URL,
        knownFileSize: Int64? = nil,
        durationSeconds: Double? = nil,
        fallbackIdentifier: String? = nil,
        imdbID: String? = nil,
        isAdultVideo: Bool = false
    ) {
        self.rawTitle = rawTitle
        self.streamURL = streamURL
        self.knownFileSize = knownFileSize
        self.durationSeconds = durationSeconds
        self.fallbackIdentifier = fallbackIdentifier
        self.imdbID = imdbID
        self.isAdultVideo = isAdultVideo
    }
}

// MARK: - 视频文件指纹（哈希）

struct VideoSubtitleFingerprint: Equatable, Sendable {
    static let minimumFileSize: Int64 = 131_072 // 128 KiB
    static let xunleiSampleSize = 20_480
    static let shooterSampleSize = 4_096
    static let openSubSampleSize = 65_536

    let fileSize: Int64
    let xunleiCID: String?
    let shooterHash: String?
    let openSubHash: String?

    /// 从任意抽象的数据读取器计算迅雷 CID、射手 4 点 MD5 与 OpenSubtitles MovieHash。
    /// 大于 128 KiB 的视频只需要读取 4 个微小区间（合计约 152 KiB）。
    static func compute(
        fileSize: Int64,
        readRange: @Sendable (Int64, Int) async -> Data?
    ) async -> VideoSubtitleFingerprint? {
        guard fileSize >= minimumFileSize else { return nil }
        let tailOffset = fileSize - Int64(openSubSampleSize)
        let thirdOffset = fileSize / 3
        let twoThirdsOffset = (fileSize * 2) / 3

        async let headTask = readRange(0, openSubSampleSize)
        async let thirdTask = readRange(thirdOffset, xunleiSampleSize)
        async let twoThirdsTask = readRange(twoThirdsOffset, shooterSampleSize)
        async let tailTask = readRange(tailOffset, openSubSampleSize)

        let head = await headTask
        let third = await thirdTask
        let twoThirds = await twoThirdsTask
        let tail = await tailTask

        var xunleiCID: String?
        if let head, head.count >= xunleiSampleSize,
           let third, third.count >= xunleiSampleSize,
           let tail, tail.count >= xunleiSampleSize {
            var combined = Data(capacity: xunleiSampleSize * 3)
            combined.append(head.prefix(xunleiSampleSize))
            combined.append(third.prefix(xunleiSampleSize))
            combined.append(tail.suffix(xunleiSampleSize))
            let digest = Insecure.SHA1.hash(data: combined)
            xunleiCID = digest.map { String(format: "%02X", $0) }.joined()
        }

        var shooterHash: String?
        let shooterTailStart = openSubSampleSize - 8_192
        let shooterTailEnd = shooterTailStart + shooterSampleSize
        if let head, head.count >= 4_096 + shooterSampleSize,
           let third, third.count >= shooterSampleSize,
           let twoThirds, twoThirds.count >= shooterSampleSize,
           let tail, tail.count >= shooterTailEnd {
            let blocks = [
                head.subdata(in: 4_096..<(4_096 + shooterSampleSize)),
                third.subdata(in: 0..<shooterSampleSize),
                twoThirds.subdata(in: 0..<shooterSampleSize),
                tail.subdata(in: shooterTailStart..<shooterTailEnd),
            ]
            shooterHash = blocks.map { block in
                Insecure.MD5.hash(data: block).map { String(format: "%02x", $0) }.joined()
            }.joined(separator: ";")
        }

        var openSubHash: String?
        if let head, head.count == openSubSampleSize,
           let tail, tail.count == openSubSampleSize {
            let sum = UInt64(fileSize) &+ littleEndianSum(head) &+ littleEndianSum(tail)
            openSubHash = String(format: "%016llx", sum)
        }

        guard xunleiCID != nil || shooterHash != nil || openSubHash != nil else { return nil }
        return VideoSubtitleFingerprint(
            fileSize: fileSize,
            xunleiCID: xunleiCID,
            shooterHash: shooterHash,
            openSubHash: openSubHash
        )
    }

    static func compute(localFileURL: URL) async -> VideoSubtitleFingerprint? {
        guard localFileURL.isFileURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: localFileURL.path)
        guard let rawSize = attrs?[.size] as? NSNumber else { return nil }
        let fileSize = rawSize.int64Value
        guard fileSize >= minimumFileSize else { return nil }

        return await compute(fileSize: fileSize) { offset, length in
            guard let handle = try? FileHandle(forReadingFrom: localFileURL) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: length)
            } catch {
                return nil
            }
        }
    }

    static func compute(
        streamURL: URL,
        knownFileSize: Int64? = nil,
        session: URLSession = .shared
    ) async -> VideoSubtitleFingerprint? {
        guard !streamURL.isFileURL else {
            return await compute(localFileURL: streamURL)
        }
        let lower = streamURL.absoluteString.lowercased()
        guard streamURL.pathExtension.lowercased() != "m3u8", !lower.contains(".m3u8") else {
            return nil
        }
        guard let headReply = await fetchRange(url: streamURL, offset: 0, length: openSubSampleSize, session: session) else {
            return nil
        }
        let resolvedSize = headReply.totalSize ?? knownFileSize ?? 0
        guard resolvedSize >= minimumFileSize else { return nil }
        let headData = headReply.data

        return await compute(fileSize: resolvedSize) { offset, length in
            if offset == 0 && length == headData.count {
                return headData
            }
            return await fetchRange(url: streamURL, offset: offset, length: length, session: session)?.data
        }
    }

    private struct RangeReply {
        let data: Data
        let totalSize: Int64?
    }

    private static func fetchRange(
        url: URL,
        offset: Int64,
        length: Int,
        session: URLSession
    ) async -> RangeReply? {
        guard offset >= 0, length > 0 else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              data.count >= min(length, openSubSampleSize) else {
            return nil
        }
        let total = parseTotalSize(from: http.value(forHTTPHeaderField: "Content-Range"))
        return RangeReply(data: data, totalSize: total)
    }

    static func parseTotalSize(from contentRange: String?) -> Int64? {
        guard let contentRange,
              let slash = contentRange.lastIndex(of: "/") else { return nil }
        let suffix = contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(suffix)
    }

    private static func littleEndianSum(_ data: Data) -> UInt64 {
        var sum: UInt64 = 0
        let count = data.count / 8
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let base = index * 8
                var value: UInt64 = 0
                for byte in 0..<8 {
                    value |= UInt64(raw[base + byte]) << (byte * 8)
                }
                sum &+= value
            }
        }
        return sum
    }
}

// MARK: - 片名与 AV 番号查询构建

struct SubtitleQueryPlan: Equatable, Sendable {
    let displayQuery: String
    let xunleiQueries: [String]
    let shooterFileName: String
    let avCatalogCode: String?
    let parsed: MediaNameParser.ParsedName
    let isAdultVideo: Bool
}

enum SubtitleQueryBuilder {
    /// 提取常规有码番号（ABC-123）或无码常见番号（FC2-PPV-1234567、HEYZO-1234、一本道/加勒比日期番号）。
    static func extractAVCode(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // 1. FC2-PPV-1234567 / FC2PPV-1234567 / FC2-1234567
        if let fc2 = firstMatch(#"(?i)(?<![a-z0-9])fc2(?:[-_ ]?ppv)?[-_ ]?(\d{5,8})(?!\d)"#, in: value, group: 1) {
            return "FC2-PPV-\(fc2)"
        }
        // 2. HEYZO-1234
        if let heyzo = firstMatch(#"(?i)(?<![a-z0-9])heyzo[-_ ]?(\d{4})(?!\d)"#, in: value, group: 1) {
            return "HEYZO-\(heyzo)"
        }
        // 3. 1pondo / carib / 10musume / pacopacomama: 123456_789 或 123456-789
        if let uncensored = firstMatch(#"(?i)(?<![0-9])(\d{6}[_-]\d{2,3})(?![0-9])"#, in: value, group: 1),
           value.range(of: #"(?i)(1pon|carib|10musume|paco|uncensored|无码)"#, options: .regularExpression) != nil {
            return uncensored
        }
        // 4. 标准有码番号（复用项目现有 AVCatalogCode）
        return AVCatalogCode.extract(value)
    }

    static func build(
        rawTitle: String,
        streamURL: URL,
        fallbackIdentifier: String? = nil,
        isAdultHint: Bool = false,
        manualQuery: String? = nil
    ) -> SubtitleQueryPlan {
        let manual = manualQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let manual, !manual.isEmpty {
            let avCode = extractAVCode(from: manual)
            let parsed = MediaNameParser.parse(manual)
            let queries = uniqueNonEmpty([avCode, manual, parsed.chineseTitle, parsed.latinTitle, parsed.title])
            return SubtitleQueryPlan(
                displayQuery: avCode ?? manual,
                xunleiQueries: Array(queries.prefix(3)),
                shooterFileName: streamURL.lastPathComponent.isEmpty ? "\(manual).mkv" : streamURL.lastPathComponent,
                avCatalogCode: avCode,
                parsed: parsed,
                isAdultVideo: isAdultHint || avCode != nil
            )
        }

        let fileLast = streamURL.isFileURL ? streamURL.lastPathComponent : ""
        let candidateTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let parseSource = candidateTitle.isEmpty ? fileLast : candidateTitle

        let avCode = extractAVCode(from: candidateTitle)
            ?? extractAVCode(from: fileLast)
            ?? fallbackIdentifier.flatMap(extractAVCode)

        let parsed = MediaNameParser.parse(parseSource)
        if let avCode {
            return SubtitleQueryPlan(
                displayQuery: avCode,
                xunleiQueries: [avCode],
                shooterFileName: fileLast.isEmpty ? "\(avCode).mp4" : fileLast,
                avCatalogCode: avCode,
                parsed: parsed,
                isAdultVideo: true
            )
        }

        let episodeToken = episodeQuerySuffix(season: parsed.season, episode: parsed.episode)
        var queries: [String] = []
        for base in parsed.searchTitles {
            if let ep = episodeToken {
                queries.append("\(base) \(ep)")
            }
            queries.append(base)
        }
        if queries.isEmpty, !parseSource.isEmpty {
            queries.append(parseSource)
        }
        let uniqueQueries = Array(uniqueNonEmpty(queries).prefix(4))
        let display = uniqueQueries.first ?? parsed.title
        let shooterName: String = {
            if !fileLast.isEmpty, fileLast != "stream", !fileLast.lowercased().hasSuffix(".m3u8") {
                return fileLast
            }
            return display.isEmpty ? "video.mkv" : "\(display).mkv"
        }()

        return SubtitleQueryPlan(
            displayQuery: display,
            xunleiQueries: uniqueQueries,
            shooterFileName: shooterName,
            avCatalogCode: nil,
            parsed: parsed,
            isAdultVideo: isAdultHint
        )
    }

    private static func episodeQuerySuffix(season: Int?, episode: Int?) -> String? {
        if let season, let episode {
            return String(format: "S%02dE%02d", season, episode)
        }
        if let episode {
            return String(format: "E%02d", episode)
        }
        return nil
    }

    private static func uniqueNonEmpty(_ items: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

// MARK: - 字幕文本编码转换与合法性校验

// MARK: - 开源 CJK 字幕字体管理

/// 把随包内置的思源黑体（Noto Sans SC，SIL OFL 1.1）注册到进程级 CoreText，
/// 并复制到只包含字体文件的独立缓存目录供 mpv / libass 直接加载，避免 iOS 沙盒缺字与回退卡顿。
enum SubtitleFontManager {
    static let defaultFontName = "Noto Sans SC"
    static let bundledFontFileName = "NotoSansSC-Regular"
    static let bundledFontExtension = "otf"
    static let directoryName = "HPlayerSubtitleFonts"

    private static let lock = NSLock()
    private static var preparedDirectory: URL?
    private static var registeredFontURLs: Set<URL> = []

    static func bundledFontURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: bundledFontFileName, withExtension: bundledFontExtension)
            ?? bundle.url(forResource: bundledFontFileName, withExtension: bundledFontExtension, subdirectory: "SubtitleFonts")
    }

    @discardableResult
    static func prepareSubtitleFontDirectory(
        in bundle: Bundle = .main,
        cacheRoot: URL? = nil
    ) -> URL? {
        guard let sourceURL = bundledFontURL(in: bundle) else { return nil }
        registerProcessFontIfNeeded(at: sourceURL)

        let targetFileName = "\(bundledFontFileName).\(bundledFontExtension)"
        if cacheRoot == nil {
            lock.lock()
            let cached = preparedDirectory
            lock.unlock()
            if let cached,
               FileManager.default.fileExists(atPath: cached.appendingPathComponent(targetFileName).path) {
                return cached
            }
        }

        let fm = FileManager.default
        guard let root = cacheRoot ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fontDir = root.appendingPathComponent(directoryName, isDirectory: true)
        try? fm.createDirectory(at: fontDir, withIntermediateDirectories: true)

        if let existing = try? fm.contentsOfDirectory(at: fontDir, includingPropertiesForKeys: nil) {
            for item in existing where item.lastPathComponent != targetFileName {
                try? fm.removeItem(at: item)
            }
        }

        let targetURL = fontDir.appendingPathComponent(targetFileName)
        let sourceSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value
        let targetSize = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.int64Value
        if !fm.fileExists(atPath: targetURL.path) || (sourceSize != nil && sourceSize != targetSize) {
            if let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe) {
                try? data.write(to: targetURL, options: .atomic)
            } else {
                try? fm.removeItem(at: targetURL)
                try? fm.copyItem(at: sourceURL, to: targetURL)
            }
        }

        guard fm.fileExists(atPath: targetURL.path) else { return nil }
        registerProcessFontIfNeeded(at: targetURL)
        if cacheRoot == nil {
            lock.lock()
            preparedDirectory = fontDir
            lock.unlock()
        }
        return fontDir
    }

    private static func registerProcessFontIfNeeded(at url: URL) {
        let standardized = url.standardizedFileURL
        lock.lock()
        let alreadyRegistered = registeredFontURLs.contains(standardized)
        if !alreadyRegistered {
            registeredFontURLs.insert(standardized)
        }
        lock.unlock()
        guard !alreadyRegistered else { return }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(standardized as CFURL, .process, &error)
    }
}

enum SubtitleTextDecoder {
    private static let commonChineseScalars: Set<Unicode.Scalar> = Set(
        ("的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严" +
         "這為說國時過產面經動會學們來發對進開關問實沒樣給看還讓與無麼體畫邊聽嗎呢啊吧見長從電門車東風書問認話請買賣頭車親愛快樂點後點兒" +
         "，。！？：；“”‘’（）【】《》")
            .unicodeScalars
    )

    private static let blurClampRegex = try? NSRegularExpression(pattern: #"\\(blur|be)([0-9]+(?:\.[0-9]+)?)"#)
    private static let fontTagRegex = try? NSRegularExpression(pattern: #"\\fn[^\\}]+"#)

    /// 将下载的字幕原始字节自适应解码为标准字符串（兼容 UTF-8 / UTF-16 / GB18030 / Big5 / Shift-JIS）。
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { return nil }
        // 拒绝 ZIP 等压缩包二进制与 HTML 错误页
        if data.count >= 2, data[0] == 0x50, data[1] == 0x4B { return nil }

        // 1. UTF-8 BOM
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let body = data.dropFirst(3)
            if let text = String(data: body, encoding: .utf8) {
                let clean = cleanDecodedControlChars(stripBOM(text))
                if looksLikeSubtitle(clean) { return clean }
            }
        }

        // 2. UTF-16 BOM
        if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF) {
            if let text = String(data: data, encoding: .utf16) {
                let clean = cleanDecodedControlChars(stripBOM(text))
                if looksLikeSubtitle(clean) { return clean }
            }
        }

        // 3. 无 BOM UTF-16LE / UTF-16BE 检测：优先拦截防止被 .utf8 吞入一堆 \0
        if let probableUTF16 = detectUTF16WithoutBOM(data),
           let text = String(data: data, encoding: probableUTF16) {
            let clean = cleanDecodedControlChars(stripBOM(text))
            if looksLikeSubtitle(clean) { return clean }
        }

        // 4. 标准无 BOM UTF-8（拒绝含 NUL 字节和大量替换符的结果）
        if !data.prefix(2048).contains(0),
           let utf8 = String(data: data, encoding: .utf8) {
            let clean = stripBOM(utf8)
            if !clean.contains("\u{FFFD}"), looksLikeSubtitle(clean) {
                return cleanDecodedControlChars(clean)
            }
        }

        // 5. 多字节 CJK 竞争评分（避免范围更广的 GB18030 无条件吞掉 Big5 繁体导致乱码）
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let cjkCandidates: [String.Encoding] = [gb18030, big5, .shiftJIS]

        var bestCJK: (text: String, score: Int)?
        for encoding in cjkCandidates {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let clean = cleanDecodedControlChars(stripBOM(decoded))
            guard looksLikeSubtitle(clean) else { continue }
            let score = scoreCJKSubtitleReadability(clean, encodingIsShiftJIS: encoding == .shiftJIS)
            if let current = bestCJK {
                if score > current.score { bestCJK = (clean, score) }
            } else {
                bestCJK = (clean, score)
            }
        }
        if let bestCJK {
            return bestCJK.text
        }

        // 6. 其余 UTF-16LE/BE 与西文兜底
        for encoding: String.Encoding in [.utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1] {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let clean = cleanDecodedControlChars(stripBOM(text))
            if looksLikeSubtitle(clean) {
                return clean
            }
        }
        return nil
    }

    static func looksLikeSubtitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let head = String(trimmed.prefix(300)).lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.contains("<body") {
            return false
        }
        if trimmed.contains("-->") { return true }
        if trimmed.contains("[Script Info]") || trimmed.contains("Dialogue:") { return true }
        if head.hasPrefix("webvtt") { return true }
        if head.contains("<sami") || trimmed.range(of: #"(?i)<sync\s+start="#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"\d{1,2}:\d{2}:\d{2}[,.]\d{2,3}"#, options: .regularExpression) != nil
    }

    /// 为 mpv/libass 播放准备干净文本：规范换行并清理 ASS 内嵌大二进制字体与缺失桌面字体声明。
    static func sanitizeForPlayback(
        _ text: String,
        format: String,
        defaultFontName: String = SubtitleFontManager.defaultFontName
    ) -> String {
        var normalized = cleanDecodedControlChars(stripBOM(text))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lowerExt = format.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        let lowerHead = String(normalized.prefix(1024)).lowercased()
        let isASS = lowerExt == "ass" || lowerExt == "ssa"
            || lowerHead.contains("[script info]")
            || lowerHead.contains("[v4+ styles]")
            || lowerHead.contains("[v4 styles]")

        guard isASS else { return normalized }
        normalized = sanitizeASSSubtitle(normalized, defaultFontName: defaultFontName)
        return normalized
    }

    private static func sanitizeASSSubtitle(_ text: String, defaultFontName: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)

        var section = ""
        var fontNameColumn = 1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                if section == "[fonts]" || section == "[graphics]" {
                    continue
                }
                if section == "[v4+ styles]" || section == "[v4 styles]" {
                    fontNameColumn = 1
                }
                output.append(line)
                continue
            }

            if section == "[fonts]" || section == "[graphics]" {
                continue
            }

            if (section == "[v4+ styles]" || section == "[v4 styles]") {
                if let range = trimmed.range(of: "format:", options: [.caseInsensitive, .anchored]) {
                    let cols = trimmed[range.upperBound...]
                        .split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    if let idx = cols.firstIndex(of: "fontname") {
                        fontNameColumn = idx
                    }
                    output.append(line)
                    continue
                }
                if let range = trimmed.range(of: "style:", options: [.caseInsensitive, .anchored]) {
                    let prefix = String(trimmed[..<range.upperBound])
                    let body = String(trimmed[range.upperBound...])
                    let leadingSpaces = body.prefix { $0 == " " || $0 == "\t" }
                    let trimmedBody = body.dropFirst(leadingSpaces.count)
                    var fields = trimmedBody.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    if fields.indices.contains(fontNameColumn) {
                        fields[fontNameColumn] = defaultFontName
                    }
                    output.append(prefix + String(leadingSpaces) + fields.joined(separator: ","))
                    continue
                }
            }

            if trimmed.lowercased().hasPrefix("dialogue:") {
                output.append(sanitizeASSDialogueTags(in: line, defaultFontName: defaultFontName))
                continue
            }

            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func sanitizeASSDialogueTags(in line: String, defaultFontName: String) -> String {
        guard line.contains("{") else { return line }
        var result = ""
        result.reserveCapacity(line.count)
        var cursor = line.startIndex

        while let open = line[cursor...].firstIndex(of: "{") {
            result.append(contentsOf: line[cursor..<open])
            guard let close = line[open...].firstIndex(of: "}") else {
                result.append(contentsOf: line[open...])
                return result
            }
            var tagBlock = String(line[open...close])
            if tagBlock.contains(#"\fn"#), let fontTagRegex {
                let mutable = NSMutableString(string: tagBlock)
                let matches = fontTagRegex.matches(in: tagBlock, range: NSRange(location: 0, length: mutable.length))
                for match in matches.reversed() {
                    mutable.replaceCharacters(in: match.range, with: "\\fn\(defaultFontName)")
                }
                tagBlock = mutable as String
            }
            if (tagBlock.contains(#"\blur"#) || tagBlock.contains(#"\be"#)), let blurClampRegex {
                let mutable = NSMutableString(string: tagBlock)
                let matches = blurClampRegex.matches(in: tagBlock, range: NSRange(location: 0, length: mutable.length))
                for match in matches.reversed() {
                    guard match.numberOfRanges >= 3 else { continue }
                    let cmd = mutable.substring(with: match.range(at: 1))
                    let valStr = mutable.substring(with: match.range(at: 2))
                    if let value = Double(valStr), value > 4.0 {
                        mutable.replaceCharacters(in: match.range, with: "\\\(cmd)4")
                    }
                }
                tagBlock = mutable as String
            }
            result.append(tagBlock)
            cursor = line.index(after: close)
        }
        result.append(contentsOf: line[cursor...])
        return result
    }

    private static func detectUTF16WithoutBOM(_ data: Data) -> String.Encoding? {
        let sampleCount = min(data.count, 1024)
        guard sampleCount >= 8 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        let pairs = sampleCount / 2
        for i in 0..<pairs {
            if data[i * 2] == 0 { evenZeros += 1 }
            if data[i * 2 + 1] == 0 { oddZeros += 1 }
        }
        let evenRatio = Double(evenZeros) / Double(pairs)
        let oddRatio = Double(oddZeros) / Double(pairs)
        if oddRatio >= 0.25 && evenRatio <= 0.05 { return .utf16LittleEndian }
        if evenRatio >= 0.25 && oddRatio <= 0.05 { return .utf16BigEndian }
        return nil
    }

    private static func scoreCJKSubtitleReadability(_ text: String, encodingIsShiftJIS: Bool) -> Int {
        var score = 0
        var nonASCIICount = 0
        var kanaCount = 0

        for scalar in text.unicodeScalars where nonASCIICount < 6000 {
            let v = scalar.value
            if v <= 0x7F {
                if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D {
                    score -= 25
                }
                continue
            }
            nonASCIICount += 1
            if v == 0xFFFD || (0xE000...0xF8FF).contains(v) {
                score -= 30
            } else if commonChineseScalars.contains(scalar) {
                score += 6
            } else if (0x3040...0x30FF).contains(v) {
                kanaCount += 1
                score += 3
            } else if (0x4E00...0x9FFF).contains(v) {
                score += 1
            } else if (0x3400...0x4DBF).contains(v) || (0xFF61...0xFF9F).contains(v) {
                // CJK 扩展 A 与半角片假名常在错误解码的 GBK/Big5/Shift-JIS 乱码中高频出现
                score -= 4
            } else if (0x0400...0x04FF).contains(v) || (0x2500...0x257F).contains(v) {
                // GBK/Shift-JIS 错解时常落在俄文字母或制表符区域
                score -= 5
            }
        }

        if encodingIsShiftJIS && nonASCIICount > 20 && kanaCount * 10 < nonASCIICount {
            // 日文文本几乎必然包含至少 10% 假名，纯中文误用 Shift-JIS 会掉入生僻汉字与制表符
            score -= 80
        }
        return score
    }

    private static func cleanDecodedControlChars(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0000}", with: "")
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}

// MARK: - 磁盘缓存

@MainActor
final class OnlineSubtitleCache {
    static let shared = OnlineSubtitleCache()

    struct CachedSelection: Codable {
        let candidate: OnlineSubtitleCandidate
        let fileName: String
        let delaySeconds: Double
        let updatedAt: Date
    }

    private let directory: URL
    private let indexURL: URL
    private let delaysURL: URL
    private let versionMarkerURL: URL
    private var selections: [String: CachedSelection] = [:]
    private var delays: [String: Double] = [:]
    private static let maxStoredFiles = 80
    private static let versionMarkerName = ".format-v2"

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HPlayerOnlineSubtitles", isDirectory: true)
        self.directory = dir
        self.indexURL = dir.appendingPathComponent("selections.json")
        self.delaysURL = dir.appendingPathComponent("delays.json")
        self.versionMarkerURL = dir.appendingPathComponent(Self.versionMarkerName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadIndex()
        migrateCacheVersionIfNeeded()
    }

    static func videoKey(streamID: String?, url: URL, title: String) -> String {
        if let streamID, !streamID.isEmpty { return "sid|\(streamID)" }
        if url.isFileURL { return "file|\(url.lastPathComponent)|\(title)" }
        let base = url.host ?? ""
        return "url|\(base)|\(url.path)|\(title)"
    }

    func cachedFile(for candidate: OnlineSubtitleCandidate) -> URL? {
        let ext = sanitizedExtension(candidate.format)
        let target = directory.appendingPathComponent("\(candidateKey(candidate)).\(ext)")
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    func saveSubtitleText(_ text: String, for candidate: OnlineSubtitleCandidate) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sanitizedExtension(candidate.format)
        let sanitized = SubtitleTextDecoder.sanitizeForPlayback(text, format: ext)
        let target = directory.appendingPathComponent("\(candidateKey(candidate)).\(ext)")
        guard let data = sanitized.data(using: .utf8) else { return nil }
        do {
            try data.write(to: target, options: .atomic)
            trimOldFilesIfNeeded()
            return target
        } catch {
            return nil
        }
    }

    func savedSelection(for videoKey: String) -> (selection: CachedSelection, fileURL: URL)? {
        guard let entry = selections[videoKey] else { return nil }
        let fileURL = directory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            selections.removeValue(forKey: videoKey)
            saveIndex()
            return nil
        }
        return (entry, fileURL)
    }

    func rememberSelection(_ candidate: OnlineSubtitleCandidate, fileURL: URL, delaySeconds: Double, for videoKey: String) {
        selections[videoKey] = CachedSelection(
            candidate: candidate,
            fileName: fileURL.lastPathComponent,
            delaySeconds: delaySeconds,
            updatedAt: Date()
        )
        saveIndex()
    }

    func savedDelay(for videoKey: String) -> Double? {
        delays[videoKey] ?? selections[videoKey]?.delaySeconds
    }

    func updateDelay(_ delaySeconds: Double, for videoKey: String) {
        if abs(delaySeconds) < 0.05 {
            delays.removeValue(forKey: videoKey)
        } else {
            delays[videoKey] = delaySeconds
        }
        saveDelays()
        if let existing = selections[videoKey] {
            selections[videoKey] = CachedSelection(
                candidate: existing.candidate,
                fileName: existing.fileName,
                delaySeconds: delaySeconds,
                updatedAt: Date()
            )
            saveIndex()
        }
    }

    var cachedFileCount: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return files.filter { !Self.isMetadataFile($0) }.count
    }

    var cachedByteCount: Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for url in urls where !Self.isMetadataFile(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: versionMarkerURL, options: .atomic)
        selections = [:]
        delays = [:]
    }

    private static func isMetadataFile(_ name: String) -> Bool {
        name == "selections.json" || name == "delays.json" || name == versionMarkerName
    }

    private func migrateCacheVersionIfNeeded() {
        guard !FileManager.default.fileExists(atPath: versionMarkerURL.path) else { return }
        if let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in urls where !Self.isMetadataFile(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !selections.isEmpty {
            selections = [:]
            saveIndex()
        }
        try? Data().write(to: versionMarkerURL, options: .atomic)
    }

    private func candidateKey(_ candidate: OnlineSubtitleCandidate) -> String {
        let digest = Insecure.SHA1.hash(data: Data(candidate.id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizedExtension(_ ext: String) -> String {
        let clean = ext.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        switch clean {
        case "ass", "ssa", "srt", "vtt", "smi": return clean
        default: return "srt"
        }
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: CachedSelection].self, from: data) {
            selections = decoded
        }
        if let delayData = try? Data(contentsOf: delaysURL),
           let decodedDelays = try? JSONDecoder().decode([String: Double].self, from: delayData) {
            delays = decodedDelays
        }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(selections) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func saveDelays() {
        guard let data = try? JSONEncoder().encode(delays) else { return }
        try? data.write(to: delaysURL, options: .atomic)
    }

    private func trimOldFilesIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return
        }
        let subtitleFiles = urls.filter { !Self.isMetadataFile($0.lastPathComponent) }
        guard subtitleFiles.count > Self.maxStoredFiles else { return }
        let sorted = subtitleFiles.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 < d1
        }
        for url in sorted.prefix(subtitleFiles.count - Self.maxStoredFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 多源免费在线字幕检索与下载服务

actor OnlineSubtitleService {
    static let shared = OnlineSubtitleService()

    private let session: URLSession
    private let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    private let enabledSourcesProvider: @Sendable () -> [OnlineSubtitleSource]

    init(
        session: URLSession = .shared,
        enabledSourcesProvider: @escaping @Sendable () -> [OnlineSubtitleSource] = { OnlineSubtitlePrefs.enabledSources }
    ) {
        self.session = session
        self.enabledSourcesProvider = enabledSourcesProvider
    }

    /// 综合检索视频的免费外挂字幕（支持文件指纹哈希 + 片名/剧集 + AV 番号）。
    func search(
        context: OnlineSubtitleContext,
        fingerprint: VideoSubtitleFingerprint?,
        manualQuery: String? = nil
    ) async -> (query: String, candidates: [OnlineSubtitleCandidate]) {
        let plan = SubtitleQueryBuilder.build(
            rawTitle: context.rawTitle,
            streamURL: context.streamURL,
            fallbackIdentifier: context.fallbackIdentifier,
            isAdultHint: context.isAdultVideo,
            manualQuery: manualQuery
        )

        let enabled = Set(enabledSourcesProvider())
        guard !enabled.isEmpty else { return (plan.displayQuery, []) }

        var rawResults: [OnlineSubtitleCandidate] = []

        await withTaskGroup(of: [OnlineSubtitleCandidate].self) { group in
            if enabled.contains(.xunlei) {
                group.addTask {
                    await self.searchXunlei(plan: plan, fingerprint: fingerprint)
                }
            }
            if enabled.contains(.shooter), !plan.isAdultVideo || fingerprint?.shooterHash != nil {
                group.addTask {
                    await self.searchShooter(plan: plan, fingerprint: fingerprint)
                }
            }
            if enabled.contains(.subtitlecat), plan.isAdultVideo || manualQuery != nil {
                group.addTask {
                    await self.searchSubtitleCat(plan: plan)
                }
            }
            if enabled.contains(.opensubtitles), !plan.isAdultVideo {
                group.addTask {
                    await self.searchOpenSubtitles(
                        plan: plan,
                        fingerprint: fingerprint,
                        explicitIMDBID: context.imdbID
                    )
                }
            }
            for await partial in group {
                rawResults.append(contentsOf: partial)
            }
        }

        // 若常规电影/剧集三源均未搜到中文字幕且尚未查过 SubtitleCat，补充兜底一次
        if !plan.isAdultVideo,
           manualQuery == nil,
           enabled.contains(.subtitlecat),
           !rawResults.contains(where: \.isChinese) {
            let fallback = await searchSubtitleCat(plan: plan)
            rawResults.append(contentsOf: fallback)
        }

        let ranked = Self.rankAndDeduplicate(
            rawResults,
            plan: plan,
            videoDuration: context.durationSeconds
        )
        return (plan.displayQuery, ranked)
    }

    /// 下载字幕内容并自适应转码为 UTF-8，不合法的网页错误页会被丢弃。
    func downloadSubtitleText(from candidate: OnlineSubtitleCandidate) async -> String? {
        var request = URLRequest(url: candidate.downloadURL)
        request.timeoutInterval = 8
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if candidate.source == .subtitlecat {
            request.setValue("https://www.subtitlecat.com/", forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if mime.contains("text/html") { return nil }
        return SubtitleTextDecoder.decode(data)
    }

    /// 从排好序的候选中按优先级挑出适合自动挂载的若干条（优先中文字幕，其次哈希精确命中），
    /// 以便首选外链失效时静默顺延尝试下一条。
    static func autoPickCandidates(from candidates: [OnlineSubtitleCandidate], limit: Int = 3) -> [OnlineSubtitleCandidate] {
        guard limit > 0 else { return [] }
        let chinese = candidates.filter(\.isChinese)
        if !chinese.isEmpty {
            return Array(chinese.prefix(limit))
        }
        return Array(candidates.filter(\.matchedByHash).prefix(limit))
    }

    /// 从排好序的候选中挑选最适合自动挂载的一条（只接受中文字幕或哈希精确命中）。
    static func autoPick(from candidates: [OnlineSubtitleCandidate]) -> OnlineSubtitleCandidate? {
        autoPickCandidates(from: candidates, limit: 1).first
    }

    // MARK: 1. 迅雷字幕库（Hash CID + 片名/番号）

    private func searchXunlei(
        plan: SubtitleQueryPlan,
        fingerprint: VideoSubtitleFingerprint?
    ) async -> [OnlineSubtitleCandidate] {
        var urls: [(url: URL, byHash: Bool)] = []
        if let cid = fingerprint?.xunleiCID,
           var comp = URLComponents(string: "https://api-shoulei-ssl.xunlei.com/oracle/subtitle") {
            comp.queryItems = [URLQueryItem(name: "cid", value: cid)]
            if let url = comp.url { urls.append((url, true)) }
        }
        for query in plan.xunleiQueries.prefix(2) {
            if var comp = URLComponents(string: "https://api-shoulei-ssl.xunlei.com/oracle/subtitle") {
                comp.queryItems = [URLQueryItem(name: "name", value: query)]
                if let url = comp.url { urls.append((url, false)) }
            }
        }

        var items: [OnlineSubtitleCandidate] = []
        for entry in urls {
            var req = URLRequest(url: entry.url)
            req.timeoutInterval = 6
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let page = try? JSONDecoder().decode(XunleiResponse.self, from: data),
                  let records = page.data else { continue }

            for record in records.prefix(20) {
                guard let urlStr = record.url, let downloadURL = URL(string: urlStr) else { continue }
                let ext = (record.ext ?? downloadURL.pathExtension).lowercased()
                guard Self.supportedFormats.contains(ext) else { continue }

                let rawName = (record.name?.isEmpty == false ? record.name : record.simpleName) ?? "在线字幕"
                let lang = Self.classifyLanguage(
                    hints: record.languages ?? [],
                    fileName: "\(rawName) \(record.simpleName ?? "")"
                )
                let dur = (record.duration ?? 0) > 0 ? Double(record.duration!) / 1000.0 : nil
                let id = "xunlei|\(downloadURL.absoluteString)"
                items.append(OnlineSubtitleCandidate(
                    id: id,
                    title: rawName,
                    languageLabel: lang,
                    format: ext,
                    source: .xunlei,
                    downloadURL: downloadURL,
                    matchedByHash: entry.byHash,
                    durationSeconds: dur,
                    score: entry.byHash ? 200 : 0
                ))
            }
        }
        return items
    }

    private struct XunleiResponse: Decodable {
        let code: Int?
        let data: [Item]?

        struct Item: Decodable {
            let url: String?
            let ext: String?
            let name: String?
            let simpleName: String?
            let duration: Int64?
            let languages: [String]?

            enum CodingKeys: String, CodingKey {
                case url, ext, name, duration, languages
                case simpleName = "simple_name"
            }
        }
    }

    // MARK: 2. SubtitleCat（重点覆盖 AV 番号 + 免 Token 直链 .srt）

    private func searchSubtitleCat(plan: SubtitleQueryPlan) async -> [OnlineSubtitleCandidate] {
        guard let searchTerm = plan.avCatalogCode ?? plan.xunleiQueries.first,
              !searchTerm.isEmpty,
              var comp = URLComponents(string: "https://www.subtitlecat.com/index.php") else {
            return []
        }
        comp.queryItems = [URLQueryItem(name: "search", value: searchTerm)]
        guard let searchURL = comp.url else { return [] }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 7
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        let entries = Self.parseSubtitleCatSearchHTML(html, expectedCode: plan.avCatalogCode, query: searchTerm)
        guard !entries.isEmpty else { return [] }

        // 并发抓取排名前 3 个详情页拿 zh-CN / zh-TW 直链
        var results: [OnlineSubtitleCandidate] = []
        await withTaskGroup(of: [OnlineSubtitleCandidate].self) { group in
            for entry in entries.prefix(3) {
                group.addTask {
                    await self.fetchSubtitleCatDetail(entry: entry)
                }
            }
            for await list in group {
                results.append(contentsOf: list)
            }
        }
        return results
    }

    private func fetchSubtitleCatDetail(entry: SubtitleCatSearchRow) async -> [OnlineSubtitleCandidate] {
        guard let detailURL = Self.safeSubtitleCatURL(path: entry.detailPath) else { return [] }
        var req = URLRequest(url: detailURL)
        req.timeoutInterval = 7
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.subtitlecat.com/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        var bonus = 0
        if entry.fromChinese { bonus += 160 }
        if entry.thumbUp { bonus += 60 }
        bonus += min(entry.downloads, 50)

        var candidates: [OnlineSubtitleCandidate] = []
        let targets: [(id: String, label: String, langBonus: Int)] = [
            ("download_zh-CN", "简体中文", 40),
            ("download_zh-TW", "繁体中文", 20),
        ]
        for target in targets {
            if let href = Self.extractDownloadHref(id: target.id, in: html),
               let downloadURL = Self.safeSubtitleCatURL(path: href) {
                let id = "subtitlecat|\(downloadURL.absoluteString)"
                candidates.append(OnlineSubtitleCandidate(
                    id: id,
                    title: "\(entry.title) (\(target.label))",
                    languageLabel: target.label,
                    format: "srt",
                    source: .subtitlecat,
                    downloadURL: downloadURL,
                    matchedByHash: false,
                    durationSeconds: nil,
                    score: bonus + target.langBonus
                ))
            }
        }
        return candidates
    }

    struct SubtitleCatSearchRow {
        let title: String
        let detailPath: String
        let fromChinese: Bool
        let thumbUp: Bool
        let downloads: Int
    }

    static func parseSubtitleCatSearchHTML(_ html: String, expectedCode: String?, query: String) -> [SubtitleCatSearchRow] {
        guard let rowRegex = try? NSRegularExpression(pattern: #"<tr\b[^>]*>(.*?)</tr>"#, options: [.dotMatchesLineSeparators]),
              let linkRegex = try? NSRegularExpression(pattern: #"<a\s+href="([^"]*subs/[^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsHTML = html as NSString
        var rows: [SubtitleCatSearchRow] = []

        for match in rowRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let rowHTML = nsHTML.substring(with: match.range(at: 1))
            let nsRow = rowHTML as NSString
            guard let linkMatch = linkRegex.firstMatch(in: rowHTML, range: NSRange(location: 0, length: nsRow.length)) else {
                continue
            }
            let href = nsRow.substring(with: linkMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = nsRow.substring(with: linkMatch.range(at: 2))
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !rawTitle.isEmpty else { continue }

            // 严格核对 AV 番号或常规关键词，防止搜出毫不相干的结果
            if let expectedCode {
                let normExpected = compactAlphaNum(expectedCode)
                let normTitle = compactAlphaNum(rawTitle)
                guard normTitle.contains(normExpected) else { continue }
            } else {
                let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
                if !tokens.isEmpty {
                    let normTitle = rawTitle.lowercased()
                    guard tokens.contains(where: { normTitle.contains($0) }) else { continue }
                }
            }

            let lowerRow = rowHTML.lowercased()
            let fromChinese = lowerRow.contains("translated from chinese")
            let thumbUp = rowHTML.contains("👍")
            let downloads: Int = {
                guard let dlRegex = try? NSRegularExpression(pattern: #"(\d+)\s*<span[^>]*>\s*downloads"#, options: .caseInsensitive),
                      let dlMatch = dlRegex.firstMatch(in: rowHTML, range: NSRange(location: 0, length: nsRow.length)),
                      let numRange = Range(dlMatch.range(at: 1), in: rowHTML) else { return 0 }
                return Int(rowHTML[numRange]) ?? 0
            }()
            rows.append(SubtitleCatSearchRow(
                title: rawTitle,
                detailPath: href,
                fromChinese: fromChinese,
                thumbUp: thumbUp,
                downloads: downloads
            ))
        }

        return rows.sorted { lhs, rhs in
            let lScore = (lhs.fromChinese ? 1000 : 0) + (lhs.thumbUp ? 200 : 0) + lhs.downloads
            let rScore = (rhs.fromChinese ? 1000 : 0) + (rhs.thumbUp ? 200 : 0) + rhs.downloads
            return lScore > rScore
        }
    }

    static func extractDownloadHref(id: String, in html: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let patterns = [
            #"<a[^>]*\bid=["']"# + escapedID + #"["'][^>]*\bhref=["']([^"']+)["']"#,
            #"<a[^>]*\bhref=["']([^"']+)["'][^>]*\bid=["']"# + escapedID + #"["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                  let range = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func safeSubtitleCatURL(path: String) -> URL? {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        if let url = URL(string: "https://www.subtitlecat.com\(normalized)") {
            return url
        }
        let decoded = normalized.removingPercentEncoding ?? normalized
        guard let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://www.subtitlecat.com\(encoded)")
    }

    // MARK: 3. 射手网（Shooter 4 点 Hash + 文件名）

    private func searchShooter(
        plan: SubtitleQueryPlan,
        fingerprint: VideoSubtitleFingerprint?
    ) async -> [OnlineSubtitleCandidate] {
        let hash = fingerprint?.shooterHash ?? ""
        let pathInfo = plan.shooterFileName
        guard !hash.isEmpty || !pathInfo.isEmpty else { return [] }
        guard let endpoint = URL(string: "https://www.shooter.cn/api/subapi.php") else { return [] }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var bodyItems = [
            URLQueryItem(name: "pathinfo", value: pathInfo),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "lang", value: "chn"),
        ]
        if !hash.isEmpty {
            bodyItems.insert(URLQueryItem(name: "filehash", value: hash), at: 0)
        }
        var comp = URLComponents()
        comp.queryItems = bodyItems
        req.httpBody = comp.percentEncodedQuery?.data(using: .utf8)

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty,
              let entries = try? JSONDecoder().decode([ShooterEntry].self, from: data) else {
            return []
        }

        let byHash = !hash.isEmpty
        var items: [OnlineSubtitleCandidate] = []
        for (idx, entry) in entries.prefix(12).enumerated() {
            for file in entry.files ?? [] {
                guard let link = file.link, let downloadURL = URL(string: link) else { continue }
                let ext = (file.ext ?? "srt").lowercased()
                guard Self.supportedFormats.contains(ext) else { continue }
                let desc = entry.desc?.trimmingCharacters(in: .whitespacesAndNewlines)
                let labelTitle = (desc?.isEmpty == false ? desc! : "\(plan.displayQuery) 字幕 \(idx + 1)")
                let lang = Self.classifyLanguage(hints: [], fileName: labelTitle)
                items.append(OnlineSubtitleCandidate(
                    id: "shooter|\(downloadURL.absoluteString)",
                    title: labelTitle,
                    languageLabel: lang == "未知" ? "中文" : lang,
                    format: ext,
                    source: .shooter,
                    downloadURL: downloadURL,
                    matchedByHash: byHash,
                    durationSeconds: nil,
                    score: byHash ? 200 : 0
                ))
            }
        }
        return items
    }

    private struct ShooterEntry: Decodable {
        let desc: String?
        let delay: Int?
        let files: [FileItem]?

        enum CodingKeys: String, CodingKey {
            case desc = "Desc"
            case delay = "Delay"
            case files = "Files"
        }

        struct FileItem: Decodable {
            let ext: String?
            let link: String?

            enum CodingKeys: String, CodingKey {
                case ext = "Ext"
                case link = "Link"
            }
        }
    }

    // MARK: 4. OpenSubtitles v3 Stremio（IMDb ID / Cinemeta + MovieHash）

    private func searchOpenSubtitles(
        plan: SubtitleQueryPlan,
        fingerprint: VideoSubtitleFingerprint?,
        explicitIMDBID: String?
    ) async -> [OnlineSubtitleCandidate] {
        let resolvedIMDB: String?
        if let explicitIMDBID, explicitIMDBID.hasPrefix("tt") {
            resolvedIMDB = explicitIMDBID
        } else {
            resolvedIMDB = await lookupIMDBID(plan: plan)
        }
        guard let imdb = resolvedIMDB else { return [] }

        let isSeries = plan.parsed.looksLikeSeries
        let mediaType = isSeries ? "series" : "movie"
        let mediaID: String = {
            guard isSeries else { return imdb }
            let season = plan.parsed.season ?? 1
            let episode = plan.parsed.episode ?? 1
            return "\(imdb):\(season):\(episode)"
        }()

        var extras: [String] = []
        if let hash = fingerprint?.openSubHash, let size = fingerprint?.fileSize {
            extras.append("videoHash=\(hash)")
            extras.append("videoSize=\(size)")
        }
        if !plan.shooterFileName.isEmpty,
           let encodedName = plan.shooterFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            extras.append("filename=\(encodedName)")
        }

        let endpointString: String
        if extras.isEmpty {
            endpointString = "https://opensubtitles-v3.strem.io/subtitles/\(mediaType)/\(mediaID).json"
        } else {
            endpointString = "https://opensubtitles-v3.strem.io/subtitles/\(mediaType)/\(mediaID)/\(extras.joined(separator: "&")).json"
        }
        guard let url = URL(string: endpointString) else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 7
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let page = try? JSONDecoder().decode(OpenSubResponse.self, from: data) else {
            return []
        }

        var items: [OnlineSubtitleCandidate] = []
        for sub in page.subtitles {
            guard let downloadURL = URL(string: sub.url) else { continue }
            let rawLang = sub.lang.lowercased()
            let langLabel = Self.mapOpenSubLanguage(rawLang, fileName: sub.subtitleFileName ?? "")
            let isPreferred = ["zho", "chi", "chs", "cht", "zh", "zh-cn", "zh-tw", "zh-hk", "eng", "jpn"].contains(rawLang)
            guard isPreferred else { continue }

            let name = sub.subtitleFileName ?? sub.movieReleaseName ?? "\(plan.displayQuery).srt"
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            let format = Self.supportedFormats.contains(ext) ? ext : "srt"
            let hashMatch = sub.m?.lowercased() == "h"

            items.append(OnlineSubtitleCandidate(
                id: "opensub|\(sub.id)|\(downloadURL.absoluteString)",
                title: name,
                languageLabel: langLabel,
                format: format,
                source: .opensubtitles,
                downloadURL: downloadURL,
                matchedByHash: hashMatch,
                durationSeconds: nil,
                score: hashMatch ? 220 : 0
            ))
        }
        return items
    }

    private func lookupIMDBID(plan: SubtitleQueryPlan) async -> String? {
        guard let query = plan.parsed.latinTitle ?? plan.parsed.searchTitles.first,
              !query.isEmpty else { return nil }
        let catalogType = plan.parsed.looksLikeSeries ? "series" : "movie"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(catalogType)/top/search=\(encoded).json") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let page = try? JSONDecoder().decode(CinemetaSearchResponse.self, from: data) else {
            return nil
        }

        let targetKey = MediaNameParser.cacheKey(query)
        let exact = page.metas.first { meta in
            let metaKey = MediaNameParser.cacheKey(meta.name)
            return metaKey == targetKey || metaKey.contains(targetKey) || targetKey.contains(metaKey)
        }
        let chosen = exact ?? page.metas.first
        let id = chosen?.imdbId ?? chosen?.id
        return (id?.hasPrefix("tt") == true) ? id : nil
    }

    private struct CinemetaSearchResponse: Decodable {
        let metas: [Meta]
        struct Meta: Decodable {
            let id: String
            let imdbId: String?
            let name: String
            enum CodingKeys: String, CodingKey {
                case id, name
                case imdbId = "imdb_id"
            }
        }
    }

    private struct OpenSubResponse: Decodable {
        let subtitles: [Item]
        struct Item: Decodable {
            let id: String
            let url: String
            let lang: String
            let m: String?
            let subtitleFileName: String?
            let movieReleaseName: String?
        }
    }

    // MARK: - 排序、语言分类与去重

    private static let supportedFormats: Set<String> = ["srt", "ass", "ssa", "vtt", "smi"]

    static func rankAndDeduplicate(
        _ items: [OnlineSubtitleCandidate],
        plan: SubtitleQueryPlan,
        videoDuration: Double?
    ) -> [OnlineSubtitleCandidate] {
        var dedup: [String: OnlineSubtitleCandidate] = [:]
        for item in items {
            let scored = scoreCandidate(item, plan: plan, videoDuration: videoDuration)
            let key = item.downloadURL.absoluteString
            if let existing = dedup[key] {
                if scored.score > existing.score { dedup[key] = scored }
            } else {
                dedup[key] = scored
            }
        }
        return dedup.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func scoreCandidate(
        _ item: OnlineSubtitleCandidate,
        plan: SubtitleQueryPlan,
        videoDuration: Double?
    ) -> OnlineSubtitleCandidate {
        var score = item.score
        if item.matchedByHash { score += 500 }

        // 语言权重：简体 / 双语 > 繁体 > 通用中文 > 英语 > 日语
        switch item.languageLabel {
        case "中英双语", "中简双语", "简日双语", "双语":
            score += 420
        case "简体中文":
            score += 400
        case "繁体中文":
            score += 320
        case "中文":
            score += 300
        case "英语":
            score += 80
        case "日语":
            score += 40
        default:
            score += 10
        }

        // AV 番号精准命中额外加权
        if let avCode = plan.avCatalogCode {
            if compactAlphaNum(item.title).contains(compactAlphaNum(avCode)) {
                score += 220
            }
        }

        // 集数核对（避免第 1 集匹配到第 5 集）
        if let expectedEpisode = plan.parsed.episode {
            let candidateParsed = MediaNameParser.parse(item.title)
            if let foundEpisode = candidateParsed.episode {
                score += (foundEpisode == expectedEpisode) ? 180 : -450
            }
        }

        // 视频时长对照（偏差 <= 5s 基本为同压制版本）
        if let videoDuration, videoDuration > 60, let subDuration = item.durationSeconds, subDuration > 60 {
            let diff = abs(videoDuration - subDuration)
            if diff <= 5 {
                score += 150
            } else if diff <= 20 {
                score += 80
            } else if diff > 120 {
                score -= 150
            }
        }

        // 格式偏好
        switch item.format.lowercased() {
        case "ass", "ssa": score += 40
        case "srt", "vtt": score += 30
        case "smi": score -= 20
        default: break
        }

        return OnlineSubtitleCandidate(
            id: item.id,
            title: item.title,
            languageLabel: item.languageLabel,
            format: item.format,
            source: item.source,
            downloadURL: item.downloadURL,
            matchedByHash: item.matchedByHash,
            durationSeconds: item.durationSeconds,
            score: score
        )
    }

    private static func classifyLanguage(hints: [String], fileName: String) -> String {
        let joined = (hints + [fileName]).joined(separator: " ").lowercased()
        let tokens = Set(joined.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasSimp = joined.contains("简") || joined.contains("chs") || joined.contains("zh-cn") || joined.contains("zh_cn") || tokens.contains("sc")
        let hasTrad = joined.contains("繁") || joined.contains("cht") || joined.contains("zh-tw") || joined.contains("zh_tw") || joined.contains("big5") || tokens.contains("tc")
        let hasDual = joined.contains("双语") || joined.contains("中英") || joined.contains("简日") || joined.contains("chs&eng")
        if hasDual { return "双语" }
        if hasSimp { return "简体中文" }
        if hasTrad { return "繁体中文" }
        if joined.contains("中") || tokens.contains("chi") || tokens.contains("zho") || tokens.contains("chn") || tokens.contains("zh") { return "中文" }
        if joined.contains("英") || tokens.contains("eng") || tokens.contains("en") { return "英语" }
        if joined.contains("日") || tokens.contains("jpn") || tokens.contains("jap") || tokens.contains("ja") { return "日语" }
        if joined.contains("默认") { return "中文" }
        return "未知"
    }

    private static func mapOpenSubLanguage(_ code: String, fileName: String) -> String {
        let lowerName = fileName.lowercased()
        switch code {
        case "zht", "zh-tw", "zh-hk", "cht": return "繁体中文"
        case "zho", "chi", "chs", "zh", "zh-cn":
            return (lowerName.contains("hant") || lowerName.contains("cht") || lowerName.contains("繁")) ? "繁体中文" : "简体中文"
        case "eng": return "英语"
        case "jpn": return "日语"
        default: return code.uppercased()
        }
    }

    private static func compactAlphaNum(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
