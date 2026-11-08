import Foundation

enum AnimeClientError: LocalizedError {
    case invalidURL
    case networkError(String)
    case serverError(code: Int, message: String)
    case emptyData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的请求地址"
        case .networkError(let msg): return "网络请求失败: \(msg)"
        case .serverError(let code, let msg): return "接口返回错误 (\(code)): \(msg)"
        case .emptyData: return "接口返回数据为空"
        }
    }
}

final class AnimeClient {
    static let shared = AnimeClient()

    private let host = "bkbfdm.cenmo.fun"
    private let fallbackIPs = ["120.240.157.64", "183.232.189.187", "111.29.14.203", "183.214.145.89"]

    private init() {}

    // MARK: - 基础请求执行流水线

    private func request<T: Codable>(path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let cleanPath = path.replacingOccurrences(of: "/?", with: "?")

        // 尝试通过主域名请求
        if let result: T = try? await performRequest(hostHeader: host, targetHost: host, path: cleanPath, method: method, body: body) {
            return result
        }

        // 域名请求失败，尝试备用 IP 池
        for ip in fallbackIPs {
            if let result: T = try? await performRequest(hostHeader: host, targetHost: ip, path: cleanPath, method: method, body: body) {
                return result
            }
        }

        throw AnimeClientError.networkError("所有动漫服务节点均无法连接")
    }

    private func performRequest<T: Codable>(hostHeader: String, targetHost: String, path: String, method: String, body: Data?) async throws -> T {
        let urlString = "http://\(targetHost)\(path)"
        guard let url = URL(string: urlString) else {
            throw AnimeClientError.invalidURL
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.httpBody = body

        let headers = AnimeSigner.shared.headers()
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue(hostHeader, forHTTPHeaderField: "Host")

        let (data, response) = try await URLSession.shared.data(for: req)

        // 处理重定向
        if let httpRes = response as? HTTPURLResponse, (httpRes.statusCode == 301 || httpRes.statusCode == 302),
           let loc = httpRes.allHeaderFields["Location"] as? String ?? httpRes.allHeaderFields["location"] as? String {
            return try await request(path: loc, method: method, body: body)
        }

        guard let rawString = String(data: data, encoding: .utf8) else {
            throw AnimeClientError.networkError("无法解析服务器响应内容")
        }

        // 混合解密
        let plainJSON = try AnimeCrypto.shared.decryptAPIResponse(rawString)
        guard let jsonData = plainJSON.data(using: .utf8) else {
            throw AnimeClientError.networkError("解密后数据编码异常")
        }

        let apiRes = try JSONDecoder().decode(AnimeAPIResponse<T>.self, from: jsonData)
        guard apiRes.code == 20000 else {
            throw AnimeClientError.serverError(code: apiRes.code, message: apiRes.message)
        }

        guard let payload = apiRes.data else {
            throw AnimeClientError.emptyData
        }

        return payload
    }

    // MARK: - 业务接口方法

    /// 顶级频道分类列表
    func fetchChannels() async throws -> [AnimeChannel] {
        try await request(path: "/app/channel?top-level=true")
    }

    /// 首页轮播图
    func fetchBanners() async throws -> [AnimeBanner] {
        try await request(path: "/app/banners")
    }

    /// 视频列表（支持分类与排序）
    func fetchVideoList(channel: Int? = nil, sort: String = "weight", limit: Int = 18, page: Int = 1) async throws -> AnimeVideoListResult {
        var queryItems: [String] = ["sort=\(sort)", "limit=\(limit)", "page=\(page)"]
        if let channel {
            queryItems.append("channel=\(channel)")
        }
        let path = "/app/video/list?" + queryItems.joined(separator: "&")
        return try await request(path: path)
    }

    /// 关键词搜索
    func search(keyword: String, limit: Int = 20, page: Int = 1) async throws -> AnimeVideoListResult {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return AnimeVideoListResult(total: 0, items: [])
        }
        let path = "/app/video/search?key=\(encoded)&limit=\(limit)&page=\(page)"
        return try await request(path: path)
    }

    /// 视频详情（含选集与多线路）
    func fetchDetail(id: Int) async throws -> AnimeVideoDetail {
        try await request(path: "/app/video/detail?id=\(id)")
    }

    /// 获取播放凭证 (POST)
    func fetchPlayCredential(id: Int, play: String, part: String) async throws -> AnimePlayResponse {
        guard let encodedPart = part.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedPlay = play.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw AnimeClientError.invalidURL
        }
        let path = "/app/video/play?id=\(id)&play=\(encodedPlay)&part=\(encodedPart)"
        let results: [AnimePlayResponse] = try await request(path: path, method: "POST")
        guard let first = results.first else {
            throw AnimeClientError.emptyData
        }
        return first
    }
}
