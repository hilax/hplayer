import Foundation

/// 只识别常见的字母加数字番号；多个不同番号时不猜。
enum AVCatalogCode {
    private static let ignoredPrefixes: Set<String> = [
        "WEB", "WEBRIP", "BLURAY", "HDTV", "BDRIP", "HDRIP", "DVDRIP",
        "HEVC", "AVC", "AAC", "DDP", "DTS", "HDR", "CHD", "HD",
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
            // 普通片名常以空格或点号接年份，不把它当作番号。
            if separator != "-", digits.count == 4, (1900...2099).contains(number) { continue }
            let normalized = String(number)
            let padded = String(repeating: "0", count: max(0, 3 - normalized.count)) + normalized
            codes.insert("\(prefix)-\(padded)")
        }
        return codes.count == 1 ? codes.first : nil
    }

    /// 来源的 content_id 必须完整地表示同一个番号，不能只匹配其中一部分。
    static func contentID(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"(?i)^[a-z]{2,8}[0-9]{3,5}$"#, options: .regularExpression) != nil else { return nil }
        return extract(value)
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

    func lookup(_ code: String) async -> MediaMetadata? {
        guard let request = Self.request(for: code) else { return nil }
        // 自动扫描可能涉及许多文件，串行限速，避免快速请求同一个公共接口。
        let now = Date()
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(1)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return nil }
        }
        guard !Task.isCancelled,
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 {
            let seconds = min(max(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30, 1), 60)
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(seconds))
        }
        guard (200..<300).contains(http.statusCode), !Task.isCancelled else { return nil }
        return Self.decode(data, requestedCode: code)
    }

    nonisolated static func request(for code: String) -> URLRequest? {
        guard let normalized = AVCatalogCode.extract(code), normalized == code.uppercased(),
              let url = URL(string: "https://r18.dev/videos/vod/movies/detail/-/dvd_id=\(normalized.replacingOccurrences(of: "-", with: "").lowercased())/json") else { return nil }
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
        let posters = [item.images?.jacketImage?.large, item.images?.jacketImage?.large2]
        guard let poster = posters.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { value in
            guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host else { return false }
            return !host.isEmpty
        }) else { return nil }
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let year = String((item.releaseDate ?? "").prefix(4))
        var metadata = MediaMetadata(
            imdbID: "r18dev:\(expected)", type: "movie",
            title: title.isEmpty ? expected : "\(expected) · \(title)",
            year: year.count == 4 && year.allSatisfy(\.isNumber) ? year : "",
            posterURL: poster, backgroundURL: "", logoURL: "", overview: "", rating: "",
            genres: [], country: "Japan", season: nil, episode: nil
        )
        metadata.source = MetadataSource.r18dev.rawValue
        return metadata
    }

    private struct Response: Decodable {
        let contentID: String
        let dvdID: String?
        let title: String?
        let releaseDate: String?
        let images: Images?

        enum CodingKeys: String, CodingKey {
            case contentID = "content_id", dvdID = "dvd_id", title, releaseDate = "release_date", images
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
