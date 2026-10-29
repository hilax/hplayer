import Foundation

/// 115 云下载（离线下载）任务
struct Direct115OfflineTask: Equatable {
    enum Status: Equatable {
        case waiting
        case downloading
        case done
        case failed
    }

    let infoHash: String
    let name: String
    let size: Int
    let status: Status
    /// 0...100
    let percent: Double
    /// 下载结果：多文件种子是文件夹编号，单文件可能是文件编号
    let fileID: String
    /// 保存到的目录
    let folderID: String
}

/// 离线完成后找到的视频，folder 是相对于下载结果的文件夹路径
struct Direct115CloudVideo {
    let file: P115File
    let folder: String
}

enum Direct115OfflineError: LocalizedError {
    case quotaExhausted
    case invalidLink
    case server(String)

    var errorDescription: String? {
        switch self {
        case .quotaExhausted: return "115 离线下载额度用完了"
        case .invalidLink: return "115 认为这个磁力链接无效"
        case .server(let message): return message
        }
    }
}

/// 115 网页登录（Cookie）下的离线下载，接口参照开源项目 115driver 和 p115client。
/// 热门资源 115 服务器上已经有了，提交后几秒就会「秒离线」完成，之后用 115 在线播放观看。
extension Direct115Client {
    private static let offlineAppVersion = "27.0.5.7"
    private static let offlineUserAgent = "Mozilla/5.0 115Browser/27.0.5.7"

