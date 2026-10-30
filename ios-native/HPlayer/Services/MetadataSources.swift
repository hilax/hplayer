import Foundation

/// 影片资料的来源
enum MetadataSource: String, Codable, CaseIterable {
    /// 番组计划 bgm.tv：动画（含国产动画）和华语、日韩剧，中文名齐全，国内能直接访问，不用 Key
    case bangumi
    /// Cinemeta（IMDb 数据）：欧美影视，英文名
    case cinemeta
    /// TMDB：覆盖最全，有中文名和中文海报，需要用户自己填 API Key
    case tmdb
    /// R18.dev：按番号查找，用户开启后才访问
    case r18dev
    /// DMM（FANZA）：官方 Web API 或封面图片服务，按番号查找，用户开启后才访问
    case dmm

    var label: String {
        switch self {
        case .bangumi: return "番组计划"
        case .cinemeta: return "IMDb"
        case .tmdb: return "TMDB"
        case .r18dev: return "R18.dev"
        case .dmm: return "FANZA"
        }
    }

    var ratingPrefix: String {
        switch self {
        case .bangumi: return "Bangumi"
        case .cinemeta: return "IMDb"
        case .tmdb: return "TMDB"
        case .r18dev: return "R18.dev"
        case .dmm: return "FANZA"
        }
    }
}

// MARK: - 打分

/// 判断搜索结果和文件名里的片名有多接近。自动匹配只接受片名几乎一样的结果，
/// 以前中文片名会直接取第一个搜索结果，经常配上毫不相干的海报。
enum MetadataScoring {
    /// 完全一样 200；一个包含另一个、长度也差不多 120；只是部分包含 60；不相干 0
    static func titleScore(names: [String], queries: [String]) -> Int {
        var best = 0
        for query in queries {
            let wanted = MediaNameParser.cacheKey(query)
            guard !wanted.isEmpty else { continue }
            for name in names {
                let actual = MediaNameParser.cacheKey(name)
                guard !actual.isEmpty else { continue }
                if wanted == actual { return 200 }
                let (short, long) = wanted.count <= actual.count ? (wanted, actual) : (actual, wanted)
                let hasHan = short.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                guard long.contains(short), short.count >= (hasHan ? 2 : 4) else { continue }
                best = max(best, Double(short.count) / Double(long.count) >= 0.6 ? 120 : 60)
            }
        }
        return best
    }

    static func names(of metadata: MediaMetadata) -> [String] {
        [metadata.title, metadata.originalTitle ?? ""].filter { !$0.isEmpty }
    }

    static func score(_ metadata: MediaMetadata, queries: [String], year: String?, wantsSeries: Bool?) -> Int {
        var value = titleScore(names: names(of: metadata), queries: queries)
        if let wantsSeries { value += metadata.isSeries == wantsSeries ? 30 : -30 }
        if let year = year.flatMap(Int.init), let found = Int(metadata.year) {
            value += year == found ? 20 : (abs(year - found) <= 1 ? 10 : -10)
        }
        return value
    }

    /// 自动匹配用：挑出可以放心直接用的那一个，没有就返回 nil，留给用户手动匹配
    static func confidentPick(_ candidates: [MediaMetadata], queries: [String], year: String?, wantsSeries: Bool?) -> MediaMetadata? {
        func yearMatches(_ item: MediaMetadata) -> Bool {
            guard let year = year.flatMap(Int.init), let found = Int(item.year) else { return false }
            return abs(year - found) <= 1
        }
        // 分数一样时保持搜索结果原来的先后（来源自己按相关度排过）
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let left = score(lhs.element, queries: queries, year: year, wantsSeries: wantsSeries)
            let right = score(rhs.element, queries: queries, year: year, wantsSeries: wantsSeries)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        // 片名完全一样：类型对得上，或者年份对得上，或者同名的只有这一个
        let exact = ranked.filter { titleScore(names: names(of: $0), queries: queries) == 200 }
        if let pick = exact.first(where: { wantsSeries == nil || $0.isSeries == wantsSeries || yearMatches($0) }) {
            return pick
        }
        if exact.count == 1 { return exact[0] }
        // 片名基本一样（多了副标题之类）：类型和年份都要对上
        return ranked.first {
            titleScore(names: names(of: $0), queries: queries) >= 120
                && (wantsSeries == nil || $0.isSeries == wantsSeries)
                && yearMatches($0)
        }
    }
}

