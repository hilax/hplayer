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

/// JavBus 磁力抓取与解析引擎。
actor JavBusSource: MagnetSearchSource {
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

    // MARK: - 搜索

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

        var request = URLRequest(url: url)
        request.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        // 设置 existmag=all 让 JavBus 展开全部有磁力条目
        request.setValue("existmag=all", forHTTPHeaderField: "Cookie")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
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

        return Self.parseSearchItems(from: html, baseURLString: currentHost)
    }

    // MARK: - 获取磁力列表

    func fetchMagnets(for item: MagnetSearchItem) async throws -> [MagnetTorrentItem] {
        let cleanPath = item.detailPath.hasPrefix("/") ? String(item.detailPath.dropFirst()) : item.detailPath
        let detailURLString = "\(currentHost)/\(cleanPath)"
        guard let detailURL = URL(string: detailURLString) else {
            throw JavBusError.invalidURL
        }

        var detailRequest = URLRequest(url: detailURL)
        detailRequest.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        detailRequest.setValue("zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        detailRequest.setValue("existmag=all", forHTTPHeaderField: "Cookie")

        let (detailData, detailResponse): (Data, URLResponse)
        do {
            (detailData, detailResponse) = try await session.data(for: detailRequest)
        } catch {
            throw JavBusError.network(error)
        }

        if let http = detailResponse as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 503 {
                throw JavBusError.cloudflareBlocked
            }
            guard (200...299).contains(http.statusCode) else {
                throw JavBusError.serverError(http.statusCode)
            }
        }

        let detailHTML = String(data: detailData, encoding: .utf8) ?? String(decoding: detailData, as: UTF8.self)
        if detailHTML.contains("cf-browser-verification") || detailHTML.contains("cf-challenge") {
            throw JavBusError.cloudflareBlocked
        }

        // 解析详情页里的 AJAX 参数：gid, uc, img
        guard let gid = Self.extractRegex(pattern: #"var\s+gid\s*=\s*(\d+);"#, text: detailHTML),
              let uc = Self.extractRegex(pattern: #"var\s+uc\s*=\s*(\d+);"#, text: detailHTML) else {
            // 有些影片可能没有磁力或直接在页面内
            return Self.parseMagnetsFromHTML(detailHTML)
        }

        let img = Self.extractRegex(pattern: #"var\s+img\s*=\s*'([^']*)';"#, text: detailHTML) ?? ""
        let floor = Int.random(in: 100...999)

        let ajaxURLString = "\(currentHost)/ajax/uncensoredcors.php?gid=\(gid)&lang=zh&img=\(img)&uc=\(uc)&floor=\(floor)"
        guard let ajaxURL = URL(string: ajaxURLString) else {
            throw JavBusError.invalidURL
        }

        var ajaxRequest = URLRequest(url: ajaxURL)
        ajaxRequest.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        ajaxRequest.setValue(detailURLString, forHTTPHeaderField: "Referer")
        ajaxRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        ajaxRequest.setValue("existmag=all", forHTTPHeaderField: "Cookie")

        let (ajaxData, ajaxResponse): (Data, URLResponse)
        do {
            (ajaxData, ajaxResponse) = try await session.data(for: ajaxRequest)
        } catch {
            throw JavBusError.network(error)
        }

        if let http = ajaxResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw JavBusError.serverError(http.statusCode)
        }

        let ajaxHTML = String(data: ajaxData, encoding: .utf8) ?? String(decoding: ajaxData, as: UTF8.self)
        let parsed = Self.parseMagnetsFromHTML(ajaxHTML)
        return Self.sortMagnets(parsed)
    }

    // MARK: - HTML 解析逻辑（非隔离静态方法，便于测试）

    nonisolated static func parseSearchItems(from html: String, baseURLString: String) -> [MagnetSearchItem] {
        var items: [MagnetSearchItem] = []

        // 匹配每个 movie-box：<a class="movie-box" href="https://www.javbus.com/xxx"> ... </a>
        let boxPattern = #"<a\s+class="movie-box"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: boxPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches where match.numberOfRanges >= 3 {
            let href = nsString.substring(with: match.range(at: 1))
            let innerContent = nsString.substring(with: match.range(at: 2))

            // 提取封面和标题：<img src="xxx" title="yyy">
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

            // 提取两个 <date>：第一个通常为番号，第二个为日期
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

            // 提取详情 path
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

    nonisolated static func parseMagnetsFromHTML(_ html: String) -> [MagnetTorrentItem] {
        var results: [MagnetTorrentItem] = []

        // 磁力表格行：<tr onmouseover... >...</tr>
        let trPattern = #"<tr[^>]*>([\s\S]*?)<\/tr>"#
        guard let trRegex = try? NSRegularExpression(pattern: trPattern, options: []) else {
            return []
        }

        let nsString = html as NSString
        let trMatches = trRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        for trMatch in trMatches where trMatch.numberOfRanges >= 2 {
            let rowContent = nsString.substring(with: trMatch.range(at: 1))

            // 提取磁力链接
            let magnetPattern = #"href="(magnet:\?[^"]+)""#
            guard let magRegex = try? NSRegularExpression(pattern: magnetPattern, options: []),
                  let magMatch = magRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) else {
                continue
            }
            let magnetURL = (rowContent as NSString).substring(with: magMatch.range(at: 1))

            // 提取名称：通常在磁力 <a> 标签内文字，或紧随其后的文本
            let namePattern = #"<a[^>]*href="magnet:[^"]*"[^>]*>([\s\S]*?)<\/a>"#
            var torrentName = ""
            if let nameRegex = try? NSRegularExpression(pattern: namePattern, options: []),
               let nameMatch = nameRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                let rawName = (rowContent as NSString).substring(with: nameMatch.range(at: 1))
                // 去掉内部的 html 标签
                torrentName = rawName.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 提取文件大小（如 4.25GB 或 800MB）
            let sizePattern = #"(\d+(?:\.\d+)?\s*(?:GB|MB|KB|G|M))"#
            var size = "未知大小"
            if let sizeRegex = try? NSRegularExpression(pattern: sizePattern, options: [.caseInsensitive]),
               let sizeMatch = sizeRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                size = (rowContent as NSString).substring(with: sizeMatch.range(at: 1))
            }

            // 提取日期（YYYY-MM-DD）
            let datePattern = #"(\d{4}-\d{2}-\d{2})"#
            var date: String?
            if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []),
               let dateMatch = dateRegex.firstMatch(in: rowContent, options: [], range: NSRange(location: 0, length: (rowContent as NSString).length)) {
                date = (rowContent as NSString).substring(with: dateMatch.range(at: 1))
            }

            // 标签：高清、字幕
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

    /// 智能排序：有字幕优先 > 高清优先
    nonisolated static func sortMagnets(_ magnets: [MagnetTorrentItem]) -> [MagnetTorrentItem] {
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

    nonisolated private static func extractRegex(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }
}
