import Foundation
import CryptoKit
import Security

/// 115 开放平台的手机端授权与云下载。敏感信息只保存在 Keychain。
actor Direct115Open {
    static let shared = Direct115Open()
    private let clientKey = "hplayer.open.clientId"
    private let tokenKey = "hplayer.open.tokens"
    private var pending: Pending?
    private var refreshTask: Task<TokenPair, Error>?

    private struct TokenPair: Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
    }
    private struct Pending {
        let uid: String
        let time: String
        let sign: String
        let verifier: String
        let expiry: Date
    }
    private struct OpenError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    func route(path: String, method: String, body: Data?) async throws -> Data {
        guard let components = URLComponents(string: "https://local.invalid\(path)") else { throw APIError.badURL }
        let params = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let payload = try body.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let result: [String: Any]
        switch (method, components.path) {
        case ("GET", "/api/115/open/status"):
            let configured = !(Keychain.load(clientKey) ?? "").isEmpty
            let authorized = loadTokens() != nil
            if authorized { result = ["configured": configured, "authorized": true] }
            else { result = ["configured": configured, "authorized": false, "message": configured ? "请扫码授权 115" : "请先填写 AppID"] }
        case ("POST", "/api/115/open/config"):
            let id = (payload["clientId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty && id.count <= 200 else { throw APIError.server("请输入有效的 AppID") }
            if Keychain.load(clientKey) != id { Keychain.delete(tokenKey) }
            Keychain.save(id, for: clientKey)
            pending = nil
            result = ["ok": true]
        case ("POST", "/api/115/open/auth/start"):
            result = try await startAuth()
        case ("POST", "/api/115/open/auth/poll"):
            result = try await pollAuth()
        case ("POST", "/api/115/open/source"):
            guard loadTokens() != nil else { throw APIError.server("请先完成开放平台授权") }
            result = ["ok": true]
        case ("GET", "/api/115/torrent/files"):
            result = try await directory(cid: params["cid"] ?? "0", offset: Int(params["offset"] ?? "0") ?? -1)
        case ("POST", "/api/115/torrent/upload"):
            result = try await upload(name: payload["name"] ?? "", encoded: payload["data"] ?? "")
        case ("POST", "/api/115/torrent/parse"):
            result = try await parse(sha: payload["sha1"] ?? "", pickCode: payload["pickCode"] ?? "")
        case ("POST", "/api/115/torrent/tasks"):
            try await addTask(payload)
            result = ["ok": true]
        case ("GET", "/api/115/torrent/tasks"):
            result = try await tasks(page: Int(params["page"] ?? "1") ?? 0)
        default:
            throw APIError.server("当前功能需要服务器模式")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func startAuth() async throws -> [String: Any] {
        guard let clientId = Keychain.load(clientKey), !clientId.isEmpty else { throw APIError.server("请先填写 AppID") }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw APIError.server("无法生成授权信息") }
        let verifier = Self.base64URL(Data(random))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let response = try await Self.formRequest("https://passportapi.115.com/open/authDeviceCode", fields: ["client_id": clientId, "code_challenge": challenge, "code_challenge_method": "sha256"])
        let data = response["data"] as? [String: Any] ?? [:]
        let uid = Self.string(data["uid"]), time = Self.string(data["time"]), sign = Self.string(data["sign"]), qr = Self.string(data["qrcode"])
        guard !uid.isEmpty && !time.isEmpty && !sign.isEmpty && !qr.isEmpty else { throw APIError.server("115 未返回完整的扫码授权信息") }
        pending = Pending(uid: uid, time: time, sign: sign, verifier: verifier, expiry: Date().addingTimeInterval(300))
        return ["verificationUri": qr, "userCode": "", "expiresIn": 300]
    }

    private func pollAuth() async throws -> [String: Any] {
        guard let current = pending, Date() < current.expiry else { pending = nil; return ["status": "expired"] }
        let response = try await Self.getJSON("https://qrcodeapi.115.com/get/status/", query: ["uid": current.uid, "time": current.time, "sign": current.sign], allowStateZero: true)
        if Self.integer(response["state"]) == 0 { pending = nil; return ["status": "expired", "message": "二维码已失效"] }
        let status = Self.integer((response["data"] as? [String: Any])?["status"])
        if status == -1 || status == -2 { pending = nil; return ["status": "expired", "message": "二维码已失效或授权已取消"] }
        guard status == 2 else { return ["status": "pending", "message": status == 1 ? "已扫码，请在 115 中确认" : "等待扫码"] }
        let responseToken = try await Self.formRequest("https://passportapi.115.com/open/deviceCodeToToken", fields: ["uid": current.uid, "code_verifier": current.verifier])
        guard pending?.uid == current.uid else { throw APIError.server("授权请求已变更，请重新开始") }
        try saveTokens(Self.tokens(responseToken))
        pending = nil
        return ["status": "authorized"]
    }

    private func loadTokens() -> TokenPair? {
        guard let raw = Keychain.load(tokenKey), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }
    private func saveTokens(_ tokens: TokenPair) throws {
        guard let value = String(data: try JSONEncoder().encode(tokens), encoding: .utf8) else { throw APIError.server("无法保存授权") }
        Keychain.save(value, for: tokenKey)
    }
    private static func tokens(_ response: [String: Any]) throws -> TokenPair {
        let data = response["data"] as? [String: Any] ?? [:]
        let access = string(data["access_token"]), refresh = string(data["refresh_token"])
        guard !access.isEmpty && !refresh.isEmpty else { throw APIError.server("115 未返回完整授权信息") }
        return TokenPair(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(TimeInterval(max(1, integer(data["expires_in"]) == 0 ? 7200 : integer(data["expires_in"])))))
    }
    private func freshTokens(force: Bool = false) async throws -> TokenPair {
        guard let old = loadTokens() else { throw APIError.server("请先在 BT 云下载中完成 115 官方授权") }
        if !force && old.expiresAt.timeIntervalSinceNow > 60 { return old }
        let task: Task<TokenPair, Error>
        if let existing = refreshTask { task = existing }
        else {
            task = Task { try await Self.tokens(Self.formRequest("https://passportapi.115.com/open/refreshToken", fields: ["refresh_token": old.refresh])) }
            refreshTask = task
        }
        do {
            let updated = try await task.value
            if loadTokens()?.refresh == old.refresh { try saveTokens(updated) }
            else if loadTokens()?.refresh != updated.refresh { throw APIError.server("授权已改变，请重试") }
            refreshTask = nil
            return updated
        } catch { refreshTask = nil; throw error }
    }

    private func api(_ path: String, query: [String: String] = [:], fields: [String: String]? = nil, retried: Bool = false) async throws -> [String: Any] {
        let token = try await freshTokens()
        guard var components = URLComponents(string: "https://proapi.115.com\(path)") else { throw APIError.badURL }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        if let fields {
            let form = Self.multipart(fields)
            request.httpMethod = "POST"; request.httpBody = form.data
            request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        }
        do { return try await Self.json(request) }
        catch let error as OpenError where !retried && (error.code == 40140125 || error.code == 40140126) {
            if loadTokens()?.access == token.access { _ = try await freshTokens(force: true) }
            return try await api(path, query: query, fields: fields, retried: true)
        }
    }

    private func directory(cid: String, offset: Int) async throws -> [String: Any] {
        guard Self.numeric(cid), offset >= 0 else { throw APIError.server("目录参数无效") }
        let json = try await api("/open/ufile/files", query: ["cid": cid, "offset": String(offset), "limit": "200", "show_dir": "1", "cur": "1"])
        let raw = json["data"] as? [[String: Any]] ?? []
        let files: [[String: Any]] = raw.filter { Self.string($0["fc"]) == "0" || Self.string($0["fn"]).lowercased().hasSuffix(".torrent") }.map { f in
            ["id": Self.string(f["fid"]), "name": Self.string(f["fn"]), "isDir": Self.string(f["fc"]) == "0", "sha1": Self.string(f["sha1"]), "pickCode": Self.string(f["pc"]), "size": Self.integer(f["fs"])]
        }
        let count = Self.integer(json["count"])
        return ["files": files, "nextOffset": offset + raw.count, "hasMore": raw.count > 0 && (count > 0 ? offset + raw.count < count : raw.count == 200)]
    }

    private func parse(sha: String, pickCode: String) async throws -> [String: Any] {
        try Self.validateSeed(sha, pickCode)
        let json = try await api("/open/offline/torrent", fields: ["torrent_sha1": sha, "pick_code": pickCode])
        let data = json["data"] as? [String: Any] ?? [:]
        guard let files = data["torrent_filelist"] as? [[String: Any]], !Self.string(data["info_hash"]).isEmpty else { throw APIError.server("115 未返回完整的种子信息") }
        return ["name": Self.string(data["torrent_name"]), "infoHash": Self.string(data["info_hash"]), "sha1": sha, "pickCode": pickCode, "size": Self.integer(data["file_size"]), "files": files.enumerated().map { index, f in ["index": index, "path": Self.string(f["path"]), "size": Self.integer(f["size"]), "wanted": Self.integer(f["wanted"]) == 1] }]
    }

    private func addTask(_ payload: [String: String]) async throws {
        let sha = payload["sha1"] ?? "", pick = payload["pickCode"] ?? "", hash = payload["infoHash"] ?? ""
        let wanted = payload["wanted"] ?? "", path = (payload["savePath"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), folder = payload["folderId"] ?? "0"
        try Self.validateSeed(sha, pick)
        let indexes = wanted.split(separator: ",", omittingEmptySubsequences: false)
        guard Self.hex40(hash), !indexes.isEmpty, indexes.allSatisfy({ Self.numeric(String($0)) }), wanted.count <= 20000, Self.numeric(folder), !path.isEmpty, path.count <= 512, !path.contains("\\"), path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw APIError.server("任务参数无效，请检查保存路径和选中文件") }
        _ = try await api("/open/offline/add_task_bt", fields: ["info_hash": hash, "wanted": wanted, "save_path": path, "torrent_sha1": sha, "pick_code": pick, "wp_path_id": folder])
    }

    private func tasks(page: Int) async throws -> [String: Any] {
        guard page > 0 else { throw APIError.server("页码无效") }
        let json = try await api("/open/offline/get_task_list", query: ["page": String(page)])
        let data = json["data"] as? [String: Any] ?? [:]
        let tasks = (data["tasks"] as? [[String: Any]] ?? []).map { t in ["id": Self.string(t["info_hash"]), "name": Self.string(t["name"]), "progress": Self.integer(t["percentDone"]), "size": Self.integer(t["size"]), "status": Self.integer(t["status"])] as [String: Any] }
        return ["page": Self.integer(data["page"]), "pageCount": Self.integer(data["page_count"]), "count": Self.integer(data["count"]), "tasks": tasks]
    }

    private func upload(name: String, encoded: String) async throws -> [String: Any] {
        guard name.lowercased().hasSuffix(".torrent"), name.count <= 255, !name.contains("/"), !name.contains("\\"), name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024, bytes.first == 0x64, bytes.last == 0x65 else { throw APIError.server("种子文件无效或超过 4 MB") }
        let sha = Self.sha1(bytes)
        let fields = ["file_name": name, "file_size": String(bytes.count), "target": "U_1_0", "fileid": sha, "preid": Self.sha1(Data(bytes.prefix(128 * 1024))), "topupload": "0"]
        var data = (try await api("/open/upload/init", fields: fields))["data"] as? [String: Any] ?? [:]
        if [700, 701, 702].contains(Self.integer(data["code"])) {
            let range = Self.string(data["sign_check"]).split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]), start >= 0, end >= start, end < bytes.count, !Self.string(data["sign_key"]).isEmpty else { throw APIError.server("115 返回了无效的上传校验范围") }
            var signed = fields
            signed["sign_key"] = Self.string(data["sign_key"])
            signed["sign_val"] = Self.sha1(bytes.subdata(in: start..<(end + 1)))
            data = (try await api("/open/upload/init", fields: signed))["data"] as? [String: Any] ?? [:]
        }
        let status = Self.integer(data["status"])
        guard status == 1 || status == 2 else { throw APIError.server("115 未完成种子上传初始化") }
        var pick = Self.string(data["pick_code"])
        if status == 1 {
            let token = (try await api("/open/upload/get_token"))["data"] as? [String: Any] ?? [:]
            let response = try await Self.uploadObject(bytes, upload: data, token: token)
            let content = response["data"] as? [String: Any] ?? [:]
            let returned = Self.string(content["pick_code"] ?? content["pickcode"] ?? response["pick_code"] ?? response["pickcode"])
            if !returned.isEmpty { pick = returned }
        }
        try Self.validateSeed(sha, pick)
        return ["sha1": sha, "pickCode": pick]
    }

    private static func uploadObject(_ data: Data, upload: [String: Any], token: [String: Any]) async throws -> [String: Any] {
        guard let endpoint = URL(string: string(upload["endpoint"])), endpoint.scheme == "https", let host = endpoint.host?.lowercased(), host == "115.com" || host.hasSuffix(".115.com"), endpoint.path.isEmpty || endpoint.path == "/", endpoint.query == nil, endpoint.fragment == nil, endpoint.user == nil, endpoint.password == nil, endpoint.port == nil else { throw APIError.server("115 返回了无效的上传地址") }
        let bucket = string(upload["bucket"]), object = string(upload["object"]), access = string(token["AccessKeyId"]), secret = string(token["AccessKeySecret"]), security = string(token["SecurityToken"])
        let callbackData = upload["callback"] as? [String: Any] ?? [:]
        let callback = string(callbackData["callback"]), callbackVar = string(callbackData["callback_var"])
        guard !bucket.isEmpty, bucket.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }), !object.isEmpty, !access.isEmpty, !secret.isEmpty, !security.isEmpty, !callback.isEmpty else { throw APIError.server("115 未返回完整的上传参数") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: Date())
        var headers = ["x-oss-callback": callback, "x-oss-security-token": security]
        if !callbackVar.isEmpty { headers["x-oss-callback-var"] = callbackVar }
        let transfer = token["transfer_config"] as? [String: Any] ?? [:], rate = integer(transfer["rate"])
        if string(transfer["unit"]) == "bytes_per_second", (102400...104857600).contains(rate) { headers["x-oss-traffic-limit"] = String(rate * 8) }
        let canonical = headers.keys.sorted().map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))\n" }.joined()
        let input = "PUT\n\napplication/octet-stream\n\(date)\n\(canonical)/\(bucket)/\(object)"
        let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: Data(secret.utf8)))).base64EncodedString()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw APIError.badURL }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        components.percentEncodedPath = "/" + object.split(separator: "/", omittingEmptySubsequences: false).map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        guard let url = components.url else { throw APIError.badURL }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpBody = data; request.timeoutInterval = 120
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(date, forHTTPHeaderField: "Date"); request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); request.setValue("OSS \(access):\(signature)", forHTTPHeaderField: "Authorization")
        return try await json(request)
    }

    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined() }
    private static func string(_ value: Any?) -> String { if let v = value as? String { return v }; if let n = value as? NSNumber { return n.stringValue }; return "" }
    private static func integer(_ value: Any?) -> Int { Int(string(value)) ?? 0 }
    private static func numeric(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
    private static func hex40(_ s: String) -> Bool { s.count == 40 && s.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func validateSeed(_ sha: String, _ pick: String) throws {
        guard hex40(sha), !pick.isEmpty, pick.count <= 128, pick.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw APIError.server("种子文件缺少有效的 SHA1 或提取码") }
    }
    private static func multipart(_ fields: [String: String]) -> (data: Data, boundary: String) {
        let boundary = "HPlayer-\(UUID().uuidString)"
        var data = Data()
        for key in fields.keys.sorted() {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return (data, boundary)
    }
    private static func formRequest(_ url: String, fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw APIError.badURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await json(request)
    }
    private static func getJSON(_ url: String, query: [String: String], allowStateZero: Bool = false) async throws -> [String: Any] {
        guard var components = URLComponents(string: url) else { throw APIError.badURL }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let target = components.url else { throw APIError.badURL }
        var request = URLRequest(url: target); request.timeoutInterval = 30
        return try await json(request, allowStateZero: allowStateZero)
    }
    private static func json(_ request: URLRequest, allowStateZero: Bool = false) async throws -> [String: Any] {
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: OpenRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError.server("115 接口请求失败") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.server("115 返回数据无法识别") }
        if (!allowStateZero && ((json["state"] as? Bool) == false || (json["state"] as? Int) == 0)) || (json["code"] != nil && integer(json["code"]) != 0) {
            let message = string(json["message"] ?? json["error"])
            throw OpenError(code: integer(json["code"]), message: message.isEmpty ? "115 接口请求失败，请检查应用权限" : message)
        }
        return json
    }
}

private final class OpenRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
