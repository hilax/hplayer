import Foundation

/// 种子里的一个文件，带上给人看的标题、集数和分类。
struct MagnetFile: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case video
        case subtitle
        case image
        case archive
        case document
        case other
    }

    let index: UInt32
    /// 种子里的完整路径
    let path: String
    let size: UInt64
    /// 文件名（含扩展名）
    let name: String
    /// 去掉种子根目录后的所在文件夹，根目录下为空
    let folder: String
    /// 小写扩展名
    let ext: String
    let kind: Kind
    /// 去掉扩展名和网址广告前缀后的标题
    let title: String
    /// 识别到的集数，例如「S01E03」「第 3 集」
    let episodeLabel: String?

    var id: UInt32 { index }
    var isPlayable: Bool { kind == .video }
    var sizeText: String { formatSize(Int(clamping: size)) }

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "m2ts", "mts", "webm", "flv", "f4v",
        "rmvb", "rm", "mpg", "mpeg", "m2v", "vob", "3gp", "ogv", "asf", "divx",
    ]
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup", "smi"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "iso"]
    private static let documentExtensions: Set<String> = ["txt", "nfo", "url", "html", "htm", "pdf", "mht", "chm", "doc", "docx", "lnk"]

    init(_ file: NuvioTorrentFile, rootFolder: String?) {
        index = file.index
        path = file.path
        size = file.size
        var components = file.path.split(separator: "/").map { String($0) }
        name = components.popLast() ?? file.path
        if let rootFolder, components.first == rootFolder { components.removeFirst() }
        folder = components.joined(separator: " / ")
        ext = (name as NSString).pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            kind = .video
        } else if Self.subtitleExtensions.contains(ext) {
            kind = .subtitle
        } else if Self.imageExtensions.contains(ext) {
            kind = .image
        } else if Self.archiveExtensions.contains(ext) || ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil {
            kind = .archive
        } else if Self.documentExtensions.contains(ext) {
            kind = .document
        } else {
            kind = .other
        }
        title = Self.cleanTitle(name)
        episodeLabel = kind == .video ? Self.episode(in: name) : nil
    }

    /// 文件名里看起来像样片、预告的视频
    var looksLikeSample: Bool {
        let lower = name.lowercased()
        return ["sample", "trailer", "预告", "預告", "片花"].contains { lower.contains($0) }
    }

    // MARK: 标题与集数

    private static let adPrefix = try? NSRegularExpression(
        pattern: #"^\s*[\[【(（]?\s*(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|cc|net|org|xyz|me|tv|top|vip|club|la|info|biz|co|io|in|us|one|life|live|fun|link|cn|tw|jp)\s*[\]】)）@]\s*"#,
        options: [.caseInsensitive]
    )

    static func cleanTitle(_ fileName: String) -> String {
        var title = (fileName as NSString).deletingPathExtension
        if let adPrefix {
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            title = adPrefix.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        }
        // 用点分隔单词的（The.Show.S01E02.1080p），换成空格更好读
        if !title.contains(" "), title.filter({ $0 == "." }).count >= 2 {
            title = title.replacingOccurrences(of: ".", with: " ")
        }
        title = title.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? fileName : title
    }

    /// 识别集数的规则，第二项表示是否带季数
    private static let episodePatterns: [(NSRegularExpression, Bool)] = {
        let raw: [(String, Bool)] = [
            (#"[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})(?!\d)"#, true),
            (#"第\s*(\d{1,4})\s*[集话話期]"#, false),
            (#"(?<![A-Za-z])[Ee][Pp]?\s?(\d{1,3})(?!\d)"#, false),
            (#"(?:\[|【| - )(\d{1,3})(?:[vV]\d)?(?:\]|】| |\.)"#, false),
        ]
        return raw.compactMap { item -> (NSRegularExpression, Bool)? in
            guard let regex = try? NSRegularExpression(pattern: item.0) else { return nil }
            return (regex, item.1)
        }
    }()

    static func episode(in fileName: String) -> String? {
        let text = (fileName as NSString).deletingPathExtension
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (regex, seasonal) in episodePatterns {
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            func number(_ group: Int) -> Int? {
                guard let found = Range(match.range(at: group), in: text) else { return nil }
                return Int(text[found])
            }
            if seasonal, let season = number(1), let episode = number(2) {
                return String(format: "S%02dE%02d", season, episode)
            }
            if !seasonal, let episode = number(1) {
                return "第 \(episode) 集"
            }
        }
        return nil
    }
}

/// 解析出来的种子内容：正片按自然顺序排好，样片和广告视频、非视频文件分开放。
struct MagnetCatalog: Sendable {
    let name: String
    let totalSize: UInt64
    let fileCount: Int
    /// 正片
    let main: [MagnetFile]
    /// 其他视频：样片、预告、广告等
    let extras: [MagnetFile]
    /// 非视频文件：字幕、图片、压缩包、文本等
    let others: [MagnetFile]
    /// 正片分布在多个文件夹里（例如按季分）
    let hasFolders: Bool

    var allVideos: [MagnetFile] { main + extras }
    var hasArchivesOnly: Bool { main.isEmpty && extras.isEmpty && others.contains { $0.kind == .archive } }

    init(files: [NuvioTorrentFile], fallbackName: String) {
        // 所有文件都在同一个根文件夹下时，根文件夹名就是种子名，列表里不再重复显示
        let firstComponents = files.map { file -> String in
            guard let first = file.path.split(separator: "/").first else { return "" }
            return String(first)
        }
        let sharedRoot: String?
        if files.allSatisfy({ $0.path.contains("/") }), let first = firstComponents.first, !first.isEmpty,
           firstComponents.allSatisfy({ $0 == first }) {
            sharedRoot = first
        } else {
            sharedRoot = nil
        }

        let items = files.map { MagnetFile($0, rootFolder: sharedRoot) }
        let videos = items.filter(\.isPlayable)
        let largest = videos.map(\.size).max() ?? 0
        let mainThreshold: UInt64 = 150 * 1024 * 1024

        var main = videos.filter { !$0.looksLikeSample && ($0.size >= largest / 4 || $0.size >= mainThreshold) }
        if main.isEmpty { main = videos.filter { !$0.looksLikeSample } }
        if main.isEmpty { main = videos }
        let mainIndexes = Set(main.map(\.index))

        let byPath: (MagnetFile, MagnetFile) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        self.main = main.sorted(by: byPath)
        extras = videos.filter { !mainIndexes.contains($0.index) }.sorted { $0.size > $1.size }
        others = items.filter { !$0.isPlayable }.sorted(by: byPath)
        hasFolders = Set(self.main.map(\.folder)).count > 1

        if let sharedRoot {
            name = sharedRoot
        } else if files.count == 1, let only = items.first {
            name = only.title
        } else {
            name = fallbackName
        }
        totalSize = files.reduce(0) { $0 &+ $1.size }
        fileCount = files.count
    }
}
