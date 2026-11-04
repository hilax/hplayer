import Foundation

enum JavBusError: LocalizedError {
    case invalidURL
    case cloudflareBlocked
    case serverError(Int)
    case network(Error)
    case parseFailed
    case emptyMagnets

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的请求地址"
        case .cloudflareBlocked:
            return "受到网络防护拦截（Cloudflare），请检查代理或更换镜像域名"
        case let .serverError(code):
            return "服务器响应异常 (\(code))"
        case let .network(err):
            return "网络请求失败: \(err.localizedDescription)"
        case .parseFailed:
            return "页面解析失败，可能站点结构已改变"
        case .emptyMagnets:
            return "未找到可用的磁力链接"
        }
    }
}

/// JavBus 磁力抓取与分类/女优解析引擎。
final class JavBusSource: MagnetSearchSource, @unchecked Sendable {
    static let shared = JavBusSource()

    let name = "JavBus"

    private let session: URLSession
    private let defaultHost = "https://www.javbus.com"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// 当前配置的基础访问域名（支持用户在设置中自定义镜像站）。
    var currentHost: String {
        let custom = UserDefaults.standard.string(forKey: "hplayer.magnet.javbus_host")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom.hasSuffix("/") ? String(custom.dropLast()) : custom
        }
        return defaultHost
    }

    private var mobileUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    }

    private func makeRequest(url: URL, referer: String? = nil, isAJAX: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        req.setValue("existmag=all", forHTTPHeaderField: "Cookie")
        if let referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if isAJAX {
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        return req
    }

    private func fetchData(from url: URL, referer: String? = nil, isAJAX: Bool = false) async throws -> (Data, String) {
        let req = makeRequest(url: url, referer: referer, isAJAX: isAJAX)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw JavBusError.network(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 503 {
                throw JavBusError.cloudflareBlocked
            }
            guard (200...299).contains(http.statusCode) else {
                throw JavBusError.serverError(http.statusCode)
            }
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if html.contains("cf-browser-verification") || html.contains("cf-challenge") {
            throw JavBusError.cloudflareBlocked
        }
        return (data, html)
    }

    // MARK: - 搜索影片

    func search(keyword: String, page: Int = 1) async throws -> [MagnetSearchItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let urlString = page > 1
            ? "\(currentHost)/search/\(encoded)/\(page)"
            : "\(currentHost)/search/\(encoded)"

        guard let url = URL(string: urlString) else {
            throw JavBusError.invalidURL
        }

        let (_, html) = try await fetchData(from: url)
        return Self.parseSearchItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 分类列表浏览（最新、无码）

    func fetchCategory(_ category: MagnetCategory, page: Int = 1) async throws -> [MagnetSearchItem] {
        let urlString: String
        switch category {
        case .latest:
            urlString = page > 1 ? "\(currentHost)/page/\(page)" : "\(currentHost)/"
        case .uncensored:
            urlString = page > 1 ? "\(currentHost)/uncensored/page/\(page)" : "\(currentHost)/uncensored"
        case .actresses:
            return []
        }

        guard let url = URL(string: urlString) else {
            throw JavBusError.invalidURL
        }

        let (_, html) = try await fetchData(from: url)
        return Self.parseSearchItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 女优浏览与搜索

    func fetchActresses(page: Int = 1) async throws -> [MagnetStarItem] {
        let urlString = page > 1 ? "\(currentHost)/actresses/\(page)" : "\(currentHost)/actresses"
        guard let url = URL(string: urlString) else {
            throw JavBusError.invalidURL
        }

        let (_, html) = try await fetchData(from: url)
        return Self.parseStarItems(from: html, baseURLString: currentHost)
    }

    func searchActresses(name: String) async throws -> [MagnetStarItem] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let urlString = "\(currentHost)/searchstar/\(encoded)"
        guard let url = URL(string: urlString) else {
            throw JavBusError.invalidURL
        }

        let (_, html) = try await fetchData(from: url)
        return Self.parseStarItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 女优专属作品列表

    func fetchStarDetail(starPath: String, page: Int = 1) async throws -> (star: MagnetStarItem?, movies: [MagnetSearchItem]) {
        let clean = starPath.hasPrefix("/") ? String(starPath.dropFirst()) : starPath
        let urlString = page > 1 ? "\(currentHost)/\(clean)/\(page)" : "\(currentHost)/\(clean)"
        guard let url = URL(string: urlString) else {
            throw JavBusError.invalidURL
        }

        let (_, html) = try await fetchData(from: url)
        let star = Self.parseStarHeader(from: html, detailPath: "/\(clean)", baseURLString: currentHost)
        let movies = Self.parseSearchItems(from: html, baseURLString: currentHost)
        return (star, movies)
    }

    // MARK: - 获取影片详情（含参演女优与磁力列表）

    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem]) {
        let cleanPath = item.detailPath.hasPrefix("/") ? String(item.detailPath.dropFirst()) : item.detailPath
        let detailURLString = "\(currentHost)/\(cleanPath)"
        guard let detailURL = URL(string: detailURLString) else {
            throw JavBusError.invalidURL
        }

        let (_, detailHTML) = try await fetchData(from: detailURL)
        let stars = Self.parseStarsFromMovieDetail(detailHTML, baseURLString: currentHost)

        // 解析详情页里的 AJAX 参数：gid, uc, img
        guard let gid = Self.extractRegex(pattern: #"var\s+gid\s*=\s*(\d+);"#, text: detailHTML),
              let uc = Self.extractRegex(pattern: #"var\s+uc\s*=\s*(\d+);"#, text: detailHTML) else {
            let staticMagnets = Self.parseMagnetsFromHTML(detailHTML)
            return (stars, Self.sortMagnets(staticMagnets))
        }

        let img = Self.extractRegex(pattern: #"var\s+img\s*=\s*'([^']*)';"#, text: detailHTML) ?? ""
        let floor = Int.random(in: 100...999)

        let ajaxURLString = "\(currentHost)/ajax/uncensoredcors.php?gid=\(gid)&lang=zh&img=\(img)&uc=\(uc)&floor=\(floor)"
        guard let ajaxURL = URL(string: ajaxURLString) else {
            throw JavBusError.invalidURL
        }

        let (_, ajaxHTML) = try await fetchData(from: ajaxURL, referer: detailURLString, isAJAX: true)
        let parsed = Self.parseMagnetsFromHTML(ajaxHTML)
        return (stars, Self.sortMagnets(parsed))
    }

    func fetchMagnets(for item: MagnetSearchItem) async throws -> [MagnetTorrentItem] {
        let (_, magnets) = try await fetchDetailInfo(for: item)
        return magnets
    }

    // MARK: - HTML 解析逻辑

    static func parseSearchItems(from html: String, baseURLString: String) -> [MagnetSearchItem] {
        var items: [MagnetSearchItem] = []
        let boxPattern = #"<a\s+class="movie-box"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: boxPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches where match.numberOfRanges >= 3 {
            let href = nsString.substring(with: match.range(at: 1))
            let innerContent = nsString.substring(with: match.range(at: 2))

            let imgPattern = #"<img[^>]*src="([^"]+)"[^>]*title="([^"]*)""#
            var coverURL: URL?
            var title = ""
            if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: []),
               let imgMatch = imgRegex.firstMatch(in: innerContent, options: [], range: NSRange(location: 0, length: (innerContent as NSString).length)) {
                let imgSrc = (innerContent as NSString).substring(with: imgMatch.range(at: 1))
                let imgTitle = (innerContent as NSString).substring(with: imgMatch.range(at: 2))
                title = imgTitle
                if let parsed = URL(string: imgSrc) {
                    coverURL = parsed
                } else if let parsed = URL(string: baseURLString + (imgSrc.hasPrefix("/") ? "" : "/") + imgSrc) {
                    coverURL = parsed
                }
            }

            let datePattern = #"<date>([^<]+)<\/date>"#
            var dates: [String] = []
            if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []) {
                let dateMatches = dateRegex.matches(in: innerContent, options: [], range: NSRange(location: 0, length: (innerContent as NSString).length))
                for dMatch in dateMatches where dMatch.numberOfRanges >= 2 {
                    dates.append((innerContent as NSString).substring(with: dMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            let code = dates.first ?? ""
            let releaseDate = dates.count > 1 ? dates[1] : nil

            var detailPath = href
            if let url = URL(string: href), !url.path.isEmpty {
                detailPath = url.path
            }

            if !code.isEmpty || !title.isEmpty {
                items.append(MagnetSearchItem(
                    id: detailPath,
                    code: code,
                    title: title.isEmpty ? code : title,
                    coverURL: coverURL,
                    releaseDate: releaseDate,
                    detailPath: detailPath
                ))
            }
        }

        return items
    }

    static func parseStarItems(from html: String, baseURLString: String) -> [MagnetStarItem] {
        var stars: [MagnetStarItem] = []
        // <a class="avatar-box..." href="https://www.javbus.com/star/xxx"> ... <img src="yyy" title="name"> ... <span>name</span>
        let starPattern = #"<a\s+class="avatar-box[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: starPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches where match.numberOfRanges >= 3 {
            let href = nsString.substring(with: match.range(at: 1))
            let inner = nsString.substring(with: match.range(at: 2))

            var avatarURL: URL?
            var name = ""

            let imgPattern = #"<img[^>]*src="([^"]+)"(?:[^>]*title="([^"]*)")?"#
            if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: []),
               let imgMatch = imgRegex.firstMatch(in: inner, options: [], range: NSRange(location: 0, length: (inner as NSString).length)) {
                let src = (inner as NSString).substring(with: imgMatch.range(at: 1))
                if imgMatch.numberOfRanges >= 3, imgMatch.range(at: 2).location != NSNotFound {
                    name = (inner as NSString).substring(with: imgMatch.range(at: 2))
                }
                if let url = URL(string: src) {
                    avatarURL = url
                } else if let url = URL(string: baseURLString + (src.hasPrefix("/") ? "" : "/") + src) {
                    avatarURL = url
                }
            }

            if name.isEmpty {
                let namePattern = #"<span>([^<]+)<\/span>"#
                if let nameRegex = try? NSRegularExpression(pattern: namePattern, options: []),
                   let nameMatch = nameRegex.firstMatch(in: inner, options: [], range: NSRange(location: 0, length: (inner as NSString).length)) {
                    name = (inner as NSString).substring(with: nameMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            var detailPath = href
            if let url = URL(string: href), !url.path.isEmpty {
                detailPath = url.path
            }

            if !name.isEmpty {
                stars.append(MagnetStarItem(
                    id: detailPath,
                    name: name,
                    avatarURL: avatarURL,
                    detailPath: detailPath
                ))
            }
        }

        return stars
    }

    static func parseStarHeader(from html: String, detailPath: String, baseURLString: String) -> MagnetStarItem? {
        let avatarPattern = #"<div\s+class="avatar-box"[^>]*>[\s\S]*?<img\s+src="([^"]+)"(?:[^>]*title="([^"]*)")?"#
        var avatarURL: URL?
        var name = ""

        if let regex = try? NSRegularExpression(pattern: avatarPattern, options: []),
           let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)) {
            let src = (html as NSString).substring(with: match.range(at: 1))
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                name = (html as NSString).substring(with: match.range(at: 2))
            }
            if let url = URL(string: src) {
                avatarURL = url
            } else if let url = URL(string: baseURLString + (src.hasPrefix("/") ? "" : "/") + src) {
                avatarURL = url
            }
        }

        if name.isEmpty {
            let namePattern = #"<span\s+class="pb10">([^<]+)<\/span>"#
            if let nameRegex = try? NSRegularExpression(pattern: namePattern, options: []),
               let nameMatch = nameRegex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)) {
                name = (html as NSString).substring(with: nameMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 提取个人资料段落
        var bioLines: [String] = []
        let pPattern = #"<p>([^<]+:[^<]+)<\/p>"#
        if let pRegex = try? NSRegularExpression(pattern: pPattern, options: []) {
            let matches = pRegex.matches(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length))
            for m in matches where m.numberOfRanges >= 2 {
                let text = (html as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                bioLines.append(text)
            }
        }

        guard !name.isEmpty else { return nil }
        return MagnetStarItem(
            id: detailPath,
            name: name,
            avatarURL: avatarURL,
            detailPath: detailPath,
            bio: bioLines.isEmpty ? nil : bioLines.joined(separator: " · ")
        )
    }

    static func parseStarsFromMovieDetail(_ html: String, baseURLString: String) -> [MagnetStarItem] {
        var stars: [MagnetStarItem] = []
        // <span class="genre"><a href="https://www.javbus.com/star/xxx">演员名</a></span>
        let pattern = #"<a[^>]*href="([^"]*(?:\/star\/)[^"]+)"[^>]*>([^<]+)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))

        for m in matches where m.numberOfRanges >= 3 {
            let href = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            var path = href
            if let u = URL(string: href), !u.path.isEmpty {
                path = u.path
            }

            if !stars.contains(where: { $0.name == name || $0.detailPath == path }) {
                stars.append(MagnetStarItem(
                    name: name,
                    avatarURL: nil,
                    detailPath: path
                ))
            }
        }
        return stars
    }

    static func parseMagnetsFromHTML(_ html: String) -> [MagnetTorrentItem] {
        var results: [MagnetTorrentItem] = []

        let trPattern = #"<tr[^>]*>([\s\S]*?)<\/tr>"#
        guard let trRegex = try? NSRegularExpression(pattern: trPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let trMatches = trRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for trMatch in trMatches where trMatch.numberOfRanges >= 2 {
            let rowContent = nsString.substring(with: trMatch.range(at: 1))

            let magnetPattern = #"href="(magnet:\?[^"]+)""#
            guard let magRegex = try? NSRegularExpression(pattern: magnetPattern, options: []),
                  let magMatch = magRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) else {
                continue
            }
            let magnetURL = (rowContent as NSString).substring(with: magMatch.range(at: 1))

            let namePattern = #"<a[^>]*href="magnet:[^"]*"[^>]*>([\s\S]*?)<\/a>"#
            var torrentName = ""
            if let nameRegex = try? NSRegularExpression(pattern: namePattern, options: []),
               let nameMatch = nameRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                let rawName = (rowContent as NSString).substring(with: nameMatch.range(at: 1))
                torrentName = rawName.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let sizePattern = #"(\d+(?:\.\d+)?\s*(?:GB|MB|KB|G|M))"#
            var size = "未知大小"
            if let sizeRegex = try? NSRegularExpression(pattern: sizePattern, options: [.caseInsensitive]),
               let sizeMatch = sizeRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                size = (rowContent as NSString).substring(with: sizeMatch.range(at: 1))
            }

            let datePattern = #"(\d{4}-\d{2}-\d{2})"#
            var date: String?
            if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []),
               let dateMatch = dateRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                date = (rowContent as NSString).substring(with: dateMatch.range(at: 1))
            }

            let isHD = rowContent.contains("btn-warning") || rowContent.localizedCaseInsensitiveContains("高清") || rowContent.localizedCaseInsensitiveContains("HD")
            let hasSubtitles = rowContent.contains("btn-primary") || rowContent.contains("字幕") || rowContent.contains("中字")

            results.append(MagnetTorrentItem(
                magnetURL: magnetURL,
                name: torrentName.isEmpty ? "磁力资源" : torrentName,
                size: size,
                date: date,
                isHD: isHD,
                hasSubtitles: hasSubtitles
            ))
        }

        return results
    }

    static func sortMagnets(_ magnets: [MagnetTorrentItem]) -> [MagnetTorrentItem] {
        magnets.sorted { a, b in
            if a.hasSubtitles != b.hasSubtitles {
                return a.hasSubtitles && !b.hasSubtitles
            }
            if a.isHD != b.isHD {
                return a.isHD && !b.isHD
            }
            return false
        }
    }

    private static func extractRegex(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }
}