// MARK: - 统一入口

actor MetadataSearch {
    static let shared = MetadataSearch()
    private let r18dev: R18DevClient
    private let dmm: DMMClient
    private let adultEnabled: () -> Bool

    init(r18dev: R18DevClient = .shared, dmm: DMMClient = .shared, adultEnabled: @escaping () -> Bool = { AdultMetadataSettings.isEnabled }) {
        self.r18dev = r18dev
        self.dmm = dmm
        self.adultEnabled = adultEnabled
    }

    /// 首页自动识别：中文名先查番组计划（和填了 Key 的 TMDB），英文名查 IMDb，只接受片名几乎一样的结果
    func lookup(_ parsed: MediaNameParser.ParsedName) async -> MediaMetadata? {
        guard !Task.isCancelled else { return nil }
        let started = Date()
        let outcome = await lookupSources(parsed)
        let codeText = parsed.catalogCode.map { "番号 \($0)" } ?? "无番号"
        MatchDiagnostics.shared.record("查找「\(parsed.searchTitles.first ?? parsed.title)」（\(codeText)）→ \(outcome.map { "命中 \($0.sourceKind.label)" } ?? "未匹配")，用时 \(MatchDiagnostics.seconds(since: started))")
        return outcome
    }

    private func lookupSources(_ parsed: MediaNameParser.ParsedName) async -> MediaMetadata? {
        guard !Task.isCancelled else { return nil }
        // 番号文件只发番号给 R18.dev，不把包含私人信息的完整文件名发给其他来源。
        if adultEnabled(), let code = parsed.catalogCode {
            if let found = await r18dev.lookup(code) { return found }
            if Task.isCancelled { return nil }
            // R18.dev 没有就问 DMM（填了 Key 用官方接口，否则只找封面图）。
            if let found = await dmm.lookup(code) { return found }
            // 都没查到就回到普通来源，避免被误认成番号的剧集永远匹配不上。
            if Task.isCancelled { return nil }
        }
        let queries = parsed.searchTitles
        let wantsSeries = parsed.looksLikeSeries
        var candidates: [MediaMetadata] = []

        func pick() -> MediaMetadata? {
            MetadataScoring.confidentPick(candidates, queries: queries, year: parsed.year, wantsSeries: wantsSeries)
        }

        // 几个来源同时发出请求，但仍按原来的先后顺序看结果：前面的来源够确定就直接用，
        // 不用等后面的。总耗时是最慢那个来源的时间，而不是每个来源的时间加在一起。
        var jobs: [Task<[MediaMetadata], Never>] = []
        if let chinese = parsed.chineseTitle {
            jobs.append(Task { await BangumiClient.shared.search(chinese) })
            jobs.append(Task { await TMDBClient.shared.search(chinese) })
        }
        if let latin = parsed.latinTitle {
            jobs.append(Task { await CinemetaClient.shared.search(latin) })
            if parsed.chineseTitle == nil {
                jobs.append(Task { await TMDBClient.shared.search(latin) })
                jobs.append(Task { await BangumiClient.shared.search(latin) })
            }
        }
        defer { jobs.forEach { $0.cancel() } }
        for job in jobs {
            candidates += await job.value
            if Task.isCancelled { return nil }
            if let found = pick() { return await finish(found, parsed) }
        }
        return nil
    }

    /// 手动匹配：从一个来源搜。页面上几个来源同时搜，哪个先回来先显示哪个
    func candidates(from source: MetadataSource, query: String) async -> [MediaMetadata] {
        guard !Task.isCancelled else { return [] }
        let code = AVCatalogCode.extract(query)
        if adultEnabled(), code != nil, source != .r18dev, source != .dmm { return [] }
        let parsed = MediaNameParser.parse(query)
        switch source {
        case .bangumi:
            return await BangumiClient.shared.search(parsed.chineseTitle ?? parsed.title, limit: 12)
        case .tmdb:
            return await TMDBClient.shared.search(parsed.title)
        case .cinemeta:
            // 只有中文时 IMDb 搜不到东西，不浪费一次请求
            guard let latin = parsed.latinTitle else { return [] }
            return await CinemetaClient.shared.search(latin)
        case .r18dev:
            guard adultEnabled(), let code, let result = await r18dev.lookup(code) else { return [] }
            return [result]
        case .dmm:
            guard adultEnabled(), let code, let result = await dmm.lookup(code) else { return [] }
            return [result]
        }
    }

    /// 去掉重复的，按和片名的接近程度排好，剧集带上这一集的季数和集数
    nonisolated static func rank(_ items: [MediaMetadata], query: String, hint: MediaNameParser.ParsedName) -> [MediaMetadata] {
        let parsed = MediaNameParser.parse(query)
        let queries = parsed.searchTitles
        let wantsSeries = hint.looksLikeSeries
        let year = parsed.year ?? hint.year
        var seen = Set<String>()
        return items
            .filter { seen.insert($0.imdbID).inserted }
            .map { item -> MediaMetadata in
                var value = item
                value.season = item.isSeries ? (hint.season ?? (hint.episode == nil ? nil : 1)) : nil
                value.episode = item.isSeries ? hint.episode : nil
                return value
            }
            .enumerated()
            .sorted { lhs, rhs in
                let left = MetadataScoring.score(lhs.element, queries: queries, year: year, wantsSeries: wantsSeries)
                let right = MetadataScoring.score(rhs.element, queries: queries, year: year, wantsSeries: wantsSeries)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
    }

    private func finish(_ found: MediaMetadata, _ parsed: MediaNameParser.ParsedName) async -> MediaMetadata {
        var value = found
        if value.source == MetadataSource.cinemeta.rawValue {
            value = await CinemetaClient.shared.withDetail(value)
        }
        value.season = value.isSeries ? (parsed.season ?? (parsed.episode == nil ? nil : 1)) : nil
        value.episode = value.isSeries ? parsed.episode : nil
        return value
    }
}

// MARK: - 番组计划

/// 番组计划公开 API：https://github.com/bangumi/api ，搜索不需要登录。
actor BangumiClient {
    static let shared = BangumiClient()
    /// 番组计划要求非浏览器客户端带上开发者和应用名
    private static let userAgent = "hilax/HPlayer/1.2 (iOS) (https://github.com/hilax/hplayer)"

    private var endpoint: String {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["HPLAYER_METADATA_TEST_ENDPOINT"] { return value }
        #endif
        return "https://api.bgm.tv"
    }

    func search(_ keyword: String, limit: Int = 10) async -> [MediaMetadata] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, let url = URL(string: "\(endpoint)/v0/search/subjects?limit=\(limit)") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // 2 = 动画，6 = 三次元（电视剧、电影）
        let body: [String: Any] = ["keyword": keyword, "sort": "match", "filter": ["type": [2, 6], "nsfw": false]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        return page.data.compactMap(\.metadata)
    }

    private struct Page: Decodable {
        let data: [Subject]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            data = (try? container.decodeIfPresent([Subject].self, forKey: .data)) ?? []
        }

        enum CodingKeys: String, CodingKey { case data }
    }

    private struct Subject: Decodable {
        let id: Int
        let name: String
        let nameCN: String
        let summary: String
        let date: String
        let platform: String
        let poster: String
        let score: Double

        enum CodingKeys: String, CodingKey {
            case id, name, summary, date, platform, images, rating
            case nameCN = "name_cn"
        }

        struct Images: Decodable {
            let large: String?
            let common: String?
            let medium: String?
        }

        struct Rating: Decodable {
            let score: Double?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
            nameCN = (try? container.decodeIfPresent(String.self, forKey: .nameCN)) ?? ""
            summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            date = (try? container.decodeIfPresent(String.self, forKey: .date)) ?? ""
            platform = (try? container.decodeIfPresent(String.self, forKey: .platform)) ?? ""
            let images = try? container.decodeIfPresent(Images.self, forKey: .images)
            poster = [images?.large, images?.common, images?.medium].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            score = (try? container.decodeIfPresent(Rating.self, forKey: .rating))?.score ?? 0
        }

        var metadata: MediaMetadata? {
            let title = nameCN.isEmpty ? name : nameCN
            guard !title.isEmpty else { return nil }
            let kind = platform.lowercased()
            let movie = kind.contains("剧场版") || kind.contains("电影") || kind.contains("movie")
            let country: String
            switch platform {
            case "华语剧": country = "China"
            case "日剧": country = "Japan"
            case "韩剧": country = "South Korea"
            default: country = ""
            }
            var metadata = MediaMetadata(
                imdbID: "bgm:\(id)",
                type: movie ? "movie" : "series",
                title: title,
                year: String(date.prefix(4)).allSatisfy(\.isNumber) ? String(date.prefix(4)) : "",
                posterURL: poster,
                backgroundURL: "",
                logoURL: "",
                overview: summary,
                rating: score > 0 ? String(format: "%.1f", score) : "",
                genres: [],
                country: country,
                season: nil,
                episode: nil
            )
            metadata.originalTitle = name == title ? nil : name
            metadata.source = MetadataSource.bangumi.rawValue
            return metadata
        }
    }
}

