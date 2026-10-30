import Foundation

/// 只识别常见的字母加数字番号；多个不同番号时不猜。
enum AVCatalogCode {
    private static let ignoredPrefixes: Set<String> = [
        "WEB", "WEBRIP", "BLURAY", "HDTV", "BDRIP", "HDRIP", "DVDRIP",
        "HEVC", "AVC", "AAC", "DDP", "DTS", "HDR", "CHD", "HD",
        // 剧集、动画常见的集数、卷数、分辨率写法，不是番号。
        "EP", "EPS", "EPISODE", "EPISODES", "VOL", "PART", "PT", "CD", "DISC", "DISK",
        "SEASON", "NO", "NUM", "CH", "CHAPTER", "OVA", "OAD", "SP", "NCOP", "NCED",
        "UHD", "FHD", "DV", "FLAC", "OPUS", "MP", "AC",
    ]

    static func extract(_ text: String) -> String? {
        // 文件名里的站点水印可能也含有数字，先去掉域名和链接，再识别番号。
        let value = text.replacingOccurrences(
            of: #"(?i)(?:https?://[^\s\]】)）]+|(?:www\.)?[a-z0-9-]+\.(?:com|net|org|cc|tv)(?:/[^\s\]】)）]*)?)"#,
            with: " ", options: .regularExpression
        )
        let pattern = #"(?i)(?<![a-z0-9])([a-z]{2,8})([-_. ]?)([0-9]{3,5})(?![a-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var codes = Set<String>()
        for match in regex.matches(in: value, range: range) {
            guard let prefixRange = Range(match.range(at: 1), in: value),
                  let separatorRange = Range(match.range(at: 2), in: value),
                  let numberRange = Range(match.range(at: 3), in: value) else { continue }
            let prefix = String(value[prefixRange]).uppercased()
            let separator = String(value[separatorRange])
            let digits = String(value[numberRange])
            guard !ignoredPrefixes.contains(prefix), let number = Int(digits), number > 0 else { continue }
            // 番号写成「ABC-123」「ABC123」「ABC_123」。用点号或空格隔开的多半是片名加集数
            // （One.Piece.1100、Naruto Episode 100），不当作番号。
            guard separator.isEmpty || separator == "-" || separator == "_" else { continue }
            if separator != "-", digits.count == 4, (1900...2099).contains(number) { continue }
            let normalized = String(number)
            let padded = String(repeating: "0", count: max(0, 3 - normalized.count)) + normalized
            codes.insert("\(prefix)-\(padded)")
        }
        return codes.count == 1 ? codes.first : nil
    }

