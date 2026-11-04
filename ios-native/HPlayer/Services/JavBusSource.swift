import Foundation

enum JavBusError: LocalizedError {
    case invalidURL
    case cloudflareBlocked
    case ageVerificationRequired
    case notFound
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
        case .ageVerificationRequired:
            return "站点要求年龄验证，自动验证未通过，请更换镜像域名后重试"
        case .notFound:
            return "未找到对应页面 (404)"
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

    static let defaultHost = "https://www.javbus.com"
    static let hostDefaultsKey = "hplayer.magnet.javbus_host"

    /// 磁力列表的 AJAX 接口，依次尝试，直到拿到磁力为止。
    static let magnetAjaxEndpoints = ["uncensoredcors.php", "uncledatoolsbyajax.php"]

    /// existmag=all：显示全部磁力；age=verified、dv=1：跳过「年龄验证」页。
    /// 不带后两个 Cookie 时，站点会把所有页面都换成年龄验证页，解析不到任何数据。
    static let requiredCookies: [(name: String, value: String)] = [
        ("existmag", "all"),
        ("age", "verified"),
        ("dv", "1"),
    ]

    let name = "JavBus"

    private let session: URLSession

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

    // MARK: - 域名

    /// 把用户输入整理成 `scheme://host[:port]`；缺少 scheme 时补 https，非法输入返回 nil。
    static func normalizedHost(_ raw: String) -> String? {
        var text = trim(raw)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host.contains(".") else {
            return nil
        }
        var result = "\(scheme)://\(host)"
        if let port = components.port {
            result += ":\(port)"
        }
        return result
    }

    /// 当前配置的基础访问域名（支持用户在设置中自定义镜像站）。
    var currentHost: String {
        let custom = UserDefaults.standard.string(forKey: Self.hostDefaultsKey) ?? ""
        return Self.normalizedHost(custom) ?? Self.defaultHost
    }