// MARK: - TMDB

/// TMDB 需要自己在 themoviedb.org 申请 API Key（免费），填了才会用。
/// v3 的 API Key 和 v4 的「API 读访问令牌」都可以。
actor TMDBClient {
    static let shared = TMDBClient()
    private static let keychainKey = "hplayer.tmdb.apiKey"

    nonisolated static var storedKey: String {
        Keychain.load(keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func saveKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(keychainKey)
        } else {
            Keychain.save(trimmed, for: keychainKey)
        }
    }

    /// api.themoviedb.org 在一些网络下连不上时，换官方的另一个域名再试，并记住能用的那个
    private static let hosts = ["https://api.themoviedb.org", "https://api.tmdb.org"]
    private var workingHost: String?

    func search(_ query: String) async -> [MediaMetadata] {
        let key = Self.storedKey
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !query.isEmpty else { return [] }
        var order = Self.hosts
        if let workingHost, let index = order.firstIndex(of: workingHost) {
            order.remove(at: index)
            order.insert(workingHost, at: 0)
        }
        for host in order {
            guard var components = URLComponents(string: "\(host)/3/search/multi") else { continue }
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "language", value: "zh-CN"),
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "page", value: "1"),
            ]
            // v4 读访问令牌是一长串 JWT，放请求头；v3 API Key 放在地址里
            let bearer = key.count > 60 && key.hasPrefix("eyJ")
            if !bearer { components.queryItems?.append(URLQueryItem(name: "api_key", value: key)) }
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            workingHost = host
            guard (200..<300).contains(http.statusCode),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
            return page.results.compactMap(\.metadata)
        }
        return []
    }

    private struct Page: Decodable {
        let results: [Item]
    }

    private struct Item: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let overview: String?
        let voteAverage: Double?
        let originCountry: [String]?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case mediaType = "media_type"
            case originalTitle = "original_title"
            case originalName = "original_name"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case voteAverage = "vote_average"
            case originCountry = "origin_country"
        }

        var metadata: MediaMetadata? {
            guard mediaType == "movie" || mediaType == "tv" else { return nil }
            let movie = mediaType == "movie"
            let display = (movie ? title : name) ?? ""
            guard !display.isEmpty else { return nil }
            let original = (movie ? originalTitle : originalName) ?? ""
            let date = (movie ? releaseDate : firstAirDate) ?? ""
            let countries = ["CN": "China", "HK": "China", "TW": "Taiwan", "JP": "Japan", "KR": "South Korea", "US": "United States", "CA": "Canada", "GB": "United Kingdom"]
            var metadata = MediaMetadata(
                imdbID: "tmdb:\(mediaType ?? ""):\(id)",
                type: movie ? "movie" : "series",
                title: display,
                year: String(date.prefix(4)),
                posterURL: posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" } ?? "",
                backgroundURL: backdropPath.map { "https://image.tmdb.org/t/p/w1280\($0)" } ?? "",
                logoURL: "",
                overview: overview ?? "",
                rating: (voteAverage ?? 0) > 0 ? String(format: "%.1f", voteAverage ?? 0) : "",
                genres: [],
                country: (originCountry ?? []).compactMap { countries[$0] }.first ?? "",
                season: nil,
                episode: nil
            )
            metadata.originalTitle = original == display || original.isEmpty ? nil : original
            metadata.source = MetadataSource.tmdb.rawValue
            return metadata
        }
    }
}
