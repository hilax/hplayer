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
        case .serverError(let code, let msg): return msg.isEmpty ? "接口返回错误（\(code)）" : msg
        case .emptyData: return "接口返回数据为空"
        }
    }
}

/// 接口外壳：业务码、说明、data，以及解密后的原文（诊断页用）
struct AnimeEnvelope {
    let code: Int
    let message: String
    let data: Any
    let raw: String
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

    // MARK: - 账号、评论、弹幕这些写接口

    /// 先用一个轻量 GET 把可用节点选出来并锁定。选路会把同一个请求在几个节点上各发一次，
    /// 写接口（登录、发弹幕、发评论）不能这样发，所以写之前保证已经锁定了节点。
    private func ensureRoute() async {
        if await AnimeEndpointCache.shared.target(for: host) != nil { return }
        _ = try? await requestJSON(path: "/app/task/sign_rule")
    }

    /// 发一个请求并原样返回外壳（code / message / data），业务码交给调用方判断。
    /// `body` 不为 nil 时按 send_key 混合加密后提交（API 文档 §8.4）。
    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> AnimeEnvelope {
        if method != "GET" { await ensureRoute() }
        var payload: Data?
        if let body {
            let json = try JSONSerialization.data(withJSONObject: body)
            payload = Data(try AnimeCrypto.shared.encryptRequest(json).utf8)
        }
        let transport = AnimeTransport(host: host, fallbackIPs: fallbackIPs)
        let result = try await transport.send(path: path, method: method,
                                              headers: AnimeSigner.shared.headers(), body: payload)
        guard let rawString = String(data: result.data, encoding: .utf8) else {
            throw AnimeClientError.networkError("无法解析服务器响应内容")
        }
        let plain = try AnimeCrypto.shared.decryptAPIResponse(rawString)
        guard let jsonData = plain.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AnimeClientError.networkError("解密后数据编码异常")
        }
        let envelope = AnimeEnvelope(code: (object["code"] as? Int) ?? Int("\(object["code"] ?? "")") ?? 0,
                                     message: object["message"] as? String ?? "",
                                     data: object["data"] ?? NSNull(), raw: plain)
        // 带着登录令牌却被告知未登录 / 登录失效：登录过期了
        if (envelope.code == 50008 || envelope.code == 50014), AnimeSigner.shared.hasUserToken {
            AnimeSigner.shared.discardIssuedToken()
        }
        return envelope
    }

    /// 同 call，但只接受成功（20000），其余抛出带服务端说明的错误
    @discardableResult
    func perform(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let envelope = try await call(path, method: method, body: body)
        guard envelope.code == 20000 else {
            throw AnimeClientError.serverError(code: envelope.code, message: envelope.message)
        }
        return envelope.data
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

    /// 视频列表（支持分类与排序）。`filters` 是额外的筛选参数（type / year / area / isend），
    /// 服务端认不认要看返回的条目——列表页会自己核对（见 AnimeFilterSupport）。
    func fetchVideoList(channel: Int? = nil, sort: String = "weight", limit: Int = 18, page: Int = 1,
                        filters: [(name: String, value: String)] = []) async throws -> AnimeVideoListResult {
        var queryItems: [String] = ["sort=\(sort)", "limit=\(limit)", "page=\(page)"]
        if let channel {
            queryItems.append("channel=\(channel)")
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        for filter in filters {
            guard let value = filter.value.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            queryItems.append("\(filter.name)=\(value)")
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
        #if DEBUG
        if let preview = try await InterfacePreview.animeDetail(id: id) { return preview }
        #endif
        return try await request(path: "/app/video/detail?id=\(id)")
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
        let total = (data as? [String: Any]).flatMap { AnimeJSON.int($0, ["total"]) }
        return AnimeCommentPage(items: records.compactMap { AnimeComment(json: $0, kind: kind) },
                                rawCount: records.count,
                                total: total)
    }

    static func subCommentsPath(themeCommentID: Int, marker: Int? = nil, limit: Int = 20) -> String {
        var query = ["theme_cid=\(themeCommentID)"]
        if let marker, marker > 0 {
            query.append("marker=\(marker)")
        }
        query.append("limit=\(limit)")
        return "/app/vod_comment/getsublist?" + query.joined(separator: "&")
    }

    /// 查看某条评论下的全部回复（游标分页：`theme_cid` 为父评论 ID，`marker` 为上一页最后一条回复的 ID）
    func fetchSubComments(themeCommentID: Int, marker: Int? = nil, limit: Int = 20) async throws -> AnimeCommentPage {
        let path = Self.subCommentsPath(themeCommentID: themeCommentID, marker: marker, limit: limit)
        let data = try await requestJSON(path: path)
        let records = AnimeJSON.records(in: data)
        let total = (data as? [String: Any]).flatMap { AnimeJSON.int($0, ["total"]) }
        return AnimeCommentPage(items: records.compactMap { AnimeComment(json: $0, kind: .list) },
                                rawCount: records.count,
                                total: total)
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
