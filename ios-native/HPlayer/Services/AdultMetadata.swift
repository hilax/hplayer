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

/// R18.dev 的公开 JSON 接口，只提交番号。返回的 content_id 必须与请求一致。
actor R18DevClient {
    static let shared = R18DevClient()
    private let session: URLSession
    private var nextRequestAt = Date.distantPast

    init(session: URLSession? = nil) {
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
        for hyphenated in [hyphenFirst, !hyphenFirst] {
            guard !Task.isCancelled else { return nil }
            guard let request = Self.request(for: code, hyphenated: hyphenated) else { return nil }
            switch await fetch(request) {
            case .data(let data):
                if let metadata = Self.decode(data, requestedCode: code) {
                    hyphenFirst = hyphenated
                    return metadata
                }
            case .notFound:
                continue
            case .failed:
                return nil
            }
        }
        return nil
    }

    private enum FetchResult { case data(Data), notFound, failed }

    private func fetch(_ request: URLRequest) async -> FetchResult {
        // 自动扫描可能涉及许多文件，串行限速，避免快速请求同一个公共接口。
        let now = Date()
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(1)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return .failed }
        }
        guard !Task.isCancelled,
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 429 {
            let seconds = min(max(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30, 1), 60)
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(seconds))
            return .failed
        }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode), !Task.isCancelled else { return .failed }
        return .data(data)
    }

    nonisolated static func request(for code: String, hyphenated: Bool = false) -> URLRequest? {
        guard let normalized = AVCatalogCode.extract(code), normalized == code.uppercased() else { return nil }
        let id = hyphenated ? normalized.lowercased() : normalized.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = URL(string: "https://r18.dev/videos/vod/movies/detail/-/dvd_id=\(id)/json") else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("hilax/HPlayer/1.2 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func decode(_ data: Data, requestedCode: String) -> MediaMetadata? {
        guard let expected = AVCatalogCode.extract(requestedCode), expected == requestedCode.uppercased(),
              let item = try? JSONDecoder().decode(Response.self, from: data),
              AVCatalogCode.contentID(item.contentID) == expected else { return nil }
        if let dvdID = item.dvdID, !dvdID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           AVCatalogCode.extract(dvdID) != expected { return nil }
        // r18.dev 的详情有两种写法：新的 jacket_full_url，和沿用 DMM 的 images.jacket_image。
        let posters = [item.jacketFullURL, item.images?.jacketImage?.large, item.images?.jacketImage?.large2, item.jacketThumbURL]
        guard let poster = posters.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { value in
            guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host else { return false }
            return !host.isEmpty
        }) else { return nil }
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
        var seen = Set<String>()
        let names = (item.actresses ?? []).compactMap { actress -> String? in
            let kanji = actress.kanji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let romaji = actress.romaji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = kanji.isEmpty ? romaji : kanji
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
        metadata.performers = names.isEmpty ? nil : names
        return metadata
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

        struct Actress: Decodable {
            let kanji: String?
            let romaji: String?
            enum CodingKeys: String, CodingKey { case kanji = "name_kanji", romaji = "name_romaji" }
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
