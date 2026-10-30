import Foundation

/// DMM（FANZA）的两个免费来源，只在开启「番号匹配」后使用，只发送番号：
/// 1. 官方 Web API：需要用户自己免费申请 API ID 和 Affiliate ID，填一次存进钥匙串，资料最全（片名、演员、日期、封面）。
/// 2. 封面图片服务：不需要账号，按番号推出图片地址，检查图片是否存在，只能得到封面。
actor DMMClient {
    static let shared = DMMClient()

    typealias Credentials = (apiID: String, affiliateID: String)

    private static let apiIDKey = "hplayer.dmm.apiID"
    private static let affiliateIDKey = "hplayer.dmm.affiliateID"

    nonisolated static func storedCredentials() -> Credentials? {
        let apiID = Keychain.load(apiIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let affiliateID = Keychain.load(affiliateIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return apiID.isEmpty || affiliateID.isEmpty ? nil : (apiID, affiliateID)
    }

    nonisolated static func saveCredentials(apiID: String, affiliateID: String) {
        Keychain.save(apiID.trimmingCharacters(in: .whitespacesAndNewlines), for: apiIDKey)
        Keychain.save(affiliateID.trimmingCharacters(in: .whitespacesAndNewlines), for: affiliateIDKey)
    }

    private let session: URLSession
    private let credentials: @Sendable () -> Credentials?
    private var nextRequestAt = Date.distantPast

    init(session: URLSession? = nil, credentials: @escaping @Sendable () -> Credentials? = { DMMClient.storedCredentials() }) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 先用官方接口（填了 Key 才会用），查不到再按图片地址找封面。
    func lookup(_ code: String) async -> MediaMetadata? {
        if let credentials = credentials(), let found = await lookupAPI(code, credentials: credentials) { return found }
        guard !Task.isCancelled else { return nil }
        return await lookupCover(code)
    }

    // MARK: 官方 Web API

    func lookupAPI(_ code: String, credentials: Credentials) async -> MediaMetadata? {
        guard let request = Self.apiRequest(code: code, credentials: credentials),
              let data = await fetch(request, interval: 1, label: "DMM 接口 \(code)") else { return nil }
        if let found = Self.decodeAPI(data, requestedCode: code) {
            MatchDiagnostics.shared.record("DMM 接口 \(code) 已匹配")
            return found
        }
        MatchDiagnostics.shared.record("DMM 接口 \(code) 没有同番号的结果。\(MatchDiagnostics.keys(of: data))")
        return nil
    }

    nonisolated static func apiRequest(code: String, credentials: Credentials) -> URLRequest? {
        guard let normalized = AVCatalogCode.extract(code), normalized == code.uppercased(),
              var components = URLComponents(string: "https://api.dmm.com/affiliate/v3/ItemList") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "api_id", value: credentials.apiID),
            URLQueryItem(name: "affiliate_id", value: credentials.affiliateID),
            URLQueryItem(name: "site", value: "FANZA"),
            URLQueryItem(name: "service", value: "digital"),
            URLQueryItem(name: "floor", value: "videoa"),
            URLQueryItem(name: "keyword", value: normalized),
            URLQueryItem(name: "hits", value: "10"),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func decodeAPI(_ data: Data, requestedCode: String) -> MediaMetadata? {
        guard let expected = AVCatalogCode.extract(requestedCode), expected == requestedCode.uppercased(),
              let response = try? JSONDecoder().decode(APIResponse.self, from: data) else { return nil }
        // 关键词搜索会返回相近的作品，必须是同一个番号才接受。
        let matches = (response.result?.items ?? []).filter { item in
            AVCatalogCode.contentID(item.contentID ?? "") == expected || AVCatalogCode.contentID(item.productID ?? "") == expected
                || AVCatalogCode.extract(item.productID ?? "") == expected
        }
        for item in matches {
            guard let poster = Self.httpsURL(item.imageURL?.large) ?? Self.httpsURL(item.imageURL?.small) else { continue }
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let year = String((item.date ?? "").prefix(4))
            var metadata = Self.metadata(code: expected, title: title, year: year, poster: poster)
            var seen = Set<String>()
            let names = (item.iteminfo?.actress ?? []).compactMap { actress -> String? in
                let name = actress.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty || !seen.insert(name).inserted ? nil : name
            }
            metadata.performers = names.isEmpty ? nil : names
            return metadata
        }
        return nil
    }

    // MARK: 封面图片服务

    func lookupCover(_ code: String) async -> MediaMetadata? {
        guard let urls = Self.coverURLs(for: code) else { return nil }
        // 几个常见的地址同时检查，按先后顺序取第一个存在的。
        var found: [Int: URL] = [:]
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, await self.exists(url)) }
            }
            for await (index, url) in group { if let url { found[index] = url } }
        }
        guard let index = found.keys.sorted().first, let url = found[index] else {
            MatchDiagnostics.shared.record("DMM 封面 \(code) 4 个常见地址都不存在")
            return nil
        }
        guard let normalized = AVCatalogCode.extract(code) else { return nil }
        MatchDiagnostics.shared.record("DMM 封面 \(code) 找到 \(url.deletingLastPathComponent().lastPathComponent)")
        return Self.metadata(code: normalized, title: "", year: "", poster: url.absoluteString)
    }

    /// START-656 → start00656、1start00656，分别在数字影片和碟片两个目录下找。
    nonisolated static func coverURLs(for code: String) -> [URL]? {
        guard let normalized = AVCatalogCode.extract(code), normalized == code.uppercased() else { return nil }
        let parts = normalized.lowercased().split(separator: "-")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        let label = String(parts[0])
        let padded = String(repeating: "0", count: max(0, 5 - String(number).count)) + String(number)
        var urls: [URL] = []
        for directory in ["digital/video", "mono/movie/adult"] {
            for cid in ["\(label)\(padded)", "1\(label)\(padded)"] {
                if let url = URL(string: "https://pics.dmm.co.jp/\(directory)/\(cid)/\(cid)pl.jpg") { urls.append(url) }
            }
        }
        return urls
    }

    private func exists(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 8
        guard await waitForSlot(interval: 0.25), !Task.isCancelled else { return nil }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if !(error is CancellationError) {
                MatchDiagnostics.shared.record("DMM 封面 \(url.deletingLastPathComponent().lastPathComponent) 请求失败：\(MatchDiagnostics.describe(error))")
            }
            return nil
        }
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        // 不存在的图片可能被转到「暂无图片」占位图，地址里要还是原来的编号。
        let cid = url.deletingLastPathComponent().lastPathComponent
        guard http.url?.absoluteString.contains(cid) != false else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "image/jpeg"
        return type.hasPrefix("image/") ? url : nil
    }

    // MARK: 共用

    nonisolated private static func httpsURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return value
    }

    nonisolated private static func metadata(code: String, title: String, year: String, poster: String) -> MediaMetadata {
        var metadata = MediaMetadata(
            imdbID: "dmm:\(code)", type: "movie",
            title: title.isEmpty ? code : "\(code) · \(title)",
            year: year.count == 4 && year.allSatisfy(\.isNumber) ? year : "",
            posterURL: poster, backgroundURL: "", logoURL: "", overview: "", rating: "",
            genres: [], country: "Japan", season: nil, episode: nil
        )
        metadata.source = MetadataSource.dmm.rawValue
        return metadata
    }

    /// 排队间隔：官方接口每秒一次，图片服务每 0.25 秒一次。被取消时返回 false。
    private func waitForSlot(interval: TimeInterval) async -> Bool {
        let now = Date()
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(interval)
        let delay = scheduled.timeIntervalSince(now)
        guard delay > 0 else { return true }
        do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); return true } catch { return false }
    }

    private func fetch(_ request: URLRequest, interval: TimeInterval, label: String) async -> Data? {
        guard await waitForSlot(interval: interval), !Task.isCancelled else { return nil }
        let started = Date()
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if !(error is CancellationError) {
                MatchDiagnostics.shared.record("\(label) 请求失败（\(MatchDiagnostics.seconds(since: started))）：\(MatchDiagnostics.describe(error))")
            }
            return nil
        }
        guard let http = result.1 as? HTTPURLResponse else { return nil }
        MatchDiagnostics.shared.record("\(label) → HTTP \(http.statusCode)（\(MatchDiagnostics.seconds(since: started))）")
        guard (200..<300).contains(http.statusCode) else { return nil }
        return result.0
    }

    private struct APIResponse: Decodable {
        let result: Result?

        struct Result: Decodable {
            let items: [Item]?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                items = try? container.decodeIfPresent([Item].self, forKey: .items)
            }
            enum CodingKeys: String, CodingKey { case items }
        }

        struct Item: Decodable {
            let contentID: String?
            let productID: String?
            let title: String?
            let date: String?
            let imageURL: Image?
            let iteminfo: Info?
            enum CodingKeys: String, CodingKey {
                case contentID = "content_id", productID = "product_id", title, date, imageURL, iteminfo
            }
        }

        struct Image: Decodable {
            let large: String?
            let small: String?
        }

        struct Info: Decodable {
            let actress: [Actress]?
            struct Actress: Decodable { let name: String? }
        }
    }
}

extension MediaMetadata {
    /// R18.dev 和 DMM 的封面是横版的整张包装（正面在右半边），海报位置要靠右裁切。
    var isWideJacket: Bool { sourceKind == .r18dev || sourceKind == .dmm }
}