    private func makeURL(path: String) -> URL? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(currentHost)/\(clean)")
    }

    // MARK: - 网络请求

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private var mobileUserAgent: String { Self.userAgent }

    /// 取封面、头像时要带的请求头：站点的图片做了防盗链，没有 Referer / 浏览器 UA 会被拒绝（403）。
    /// 只对 JavBus 自己的域名（默认域名和当前配置的镜像域名及其子域名）生效，别的图床不加。
    static func imageHeaders(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased() else { return [:] }

        func registrable(_ host: String) -> String {
            host.split(separator: ".").suffix(2).joined(separator: ".")
        }

        let base = JavBusSource.shared.currentHost
        let known = [URL(string: base)?.host, URL(string: defaultHost)?.host].compactMap { $0?.lowercased() }
        guard known.contains(where: { $0 == host || registrable($0) == registrable(host) }) else { return [:] }

        return [
            "Referer": base + "/",
            "User-Agent": userAgent,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        ]
    }

    private static func installCookies(in storage: HTTPCookieStorage, for url: URL) {
        guard let host = url.host else { return }
        for cookie in requiredCookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: host,
                .path: "/",
                .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 30),
            ]
            if let httpCookie = HTTPCookie(properties: properties) {
                storage.setCookie(httpCookie)
            }
        }
    }

    private func makeRequest(url: URL, referer: String? = nil, isAJAX: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        if let storage = session.configuration.httpCookieStorage {
            Self.installCookies(in: storage, for: url)
        } else {
            let header = Self.requiredCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        if let referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if isAJAX {
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        return req
    }

    /// 发一次请求并检查状态码：404 → `.notFound`，403/503 → Cloudflare 拦截。任务被取消时抛 `CancellationError`。
    private func send(_ req: URLRequest) async throws -> (html: String, finalURL: URL?) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw JavBusError.network(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:
                break
            case 404:
                throw JavBusError.notFound
            case 403, 503:
                throw JavBusError.cloudflareBlocked
            default:
                throw JavBusError.serverError(http.statusCode)
            }
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if Self.isCloudflareChallenge(html) {
            throw JavBusError.cloudflareBlocked
        }
        return (html, response.url)
    }

    static func isCloudflareChallenge(_ html: String) -> Bool {
        html.contains("cf-browser-verification") || html.contains("cf-challenge")
    }

    /// JavBus 的「你是否已經成年?」页面（地区年龄检测）。
    static func isAgeVerificationPage(_ html: String) -> Bool {
        html.contains("id=\"ageVerify\"")
    }

    private func fetchData(from url: URL, referer: String? = nil, isAJAX: Bool = false) async throws -> String {
        let first = try await send(makeRequest(url: url, referer: referer, isAJAX: isAJAX))
        guard Self.isAgeVerificationPage(first.html) else {
            return first.html
        }

        // Cookie 没能跳过验证页时，提交一次「我已成年」表单再重试。
        await submitAgeVerification(verifyURL: first.finalURL, originalURL: url)
        let second = try await send(makeRequest(url: url, referer: referer, isAJAX: isAJAX))
        if Self.isAgeVerificationPage(second.html) {
            throw JavBusError.ageVerificationRequired
        }
        return second.html
    }

    private func submitAgeVerification(verifyURL: URL?, originalURL: URL) async {
        let target: URL
        if let verifyURL, verifyURL.path.contains("driver-verify") {
            target = verifyURL
        } else {
            var components = URLComponents(string: currentHost)
            components?.path = "/doc/driver-verify"
            components?.queryItems = [URLQueryItem(name: "referer", value: originalURL.absoluteString)]
            guard let built = components?.url else { return }
            target = built
        }

        var req = makeRequest(url: target, referer: target.absoluteString)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("Submit=%E7%A2%BA%E8%AA%8D".utf8)
        _ = try? await send(req)
    }

    /// 404 视为「没有内容」（搜索无结果、翻页翻过头），返回 nil。
    private func fetchHTMLOrNil(_ url: URL) async throws -> String? {
        do {
            return try await fetchData(from: url)
        } catch JavBusError.notFound {
            return nil
        }
    }

    // MARK: - 路径编码

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    static func encodePathSegment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? text
    }

    // MARK: - 搜索影片

    func search(keyword: String, page: Int = 1) async throws -> [MagnetSearchItem] {
        let trimmed = Self.trim(keyword)
        guard !trimmed.isEmpty else { return [] }

        let encoded = Self.encodePathSegment(trimmed)
        let path = page > 1 ? "search/\(encoded)/\(page)" : "search/\(encoded)"
        guard let url = makeURL(path: path) else {
            throw JavBusError.invalidURL
        }

        guard let html = try await fetchHTMLOrNil(url) else { return [] }
        return Self.parseSearchItems(from: html, baseURLString: currentHost)
    }

    /// 同时搜影片和女优。女优搜索失败（番号搜不到女优、404 等）不影响影片结果。
    func searchAll(keyword: String, page: Int = 1) async throws -> (movies: [MagnetSearchItem], stars: [MagnetStarItem]) {
        async let movies = search(keyword: keyword, page: page)
        async let stars = searchActressesOrEmpty(keyword)
        return try await (movies, stars)
    }

    private func searchActressesOrEmpty(_ name: String) async -> [MagnetStarItem] {
        (try? await searchActresses(name: name)) ?? []
    }

    // MARK: - 分类列表浏览（最新、无码）

    func fetchCategory(_ category: MagnetCategory, page: Int = 1) async throws -> [MagnetSearchItem] {
        let path: String
        switch category {
        case .latest:
            path = page > 1 ? "page/\(page)" : ""
        case .uncensored:
            path = page > 1 ? "uncensored/page/\(page)" : "uncensored"
        case .actresses:
            return []
        }

        guard let url = makeURL(path: path) else {
            throw JavBusError.invalidURL
        }

        guard let html = try await fetchHTMLOrNil(url) else { return [] }
        return Self.parseSearchItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 女优浏览与搜索

    func fetchActresses(page: Int = 1) async throws -> [MagnetStarItem] {
        let path = page > 1 ? "actresses/\(page)" : "actresses"
        guard let url = makeURL(path: path) else {
            throw JavBusError.invalidURL
        }

        guard let html = try await fetchHTMLOrNil(url) else { return [] }
        return Self.parseStarItems(from: html, baseURLString: currentHost)
    }

    func searchActresses(name: String) async throws -> [MagnetStarItem] {
        let trimmed = Self.trim(name)
        guard !trimmed.isEmpty else { return [] }

        let encoded = Self.encodePathSegment(trimmed)
        guard let url = makeURL(path: "searchstar/\(encoded)") else {
            throw JavBusError.invalidURL
        }

        guard let html = try await fetchHTMLOrNil(url) else { return [] }
        return Self.parseStarItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 女优专属作品列表

    func fetchStarDetail(starPath: String, page: Int = 1) async throws -> (star: MagnetStarItem?, movies: [MagnetSearchItem]) {
        let clean = starPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = page > 1 ? "\(clean)/\(page)" : clean
        guard let url = makeURL(path: path) else {
            throw JavBusError.invalidURL
        }

        let host = currentHost
        if page > 1 {
            // 翻过最后一页时站点返回 404，当作没有更多作品。
            guard let html = try await fetchHTMLOrNil(url) else { return (nil, []) }
            return (nil, Self.parseSearchItems(from: html, baseURLString: host))
        }

        let html = try await fetchData(from: url)
        let star = Self.parseStarHeader(from: html, detailPath: "/\(clean)", baseURLString: host)
        let movies = Self.parseSearchItems(from: html, baseURLString: host)
        return (star, movies)
    }

    // MARK: - 获取影片详情（含参演女优与磁力列表）

    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem]) {
        guard let detailURL = makeURL(path: item.detailPath) else {
            throw JavBusError.invalidURL
        }

        let host = currentHost
        let detailHTML = try await fetchData(from: detailURL)
        let stars = Self.parseStarsFromMovieDetail(detailHTML, baseURLString: host)

        // 解析详情页里的 AJAX 参数：gid, uc, img
        guard let gid = Self.extractRegex(pattern: #"var\s+gid\s*=\s*(\d+);"#, text: detailHTML),
              let uc = Self.extractRegex(pattern: #"var\s+uc\s*=\s*(\d+);"#, text: detailHTML) else {
            return (stars, Self.sortMagnets(Self.parseMagnetsFromHTML(detailHTML)))
        }

        let img = Self.extractRegex(pattern: #"var\s+img\s*=\s*'([^']*)';"#, text: detailHTML) ?? ""
        let floor = Int.random(in: 100...999)

        for endpoint in Self.magnetAjaxEndpoints {
            guard let ajaxURL = Self.makeAjaxURL(host: host, endpoint: endpoint, gid: gid, uc: uc, img: img, floor: floor) else {
                continue
            }
            do {
                let ajaxHTML = try await fetchData(from: ajaxURL, referer: detailURL.absoluteString, isAJAX: true)
                let parsed = Self.parseMagnetsFromHTML(ajaxHTML)
                if !parsed.isEmpty {
                    return (stars, Self.sortMagnets(parsed))
                }
            } catch JavBusError.notFound {
                continue
            }
        }

        // AJAX 都没有结果时，退回详情页里直接写着的磁力。
        return (stars, Self.sortMagnets(Self.parseMagnetsFromHTML(detailHTML)))
    }

    func fetchMagnets(for item: MagnetSearchItem) async throws -> [MagnetTorrentItem] {
        let (_, magnets) = try await fetchDetailInfo(for: item)
        return magnets
    }

    static func makeAjaxURL(host: String, endpoint: String, gid: String, uc: String, img: String, floor: Int) -> URL? {
        guard var components = URLComponents(string: host) else { return nil }
        components.path = "/ajax/\(endpoint)"
        components.queryItems = [
            URLQueryItem(name: "gid", value: gid),
            URLQueryItem(name: "lang", value: "zh"),
            URLQueryItem(name: "img", value: img),
            URLQueryItem(name: "uc", value: uc),
            URLQueryItem(name: "floor", value: String(floor)),
        ]
        return components.url
    }

    // MARK: - 解析辅助

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉标签、解码实体、把连续空白压成一个空格。
    private static func plainText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeHTMLEntities(stripped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func makeRegex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func fullRange(_ text: NSString) -> NSRange {
        NSRange(location: 0, length: text.length)
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: NSString) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: range)
    }

    /// 解码常见 HTML 实体（&amp; &quot; &#39; &#x27; 等）。
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text

        if let regex = makeRegex("&#([xX]?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            // 从后往前替换，前面的匹配位置不受影响。
            for match in regex.matches(in: result, options: [], range: fullRange(ns)).reversed() {
                guard let prefix = capture(match, 1, in: ns),
                      let digits = capture(match, 2, in: ns),
                      let value = UInt32(digits, radix: prefix.isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(value),
                      let range = Range(match.range, in: result) else {
                    continue
                }
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }

        let named: [(String, String)] = [
            ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // &amp; 放最后，避免 &amp;lt; 被解码两次。
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 把页面里的地址补成绝对地址：支持绝对、`//host/x`、`/x`、`x` 四种写法。
    /// 注意 `URL(string: "/x")` 不会返回 nil 而是相对 URL，所以必须显式拼上域名。
    static func resolveURL(_ raw: String, baseURLString: String) -> URL? {
        let text = trim(decodeHTMLEntities(raw))
        guard !text.isEmpty else { return nil }

        let base = URL(string: baseURLString)
        if text.hasPrefix("//") {
            return URL(string: "\(base?.scheme ?? "https"):\(text)")
        }
        if let url = URL(string: text), url.scheme != nil, url.host != nil {
            return url
        }
        guard let base else { return URL(string: text) }
        return URL(string: text, relativeTo: base)?.absoluteURL
    }

    /// 取链接的路径部分（去掉域名和查询串），作为站内详情页路径。
    static func detailPath(from href: String) -> String {
        let decoded = trim(decodeHTMLEntities(href))
        if let url = URL(string: decoded), !url.path.isEmpty {
            return url.path
        }
        return decoded
    }

    // MARK: - HTML 解析逻辑

    static func parseSearchItems(from html: String, baseURLString: String) -> [MagnetSearchItem] {
        guard let boxRegex = makeRegex(#"<a\s+class="movie-box[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#),
              let imgRegex = makeRegex(#"<img[^>]*src="([^"]+)"[^>]*title="([^"]*)""#),
              let dateRegex = makeRegex(#"<date>([^<]+)<\/date>"#) else {
            return []
        }

        let nsHTML = html as NSString
        var items: [MagnetSearchItem] = []
        var seen = Set<String>()

        for match in boxRegex.matches(in: html, options: [], range: fullRange(nsHTML)) {
            guard let href = capture(match, 1, in: nsHTML),
                  let inner = capture(match, 2, in: nsHTML) else {
                continue
            }
            let nsInner = inner as NSString

            var coverURL: URL?
            var title = ""
            if let imgMatch = imgRegex.firstMatch(in: inner, options: [], range: fullRange(nsInner)) {
                if let src = capture(imgMatch, 1, in: nsInner) {
                    coverURL = resolveURL(src, baseURLString: baseURLString)
                }
                title = trim(decodeHTMLEntities(capture(imgMatch, 2, in: nsInner) ?? ""))
            }

            var dates: [String] = []
            for dateMatch in dateRegex.matches(in: inner, options: [], range: fullRange(nsInner)) {
                if let value = capture(dateMatch, 1, in: nsInner) {
                    dates.append(trim(value))
                }
            }

            let code = dates.first ?? ""
            let releaseDate = dates.count > 1 ? dates[1] : nil
            let path = detailPath(from: href)

            guard !code.isEmpty || !title.isEmpty, seen.insert(path).inserted else { continue }
            items.append(MagnetSearchItem(
                id: path,
                code: code,
                title: title.isEmpty ? code : title,
                coverURL: coverURL,
                releaseDate: releaseDate,
                detailPath: path
            ))
        }

        return items
    }

    static func parseStarItems(from html: String, baseURLString: String) -> [MagnetStarItem] {
        // <a class="avatar-box..." href="https://www.javbus.com/star/xxx"> ... <img src="yyy" title="name"> ... <span>name</span>
        guard let starRegex = makeRegex(#"<a\s+class="avatar-box[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#),
              let imgRegex = makeRegex(#"<img[^>]*src="([^"]+)"(?:[^>]*title="([^"]*)")?"#),
              let spanRegex = makeRegex(#"<span>([^<]+)<\/span>"#) else {
            return []
        }

        let nsHTML = html as NSString
        var stars: [MagnetStarItem] = []
        var seen = Set<String>()

        for match in starRegex.matches(in: html, options: [], range: fullRange(nsHTML)) {
            guard let href = capture(match, 1, in: nsHTML),
                  let inner = capture(match, 2, in: nsHTML) else {
                continue
            }
            let nsInner = inner as NSString

            var avatarURL: URL?
            var name = ""
            if let imgMatch = imgRegex.firstMatch(in: inner, options: [], range: fullRange(nsInner)) {
                if let src = capture(imgMatch, 1, in: nsInner) {
                    avatarURL = resolveURL(src, baseURLString: baseURLString)
                }
                name = trim(decodeHTMLEntities(capture(imgMatch, 2, in: nsInner) ?? ""))
            }
            if name.isEmpty,
               let spanMatch = spanRegex.firstMatch(in: inner, options: [], range: fullRange(nsInner)),
               let text = capture(spanMatch, 1, in: nsInner) {
                name = trim(decodeHTMLEntities(text))
            }

            let path = detailPath(from: href)
            guard !name.isEmpty, seen.insert(path).inserted else { continue }
            stars.append(MagnetStarItem(id: path, name: name, avatarURL: avatarURL, detailPath: path))
        }

        return stars
    }

    static func parseStarHeader(from html: String, detailPath: String, baseURLString: String) -> MagnetStarItem? {
        let nsHTML = html as NSString
        var avatarURL: URL?
        var name = ""

        if let avatarRegex = makeRegex(#"<div\s+class="avatar-box"[^>]*>[\s\S]*?<img\s+src="([^"]+)"(?:[^>]*title="([^"]*)")?"#),
           let match = avatarRegex.firstMatch(in: html, options: [], range: fullRange(nsHTML)) {
            if let src = capture(match, 1, in: nsHTML) {
                avatarURL = resolveURL(src, baseURLString: baseURLString)
            }
            name = trim(decodeHTMLEntities(capture(match, 2, in: nsHTML) ?? ""))
        }

        if name.isEmpty,
           let nameRegex = makeRegex(#"<span\s+class="pb10">([^<]+)<\/span>"#),
           let match = nameRegex.firstMatch(in: html, options: [], range: fullRange(nsHTML)),
           let text = capture(match, 1, in: nsHTML) {
            name = trim(decodeHTMLEntities(text))
        }

        // 个人资料段落，形如 <p>生日: 1993-08-16</p>；冒号前的字段名不会很长，借此过滤掉页面里别的 <p>。
        var bioLines: [String] = []
        if let bioRegex = makeRegex(#"<p>([^<]*[:：][^<]*)<\/p>"#) {
            for match in bioRegex.matches(in: html, options: [], range: fullRange(nsHTML)) {
                guard let raw = capture(match, 1, in: nsHTML) else { continue }
                let text = trim(decodeHTMLEntities(raw))
                guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }),
                      text.distance(from: text.startIndex, to: colon) <= 8 else {
                    continue
                }
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
        // <span class="genre"><a href="https://www.javbus.com/star/xxx">演员名</a></span>
        guard let regex = makeRegex(#"<a[^>]*href="([^"]*(?:\/star\/)[^"]+)"[^>]*>([^<]+)<\/a>"#) else {
            return []
        }

        let ns = html as NSString
        var stars: [MagnetStarItem] = []

        for match in regex.matches(in: html, options: [], range: fullRange(ns)) {
            guard let href = capture(match, 1, in: ns),
                  let rawName = capture(match, 2, in: ns) else {
                continue
            }
            let name = trim(decodeHTMLEntities(rawName))
            guard !name.isEmpty else { continue }

            let path = detailPath(from: href)
            if !stars.contains(where: { $0.name == name || $0.detailPath == path }) {
                stars.append(MagnetStarItem(name: name, avatarURL: nil, detailPath: path))
            }
        }
        return stars
    }

    static func parseMagnetsFromHTML(_ html: String) -> [MagnetTorrentItem] {
        guard let rowRegex = makeRegex(#"<tr[^>]*>([\s\S]*?)<\/tr>"#),
              let cellRegex = makeRegex(#"<td[^>]*>([\s\S]*?)<\/td>"#),
              let magnetRegex = makeRegex(#"href="(magnet:\?[^"]+)""#),
              let nameRegex = makeRegex(#"<a[^>]*href="magnet:[^"]*"[^>]*>([\s\S]*?)<\/a>"#),
              let sizeRegex = makeRegex(#"(\d+(?:\.\d+)?\s*(?:TB|GB|MB|KB|G|M))(?![A-Za-z0-9])"#, caseInsensitive: true),
              let dateRegex = makeRegex(#"(\d{4}-\d{2}-\d{2})"#),
              let hdRegex = makeRegex(#"(?<![A-Za-z0-9])(?:F|U)?HD(?![A-Za-z0-9])"#, caseInsensitive: true) else {
            return []
        }

        /// 先去掉 href="magnet:..."：磁力地址里的哈希、dn 参数不能当成大小、日期或 HD 标记。
        func withoutHrefs(_ text: String) -> String {
            text.replacingOccurrences(of: #"href="magnet:[^"]*""#, with: "", options: .regularExpression)
        }

        func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange(ns)) else { return nil }
            return capture(match, 1, in: ns)
        }

        let nsHTML = html as NSString
        var results: [MagnetTorrentItem] = []
        var seen = Set<String>()

        for rowMatch in rowRegex.matches(in: html, options: [], range: fullRange(nsHTML)) {
            guard let row = capture(rowMatch, 1, in: nsHTML) else { continue }
            let nsRow = row as NSString

            guard let magnetMatch = magnetRegex.firstMatch(in: row, options: [], range: fullRange(nsRow)),
                  let rawMagnet = capture(magnetMatch, 1, in: nsRow) else {
                continue
            }
            let magnetURL = decodeHTMLEntities(rawMagnet)
            guard seen.insert(magnetURL).inserted else { continue }

            // 第 1 格：名称 + 高清/字幕标签；第 2 格：大小；第 3 格：日期。
            let cells = cellRegex.matches(in: row, options: [], range: fullRange(nsRow))
                .compactMap { capture($0, 1, in: nsRow) }
            let infoCell = cells.first ?? row

            var torrentName = ""
            if let rawName = firstCapture(nameRegex, in: infoCell) {
                torrentName = plainText(rawName)
            }

            let infoFlat = withoutHrefs(infoCell)
            let infoText = plainText(infoFlat)
            let isHD = infoFlat.contains("btn-warning")
                || infoText.contains("高清")
                || hdRegex.firstMatch(in: infoText, options: [], range: fullRange(infoText as NSString)) != nil
            let hasSubtitles = infoFlat.contains("btn-primary")
                || infoText.contains("字幕")
                || infoText.contains("中字")

            let rowText = plainText(withoutHrefs(row))
            let sizeText = cells.count > 1 ? plainText(withoutHrefs(cells[1])) : rowText
            let dateText = cells.count > 2 ? plainText(withoutHrefs(cells[2])) : rowText
            let size = firstCapture(sizeRegex, in: sizeText) ?? firstCapture(sizeRegex, in: rowText) ?? "未知大小"
            let date = firstCapture(dateRegex, in: dateText) ?? firstCapture(dateRegex, in: rowText)

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
        guard let regex = makeRegex(pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange(ns)) else { return nil }
        return capture(match, 1, in: ns)
    }
}
