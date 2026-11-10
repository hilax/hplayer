import Foundation
import UIKit

enum DramaError: LocalizedError {
    case http(Int)
    case server(String)
    case invalidResponse
    case noPlayURL

    var errorDescription: String? {
        switch self {
        case .http(let code): return "短剧接口请求失败（HTTP \(code)）"
        case .server(let message): return message.isEmpty ? "短剧接口返回失败" : message
        case .invalidResponse: return "短剧接口返回异常"
        case .noPlayURL: return "这一集暂时没有可播放的片源"
        }
    }
}

/// 在线短剧的接口。所有业务请求都走同一个入口 `POST /api/edge/request`，
/// 把真正的 method / path 包在 JSON 里；游客访问，不带签名也不用登录。
///
/// 只接入「AI 短剧」「AI 漫剧」两个分类，并且只按分类拉列表：
/// 站点的推荐流、榜单和搜索会混入换脸类内容（用真人的脸合成），这部分不接。
final class DramaClient {
    static let shared = DramaClient()

    static let lines = ["https://huangguoai.com", "https://huangguoai.ai"]
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private static let lineKey = "hplayer.drama.line"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
    }

    /// 上次能连上的线路排在前面
    private var orderedLines: [String] {
        let saved = UserDefaults.standard.string(forKey: Self.lineKey) ?? ""
        guard Self.lines.contains(saved) else { return Self.lines }
        return [saved] + Self.lines.filter { $0 != saved }
    }

    var currentLine: String { orderedLines[0] }

    /// 播放和取封面时带的请求头
    var mediaHeaders: [String: String] {
        ["User-Agent": Self.userAgent, "Referer": currentLine + "/"]
    }

    // MARK: 业务接口

    func list(_ category: DramaCategory, page: Int, size: Int = 21) async throws -> DramaPage {
        let data = try await request("/api/videos/category/\(category.rawValue)?page=\(page)&size=\(size)")
        guard let dict = data as? [String: Any] else { throw DramaError.invalidResponse }
        let items = ((dict["items"] as? [[String: Any]]) ?? []).compactMap(DramaCard.init(json:))
        let pagination = dict["pagination"] as? [String: Any] ?? [:]
        return DramaPage(items: items,
                         page: AnimeJSON.int(pagination, ["page"]) ?? page,
                         pages: AnimeJSON.int(pagination, ["pages"]) ?? page)
    }

    func detail(id: Int) async throws -> DramaDetail {
        let data = try await request("/api/videos/\(id)")
        guard let dict = data as? [String: Any], let detail = DramaDetail(json: dict) else {
            throw DramaError.invalidResponse
        }
        return detail
    }

    /// 一集的 HLS 地址。地址里的签名一小时左右过期，每次播放现取，不缓存。
    func playURL(videoId: Int, episode: Int) async throws -> URL {
        let data = try await request("/api/videos/\(videoId)/play?ep=\(episode)&page_texts=0")
        guard let dict = data as? [String: Any],
              let text = AnimeJSON.string(dict, ["video_url"]), let url = URL(string: text) else {
            throw DramaError.noPlayURL
        }
        return url
    }

    // MARK: 请求

    /// 返回外壳里的 `data`。连不上时换下一条线路；接口明确返回失败就不再重试。
    private func request(_ path: String) async throws -> Any {
        var lastError: Error = DramaError.invalidResponse
        for line in orderedLines {
            do {
                let value = try await send(path, line: line)
                UserDefaults.standard.set(line, forKey: Self.lineKey)
                return value
            } catch let error as DramaError {
                throw error
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func send(_ path: String, line: String) async throws -> Any {
        guard let url = URL(string: line + "/api/edge/request") else { throw DramaError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": "GET", "path": path, "body": "", "content_type": "",
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(line + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DramaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DramaError.http(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DramaError.invalidResponse
        }
        guard AnimeJSON.int(object, ["status"]) == 1, let payload = object["data"], !(payload is NSNull) else {
            throw DramaError.server(object["msg"] as? String ?? "")
        }
        return payload
    }
}

/// 短剧封面。封面地址返回的不是图片，而是 AES-128-CBC 密文，取回后在本机解密再显示。
final class DramaCoverStore {
    static let shared = DramaCoverStore()

    private static let key = Data("f5d965df75336270".utf8)
    private static let iv = Data("97b60394abc2fbe1".utf8)
    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 240 }

    func cached(_ urlString: String) -> UIImage? { cache.object(forKey: urlString as NSString) }

    func image(for urlString: String) async -> UIImage? {
        if let image = cached(urlString) { return image }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        for (name, value) in DramaClient.shared.mediaHeaders { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = Self.decode(data) else { return nil }
        cache.setObject(image, forKey: urlString as NSString)
        return image
    }

    /// 已经是图片就直接用，否则先解密。
    static func decode(_ data: Data) -> UIImage? {
        if let image = UIImage(data: data) { return image }
        guard !data.isEmpty, data.count % 16 == 0,
              let plain = AnimeCrypto.aes128CbcDecrypt(data: data, key: key, iv: iv) else { return nil }
        return UIImage(data: plain)
    }
}