    /// 提交离线任务。任务已经存在也算成功。
    func addOfflineTask(_ link: String, userID: Int) async throws {
        let payload = [
            "ac": "add_task_urls",
            "app_ver": Self.offlineAppVersion,
            "uid": String(userID),
            "url[0]": link,
        ]
        let endpoints = [
            "https://lixian.115.com/lixianssp/?ac=add_task_urls",
            "https://clouddownload.115.com/lixianssp/?ac=add_task_urls",
        ]
        var lastError: Error = Direct115OfflineError.server("115 离线下载接口没有响应")
        for endpoint in endpoints {
            do {
                let (json, key) = try await encryptedPost(endpoint, payload: payload, userAgent: Self.offlineUserAgent)
                if Self.succeeded(json) {
                    try Self.checkAddResult(json, key: key)
                    return
                }
                let code = Self.errorCode(json)
                switch code {
                case 10008:
                    return
                case 10010:
                    throw Direct115OfflineError.quotaExhausted
                case 10004:
                    throw Direct115OfflineError.invalidLink
                default:
                    let message = Self.errorMessage(json)
                    // 没有错误码也没有说明，多半是接口地址变了，换一个地址再试
                    guard code != 0 || !message.isEmpty else {
                        lastError = Direct115OfflineError.server("115 离线下载接口返回了无法识别的结果")
                        continue
                    }
                    throw Direct115OfflineError.server(message.isEmpty ? "115 离线下载失败（\(code)）" : message)
                }
            } catch let error as Direct115OfflineError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 在离线任务列表里找这个资源（最多看前 3 页）
    func offlineTask(infoHash: String) async throws -> Direct115OfflineTask? {
        let target = infoHash.lowercased()
        for page in 1...3 {
            let tasks = try await offlineTasks(page: page)
            if let task = tasks.first(where: { $0.infoHash == target }) { return task }
            if tasks.isEmpty { break }
        }
        return nil
    }

    func offlineTasks(page: Int) async throws -> [Direct115OfflineTask] {
        let attempts: [(address: String, post: Bool)] = [
            ("https://lixian.115.com/lixian/?ct=lixian&ac=task_lists&page=\(page)", true),
            ("https://clouddownload.115.com/web/?ac=task_lists&page=\(page)&page_size=30", false),
        ]
        var lastError: Error = Direct115OfflineError.server("没能读取 115 离线任务列表")
        for attempt in attempts {
            guard let url = URL(string: attempt.address) else { continue }
            do {
                let (data, response) = try await send(url, form: attempt.post ? ["page": String(page)] : nil)
                guard (200..<300).contains(response.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = Direct115OfflineError.server("读取 115 离线任务失败（\(response.statusCode)）")
                    continue
                }
                let container = json["data"] as? [String: Any] ?? json
                if let tasks = container["tasks"] as? [[String: Any]] ?? json["tasks"] as? [[String: Any]] {
                    return tasks.map(Self.parseTask)
                }
                if Self.succeeded(json) {
                    return []
                }
                let message = Self.errorMessage(json)
                lastError = Direct115OfflineError.server(message.isEmpty ? "读取 115 离线任务失败" : message)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 离线完成后找出里面的视频：结果是文件夹就往下找（最多三层），是单个文件就按名称搜索
    func offlineVideos(for task: Direct115OfflineTask) async throws -> [Direct115CloudVideo] {
        var videos: [Direct115CloudVideo] = []
        if !task.fileID.isEmpty, task.fileID.allSatisfy(\.isNumber), let root = try? await folderEntries(task.fileID) {
            var queue: [(cid: String, path: String, depth: Int)] = []
            for entry in root {
                if entry.isDir {
                    queue.append((entry.id, entry.name, 1))
                } else if entry.isVideo, !entry.pickCode.isEmpty {
                    videos.append(Direct115CloudVideo(file: entry, folder: ""))
                }
            }
            var visited = 0
            while !queue.isEmpty, visited < 30 {
                let next = queue.removeFirst()
                visited += 1
                guard let entries = try? await folderEntries(next.cid) else { continue }
                for entry in entries {
                    if entry.isDir, next.depth < 3 {
                        queue.append((entry.id, "\(next.path)/\(entry.name)", next.depth + 1))
                    } else if entry.isVideo, !entry.pickCode.isEmpty {
                        videos.append(Direct115CloudVideo(file: entry, folder: next.path))
                    }
                }
            }
        }
        if videos.isEmpty, !task.name.isEmpty {
            let keyword = (task.name as NSString).deletingPathExtension
            let found = (try? await search(keyword.isEmpty ? task.name : keyword)) ?? []
            let matches = found.filter { !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty }
            let exact = matches.filter { $0.name == task.name || $0.id == task.fileID || (task.size > 0 && $0.size == task.size) }
            videos = (exact.isEmpty ? matches : exact).map { Direct115CloudVideo(file: $0, folder: "") }
        }
        return videos
    }

    /// 原文件下载地址，用来播放还没有转码的视频。地址和请求时的 User-Agent 绑定，播放器要用同一个。
    func originalURL(pickCode: String) async throws -> URL {
        let (json, key) = try await encryptedPost("https://proapi.115.com/app/chrome/downurl", payload: ["pickcode": pickCode], userAgent: Self.userAgent)
        guard Self.succeeded(json), let text = json["data"] as? String, !text.isEmpty else {
            let message = Self.errorMessage(json)
            throw APIError.server(message.isEmpty ? "115 没有返回原画地址" : message)
        }
        let decoded = try M115Cipher.decode(text, key: key)
        guard let object = try JSONSerialization.jsonObject(with: Data(decoded)) as? [String: Any] else {
            throw APIError.server("115 返回的原画地址无法识别")
        }
        for value in object.values {
            guard let info = value as? [String: Any] else { continue }
            let address = (info["url"] as? [String: Any]).map { Self.text($0["url"]) } ?? Self.text(info["url"])
            if let url = URL(string: address), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
                return url
            }
        }
        throw APIError.server("115 没有返回原画地址，文件可能已经被删除")
    }

    // MARK: 请求

    private func encryptedPost(_ address: String, payload: [String: String], userAgent: String) async throws -> ([String: Any], [UInt8]) {
        guard var components = URLComponents(string: address) else { throw APIError.badURL }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        guard let url = components.url else { throw APIError.badURL }
        let key = M115Cipher.randomKey()
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let encoded = M115Cipher.encode([UInt8](body), key: key)
        let (data, response) = try await send(url, form: ["data": encoded], userAgent: userAgent)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server("115 请求失败（\(response.statusCode)）")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.server("115 返回的数据无法识别")
        }
        return (json, key)
    }

    /// 解开添加结果，单条任务里也可能带着错误码
    private static func checkAddResult(_ json: [String: Any], key: [UInt8]) throws {
        guard let text = json["data"] as? String, !text.isEmpty,
              let decoded = try? M115Cipher.decode(text, key: key),
              let object = try? JSONSerialization.jsonObject(with: Data(decoded)) as? [String: Any] else { return }
        let items = object["result"] as? [[String: Any]] ?? []
        guard let first = items.first else { return }
        let code = errorCode(first)
        if code == 0 || code == 10008 { return }
        if succeeded(first) { return }
        switch code {
        case 10010: throw Direct115OfflineError.quotaExhausted
        case 10004: throw Direct115OfflineError.invalidLink
        default:
            let message = errorMessage(first)
            throw Direct115OfflineError.server(message.isEmpty ? "115 离线下载失败（\(code)）" : message)
        }
    }

    /// 列出文件夹内容；返回的目录编号和请求的不一致时，说明这个编号不是文件夹
    private func folderEntries(_ cid: String) async throws -> [P115File] {
        var components = URLComponents(string: "https://webapi.115.com/files")!
        components.queryItems = [
            URLQueryItem(name: "aid", value: "1"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "show_dir", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "fc_mix", value: "0"),
        ]
        guard let url = components.url else { throw APIError.badURL }
        let (data, _) = try await send(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], Self.succeeded(json) else {
            throw APIError.server("不是文件夹")
        }
        let listed = Self.text(json["cid"])
        if !listed.isEmpty, listed != cid { throw APIError.server("不是文件夹") }
        let items = json["data"] as? [[String: Any]] ?? []
        return items.map { Self.cloudFile($0, parent: cid) }
    }

    // MARK: 解析

    private static func parseTask(_ raw: [String: Any]) -> Direct115OfflineTask {
        let percent = Double(text(raw["percentDone"])) ?? 0
        let code = Int(text(raw["status"])) ?? 0
        let status: Direct115OfflineTask.Status
        switch code {
        case 2: status = .done
        case 1: status = percent >= 100 ? .done : .downloading
        case -1: status = .failed
        default: status = percent >= 100 ? .done : .waiting
        }
        return Direct115OfflineTask(
            infoHash: text(raw["info_hash"]).lowercased(),
            name: text(raw["name"]),
            size: Int(text(raw["size"])) ?? 0,
            status: status,
            percent: min(max(percent, 0), 100),
            fileID: text(raw["file_id"]),
            folderID: text(raw["wp_path_id"])
        )
    }

    private static let cloudVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "m2ts", "mts", "webm", "flv", "f4v",
        "rmvb", "rm", "mpg", "mpeg", "vob", "3gp", "asf",
    ]

    private static func cloudFile(_ raw: [String: Any], parent: String) -> P115File {
        let fid = text(raw["fid"])
        let isDir = fid.isEmpty || fid == "0"
        let name = text(raw["n"])
        let ext = (name as NSString).pathExtension.lowercased()
        let video = text(raw["isv"]) == "1" || text(raw["ico"]) == "video" || cloudVideoExtensions.contains(ext)
        return P115File(
            id: isDir ? text(raw["cid"]) : fid,
            parentId: parent,
            name: name,
            isDir: isDir,
            kind: isDir ? "folder" : (video ? "video" : text(raw["ico"])),
            size: Int(text(raw["s"])) ?? 0,
            pickCode: text(raw["pc"]),
            sha1: text(raw["sha"]),
            updatedAt: text(raw["t"]),
            thumbUrl: text(raw["u"])
        )
    }

    private static func succeeded(_ json: [String: Any]) -> Bool {
        if let state = json["state"] as? Bool { return state }
        if let state = json["state"] as? NSNumber { return state.intValue != 0 }
        return false
    }

    private static func errorCode(_ json: [String: Any]) -> Int {
        for key in ["errno", "errNo", "errcode", "errCode", "error_code", "code"] {
            if let value = Int(text(json[key])), value != 0 { return value }
        }
        return 0
    }

    private static func errorMessage(_ json: [String: Any]) -> String {
        for key in ["error_msg", "error", "msg", "message"] {
            let value = text(json[key])
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}
