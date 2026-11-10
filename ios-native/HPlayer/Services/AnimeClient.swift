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

    private func request<T: Codable>(path: String, method: String = "GET", body: Data? = nil,
                                     redirectDepth: Int = 0, tokenRetried: Bool = false) async throws -> T {
        let cleanPath = path.replacingOccurrences(of: "/?", with: "?")
        let transport = AnimeTransport(host: host, fallbackIPs: fallbackIPs)
        let result = try await transport.send(path: cleanPath, method: method,
                                              headers: AnimeSigner.shared.headers(), body: body)

        // 带尾斜杠的路径会 301，跟一次 Location
        if (result.status == 301 || result.status == 302), let loc = result.location, redirectDepth < 3 {
            return try await request(path: loc, method: method, body: body, redirectDepth: redirectDepth + 1)
        }

        let data = result.data
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
            // 50014 = 令牌失效：丢掉手里的令牌，不带令牌重发一次，让服务端重新下发
            if apiRes.code == 50014, !tokenRetried {
                AnimeSigner.shared.discardIssuedToken()
                return try await request(path: path, method: method, body: body, tokenRetried: true)
            }
            throw AnimeClientError.serverError(code: apiRes.code, message: apiRes.message)
        }

        guard let payload = apiRes.data else {
            throw AnimeClientError.emptyData
        }

        return payload
    }

    /// 不按固定模型解码，直接返回外壳里的 `data`（JSON 对象）。评论接口的字段 API 文档没有展开，
    /// 用这个拿到原始结构再宽松解析（见 AnimeComment）。
    private func requestJSON(path: String, tokenRetried: Bool = false) async throws -> Any {
        let cleanPath = path.replacingOccurrences(of: "/?", with: "?")
        let transport = AnimeTransport(host: host, fallbackIPs: fallbackIPs)
        let result = try await transport.send(path: cleanPath, method: "GET",
                                              headers: AnimeSigner.shared.headers(), body: nil)
        guard let rawString = String(data: result.data, encoding: .utf8) else {
            throw AnimeClientError.networkError("无法解析服务器响应内容")
        }
        let plainJSON = try AnimeCrypto.shared.decryptAPIResponse(rawString)
        guard let jsonData = plainJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AnimeClientError.networkError("解密后数据编码异常")
        }
        let code = (object["code"] as? Int) ?? Int("\(object["code"] ?? "")") ?? 0
        guard code == 20000 else {
            if code == 50014, !tokenRetried {
                AnimeSigner.shared.discardIssuedToken()
                return try await requestJSON(path: path, tokenRetried: true)
            }
            throw AnimeClientError.serverError(code: code, message: object["message"] as? String ?? "")
        }
        return object["data"] ?? NSNull()
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

    /// 一段弹幕：按播放进度 60 秒一段拉取（毫秒时间点）。没有弹幕时返回空数组。
    func fetchDanmaku(id: Int, play: String, part: String, startMs: Int, endMs: Int) async throws -> [AnimeDanmaku] {
        guard let encodedPart = part.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedPlay = play.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw AnimeClientError.invalidURL
        }
        let path = "/app/danmu?vid=\(id)&play=\(encodedPlay)&part=\(encodedPart)&start_time_point=\(startMs)&end_time_point=\(endMs)"
        let data = try await requestJSON(path: path)
        return AnimeDanmaku.list(from: data)
    }

    /// 评论：置顶（gettop）、高赞（gethitstop）、分页列表（getlist）。
    func fetchComments(_ kind: AnimeCommentKind, vid: Int, page: Int = 1, limit: Int = 20) async throws -> AnimeCommentPage {
        let path: String
        switch kind {
        case .top: path = "/app/vod_comment/gettop?vid=\(vid)"
        case .hot: path = "/app/vod_comment/gethitstop?vid=\(vid)"
        case .list: path = "/app/vod_comment/getlist?vid=\(vid)&limit=\(limit)&page=\(page)"
        }
        let data = try await requestJSON(path: path)
        let records = AnimeJSON.records(in: data)
        return AnimeCommentPage(items: records.compactMap { AnimeComment(json: $0, kind: kind) },
                                rawCount: records.count)
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