    /// 来源的 content_id 必须完整地表示同一个番号，不能只匹配其中一部分。
    /// 很多厂商的 content_id 带数字或 h_ 前缀（1start00656、h_1234abc00123、118abp00123），先去掉再核对。
    static func contentID(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = value.replacingOccurrences(of: #"^(?:h_)?[0-9]{0,4}_?"#, with: "", options: .regularExpression)
        guard stripped.range(of: #"^[a-z]{2,8}[0-9]{3,5}$"#, options: .regularExpression) != nil else { return nil }
        return extract(stripped)
    }
}

enum AdultMetadataSettings {
    static let enabledKey = "hplayer.metadata.r18dev.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

/// 按番号查演员的结果。
enum PerformerLookup: Equatable {
    /// 查到了演员名
    case found([String])
    /// 来源里有这部片，但没有演员（或来源没有这个番号）：一段时间内不再重复问
    case none
    /// 网络出错、被限流：不算问过，稍后再试
    case unavailable
}

extension MediaMetadata {
    /// 番号类来源（R18.dev、FANZA）匹配到的影片带着番号，其他来源没有。
    /// 每次补查演员都要对整个片库调用，所以不用正则，只做简单的格式检查（真正发请求前还会再核对一次）。
    var catalogCode: String? {
        guard source == MetadataSource.r18dev.rawValue || source == MetadataSource.dmm.rawValue,
              let colon = imdbID.firstIndex(of: ":") else { return nil }
        let value = String(imdbID[imdbID.index(after: colon)...])
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, (2...8).contains(parts[0].count), (3...5).contains(parts[1].count),
              parts[0].unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }),
              parts[1].unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
        return value
    }
}

/// R18.dev 的公开 JSON 接口，只提交番号。返回的 content_id 必须与请求一致。
///
/// 接口有两层：按番号查（`dvd_id=…`）一定会给出 content_id，可能带封面和片名；
/// 演员、完整资料在按 content_id 查的详情（`combined=…`）里。需要演员、或者番号接口没给封面时，再取一次详情。
actor R18DevClient {
    static let shared = R18DevClient()
    private let session: URLSession
    private var nextRequestAt = Date.distantPast
    /// 两次请求之间至少隔多久。公共接口，默认每秒一次；测试里设为 0。
    private let minimumInterval: TimeInterval

    init(session: URLSession? = nil, minimumInterval: TimeInterval = 1) {
        self.minimumInterval = minimumInterval
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// r18.dev 的 dvd_id 有「start-656」和「start656」两种写法，哪种有效就记住哪种。
    private var hyphenFirst = true

    func lookup(_ code: String) async -> MediaMetadata? {
        switch await fetchRecord(for: code, needsPerformers: false) {
        case .record(let record):
            if let metadata = record.metadata {
                MatchDiagnostics.shared.record("r18.dev \(code) 已匹配（content_id \(record.contentID)，演员 \(record.performers.map { "\($0.count) 位" } ?? "未取")）")
                return metadata
            }
            MatchDiagnostics.shared.record("r18.dev \(code) 返回了内容但不能用（没有 https 封面）")
            return nil
        case .notFound:
            MatchDiagnostics.shared.record("r18.dev \(code) 两种写法都没有结果")
            return nil
        case .unavailable:
            return nil
        }
    }

    /// 查演员名。已经知道 content_id（匹配时记下的）就直接取详情，只要一次请求。
    func performers(for code: String, contentID: String? = nil) async -> PerformerLookup {
        if let contentID {
            switch await detail(contentID: contentID) {
            case .data(let data):
                if let parsed = Self.parse(data, requestedCode: code) { return Self.outcome(parsed.performers) }
                // 编号对不上：记下的 content_id 不对，回到按番号查。
            case .notFound:
                break
            case .failed:
                return .unavailable
            }
        }
        switch await fetchRecord(for: code, needsPerformers: true) {
        case .record(let record):
            if let names = record.performers { return Self.outcome(names) }
            return record.detailed ? .none : .unavailable
        case .notFound:
            return .none
        case .unavailable:
            return .unavailable
        }
    }

    nonisolated private static func outcome(_ names: [String]?) -> PerformerLookup {
        guard let names, !names.isEmpty else { return .none }
        return .found(names)
    }

    struct Record {
        var contentID: String
        /// 有可用封面时才有
        var metadata: MediaMetadata?
        /// nil 表示来源没给出演员这一项（不等于没有演员）
        var performers: [String]?
        /// 已经拿到完整详情
        var detailed: Bool

        mutating func apply(_ parsed: Parsed) {
            if let found = parsed.metadata { metadata = found }
            if let names = parsed.performers {
                performers = names
                metadata?.performers = names.isEmpty ? nil : names
            }
            detailed = true
        }
    }

    private enum RecordResult { case record(Record), notFound, unavailable }

    /// 按番号取记录。needsPerformers 为真、或番号接口没给封面时，再按 content_id 取一次详情。
    private func fetchRecord(for code: String, needsPerformers: Bool) async -> RecordResult {
        var sawNotFound = false
        for hyphenated in [hyphenFirst, !hyphenFirst] {
            guard !Task.isCancelled else { return .unavailable }
            guard let request = Self.request(for: code, hyphenated: hyphenated) else { return .unavailable }
            switch await fetch(request) {
            case .data(let data):
                guard let first = Self.parse(data, requestedCode: code) else {
                    MatchDiagnostics.shared.record("r18.dev \(code) 返回了内容但编号对不上。\(MatchDiagnostics.keys(of: data))")
                    continue
                }
                hyphenFirst = hyphenated
                var record = Record(contentID: first.contentID, metadata: first.metadata, performers: first.performers,
                                    detailed: first.metadata != nil && first.performers != nil)
                guard (needsPerformers && first.performers == nil) || first.metadata == nil else { return .record(record) }
                switch await detail(contentID: first.contentID) {
                case .data(let detailData):
                    if let parsed = Self.parse(detailData, requestedCode: code) { record.apply(parsed) }
                case .notFound, .failed:
                    break
                }
                return .record(record)
            case .notFound:
                sawNotFound = true
            case .failed:
                return .unavailable
            }
        }
        return sawNotFound ? .notFound : .unavailable
    }

    private func detail(contentID: String) async -> FetchResult {
        guard let request = Self.detailRequest(contentID: contentID) else { return .notFound }
        return await fetch(request)
    }

    private enum FetchResult { case data(Data), notFound, failed }

    private func fetch(_ request: URLRequest) async -> FetchResult {
        let tag = request.url?.lastPathComponent == "json" ? (request.url?.deletingLastPathComponent().lastPathComponent ?? "") : ""
        // 自动扫描可能涉及许多文件，串行限速，避免快速请求同一个公共接口。
        let now = Date()
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(minimumInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return .failed }
        }
        guard !Task.isCancelled else { return .failed }
        let started = Date()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if !(error is CancellationError) {
                MatchDiagnostics.shared.record("r18.dev \(tag) 请求失败（\(MatchDiagnostics.seconds(since: started))）：\(MatchDiagnostics.describe(error))")
            }
            return .failed
        }
        guard let http = result.1 as? HTTPURLResponse else { return .failed }
        MatchDiagnostics.shared.record("r18.dev \(tag) → HTTP \(http.statusCode)（\(MatchDiagnostics.seconds(since: started))）")
        if http.statusCode == 429 {
            let seconds = min(max(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30, 1), 60)
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(seconds))
            return .failed
        }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode), !Task.isCancelled else { return .failed }
        return .data(result.0)
    }

    nonisolated static func request(for code: String, hyphenated: Bool = false) -> URLRequest? {
        guard let normalized = AVCatalogCode.extract(code), normalized == code.uppercased() else { return nil }
        let id = hyphenated ? normalized.lowercased() : normalized.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = URL(string: "https://r18.dev/videos/vod/movies/detail/-/dvd_id=\(id)/json") else { return nil }
        return makeRequest(url)
    }

    /// 按 content_id 取完整详情（演员在这里）。content_id 只允许字母、数字、下划线，不能把别的东西拼进地址。
    nonisolated static func detailRequest(contentID: String) -> URLRequest? {
        guard contentID.range(of: #"^[A-Za-z0-9_]{3,40}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://r18.dev/videos/vod/movies/detail/-/combined=\(contentID)/json") else { return nil }
        return makeRequest(url)
    }

    nonisolated private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("hilax/HPlayer/1.2 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    struct Parsed {
        let contentID: String
        /// 有 https 封面才有
        let metadata: MediaMetadata?
        /// nil = 这份 JSON 里没有演员这一项
        let performers: [String]?
    }

    nonisolated static func decode(_ data: Data, requestedCode: String) -> MediaMetadata? {
        parse(data, requestedCode: requestedCode)?.metadata
    }

    /// 编号必须和请求的番号一致才接受；封面、演员各自可能缺。
    nonisolated static func parse(_ data: Data, requestedCode: String) -> Parsed? {
        guard let expected = AVCatalogCode.extract(requestedCode), expected == requestedCode.uppercased(),
              let item = try? JSONDecoder().decode(Response.self, from: data),
              AVCatalogCode.contentID(item.contentID) == expected else { return nil }
        if let dvdID = item.dvdID, !dvdID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           AVCatalogCode.extract(dvdID) != expected { return nil }
        // 有汉字名用汉字名，没有再用罗马字；同一个人不重复。
        let names: [String]? = item.actresses.map { actresses in
            PerformerName.unique(actresses.map { actress in
                let kanji = actress.kanji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return kanji.isEmpty ? (actress.romaji ?? "") : kanji
            })
        }
        // r18.dev 的详情有两种写法：新的 jacket_full_url，和沿用 DMM 的 images.jacket_image。
        let posters = [item.jacketFullURL, item.images?.jacketImage?.large, item.images?.jacketImage?.large2, item.jacketThumbURL]
        guard let poster = posters.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { value in
            guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host else { return false }
            return !host.isEmpty
        }) else {
            return Parsed(contentID: item.contentID, metadata: nil, performers: names)
        }
        let title = [item.titleEN, item.titleJA, item.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        let year = String((item.releaseDate ?? "").prefix(4))
        var metadata = MediaMetadata(
            imdbID: "r18dev:\(expected)", type: "movie",
            title: title.isEmpty ? expected : "\(expected) · \(title)",
            year: year.count == 4 && year.allSatisfy(\.isNumber) ? year : "",
            posterURL: poster, backgroundURL: "", logoURL: "", overview: "", rating: "",
            genres: [], country: "Japan", season: nil, episode: nil
        )
        metadata.source = MetadataSource.r18dev.rawValue
        metadata.contentID = item.contentID
        metadata.performers = (names ?? []).isEmpty ? nil : names
        return Parsed(contentID: item.contentID, metadata: metadata, performers: names)
    }

    private struct Response: Decodable {
        let contentID: String
        let dvdID: String?
        let title: String?
        let titleEN: String?
        let titleJA: String?
        let jacketFullURL: String?
        let jacketThumbURL: String?
        let releaseDate: String?
        let images: Images?
        let actresses: [Actress]?

        enum CodingKeys: String, CodingKey {
            case contentID = "content_id", dvdID = "dvd_id", title, titleEN = "title_en", titleJA = "title_ja"
            case jacketFullURL = "jacket_full_url", jacketThumbURL = "jacket_thumb_url"
            case releaseDate = "release_date", images, actresses
        }

        /// 只有 content_id 是必须的；其余字段格式不对时当作没有，不要因为演员列表写法变了连封面都丢掉。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contentID = try container.decode(String.self, forKey: .contentID)
            dvdID = try? container.decodeIfPresent(String.self, forKey: .dvdID)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            titleEN = try? container.decodeIfPresent(String.self, forKey: .titleEN)
            titleJA = try? container.decodeIfPresent(String.self, forKey: .titleJA)
            jacketFullURL = try? container.decodeIfPresent(String.self, forKey: .jacketFullURL)
            jacketThumbURL = try? container.decodeIfPresent(String.self, forKey: .jacketThumbURL)
            releaseDate = try? container.decodeIfPresent(String.self, forKey: .releaseDate)
            images = try? container.decodeIfPresent(Images.self, forKey: .images)
            actresses = try? container.decodeIfPresent([Actress].self, forKey: .actresses)
        }

        struct Actress: Decodable {
            let kanji: String?
            let romaji: String?
            enum CodingKeys: String, CodingKey { case kanji = "name_kanji", romaji = "name_romaji" }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kanji = try? container.decodeIfPresent(String.self, forKey: .kanji)
                romaji = try? container.decodeIfPresent(String.self, forKey: .romaji)
            }
        }

        struct Images: Decodable {
            let jacketImage: JacketImage?
            enum CodingKeys: String, CodingKey { case jacketImage = "jacket_image" }
        }

        struct JacketImage: Decodable {
            let large: String?
            let large2: String?
        }
    }
}
