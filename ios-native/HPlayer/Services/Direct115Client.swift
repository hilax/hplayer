import Foundation

struct Direct115Stream: Identifiable {
    let id: String
    let title: String
    let url: URL
}

/// 115 网页会话直连，Cookie 仅保存在本机 Keychain。
struct Direct115Client {
    let cookie: String
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func user() async throws -> P115Status {
        let json = try await jsonRequest("https://my.115.com/", query: ["ct": "ajax", "ac": "nav"])
        let data = json["data"] as? [String: Any] ?? [:]
        let id = Self.integer(data["user_id"])
        guard id > 0 else { throw APIError.server("115 登录状态无效，请重新登录") }
        return P115Status(configured: true, userId: id, userName: Self.string(data["user_name"]), vip: Self.integer(data["vip"]), error: nil, message: nil)
    }

    func quota() async throws -> QuotaResponse {
        let json = try await jsonRequest("https://webapi.115.com/user/space")
        let data = json["data"] as? [String: Any] ?? [:]
        let used = data["all_use"] as? [String: Any] ?? [:]
        let total = data["all_total"] as? [String: Any] ?? [:]
        return QuotaResponse(usedText: Self.string(used["size"]), totalText: Self.string(total["size"]), usedBytes: Self.integer(used["size_byte"]), totalBytes: Self.integer(total["size_byte"]))
    }

    func files(cid: String) async throws -> [P115File] {
        guard !cid.isEmpty, cid.allSatisfy(\.isNumber) else { throw APIError.server("目录编号无效") }
        var result: [P115File] = []
        var offset = 0
        repeat {
            let json = try await jsonRequest("https://webapi.115.com/files", query: ["aid": "1", "cid": cid, "offset": String(offset), "limit": "1000", "show_dir": "1", "format": "json", "fc_mix": "0"])
            guard let files = json["data"] as? [[String: Any]] else { throw APIError.server("115 未返回文件列表") }
            result.append(contentsOf: files.map { Self.file($0, parent: cid) })
            offset += files.count
            let count = Self.integer(json["count"])
            if files.isEmpty || (count > 0 && offset >= count) || (count == 0 && files.count < 1000) { break }
        } while true
        return result
    }

    func search(_ keyword: String) async throws -> [P115File] {
        let json = try await jsonRequest("https://webapi.115.com/files/search", query: ["aid": "1", "search_value": keyword, "offset": "0", "limit": "100", "show_dir": "1", "format": "json", "fc_mix": "0"])
        guard let files = json["data"] as? [[String: Any]] else { throw APIError.server("115 未返回搜索结果") }
        return files.map { Self.file($0, parent: "0") }
    }

    /// 115 网页端返回主播放列表；请求和播放器使用相同 UA。
    func streams(pickCode: String) async throws -> [Direct115Stream] {
        guard !pickCode.isEmpty, pickCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw APIError.server("视频提取码无效") }
        let url = URL(string: "https://115.com/api/video/m3u8/\(pickCode).m3u8?definition=0")!
        let (data, response) = try await request(url)
        guard (200..<300).contains(response.statusCode), let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw APIError.server("115 没有返回可播放的在线视频，请检查账号权益或稍后重试")
        }
        var results: [Direct115Stream] = []
        var metadata: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") { metadata = line; continue }
            guard let attributes = metadata, !line.isEmpty, !line.hasPrefix("#") else { continue }
            metadata = nil
            guard let streamURL = URL(string: line, relativeTo: response.url ?? url)?.absoluteURL,
                  streamURL.scheme?.lowercased() == "https", streamURL.host != nil else { continue }
            let resolution = attributes.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression).map { String(attributes[$0]) }
            let title = resolution?.components(separatedBy: "x").last.map { "\($0)P" } ?? "画质 \(results.count + 1)"
            results.append(Direct115Stream(id: String(results.count), title: title, url: streamURL))
        }
        guard !results.isEmpty else { throw APIError.server("115 未返回可选择的在线播放画质；此视频可能尚未转码或账号无权限") }
        return results
    }

    private func jsonRequest(_ address: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard var components = URLComponents(string: address) else { throw APIError.badURL }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.badURL }
        let (data, response) = try await request(url)
        guard (200..<300).contains(response.statusCode) else { throw APIError.server("115 请求失败（\(response.statusCode)）") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.server("115 返回的数据无法识别") }
        let failedState = (json["state"] as? Bool) == false || (json["state"] as? Int) == 0
        let errorCode = Self.integer(json["errno"] ?? json["errNo"])
        if failedState || errorCode != 0 {
            let message = Self.string(json["error"] ?? json["message"] ?? json["msg"])
            throw APIError.server(message.isEmpty ? "115 请求失败，请检查登录状态" : message)
        }
        return json
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(url)
    }

    /// 发送带登录 Cookie 的请求；传入 form 时用 POST 表单提交
    func send(_ url: URL, form: [String: String]? = nil, userAgent: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent ?? Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(form).data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server("115 响应无效") }
        return (data, http)
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func formBody(_ form: [String: String]) -> String {
        form.sorted { $0.key < $1.key }
            .map { key, value in
                let name = key.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? key
                let encoded = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
                return "\(name)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private static func file(_ raw: [String: Any], parent: String) -> P115File {
        let fid = string(raw["fid"])
        let isDir = fid.isEmpty || fid == "0"
        let name = string(raw["n"])
        let ext = (name as NSString).pathExtension.lowercased()
        let video = integer(raw["isv"]) == 1 || string(raw["ico"]) == "video" || ["mp4", "mkv", "mov", "m4v", "avi", "ts", "webm", "wmv", "flv", "m2ts", "mpg", "mpeg"].contains(ext)
        return P115File(id: isDir ? string(raw["cid"]) : fid, parentId: string(raw["pid"]).isEmpty ? parent : string(raw["pid"]), name: name, isDir: isDir, kind: isDir ? "folder" : (video ? "video" : string(raw["ico"])), size: integer(raw["s"]), pickCode: string(raw["pc"]), sha1: string(raw["sha"]), updatedAt: string(raw["t"]), thumbUrl: string(raw["u"]))
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private static func integer(_ value: Any?) -> Int { Int(string(value)) ?? 0 }
}

/// 重定向至 CDN 时不发送 115 登录 Cookie。
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { completionHandler(nil); return }
        var next = request
        if host != "115.com" && !host.hasSuffix(".115.com") { next.setValue(nil, forHTTPHeaderField: "Cookie") }
        completionHandler(next)
    }
}
