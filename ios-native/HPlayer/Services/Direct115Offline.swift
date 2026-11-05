import Foundation

/// 115 云下载（离线下载）任务
struct Direct115OfflineTask: Equatable, Identifiable {
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
    /// 115 返回的任务编号原文；删除任务时原样交回给 115
    var remoteHash: String = ""
    /// 添加任务时用的链接
    var sourceURL: String = ""
    var addedAt: Date? = nil
    /// 字节/秒，只有下载中才有
    var speed: Double = 0
    /// 预计剩余秒数，0 表示未知
    var remainingSeconds: Int = 0

    var id: String { infoHash.isEmpty ? remoteHash : infoHash }

    /// 任务来源，用来在列表里写「磁力链接」「HTTP 链接」
    var sourceLabel: String {
        let link = sourceURL.lowercased()
        if link.hasPrefix("magnet:") { return "磁力链接" }
        if link.hasPrefix("ed2k:") { return "电驴链接" }
        if link.hasPrefix("ftp:") || link.hasPrefix("ftps:") { return "FTP 链接" }
        if link.hasPrefix("http:") || link.hasPrefix("https:") { return "HTTP 链接" }
        return "离线任务"
    }
}

/// 离线任务列表的一页
struct Direct115OfflinePage: Equatable {
    var tasks: [Direct115OfflineTask]
    /// 全部任务数；115 没有返回时等于已经看到的数量
    var total: Int
    var page: Int
    var pageCount: Int

    var hasMore: Bool { page < pageCount && !tasks.isEmpty }
}

/// 批量添加的结果：每条链接分别成功或失败
struct Direct115OfflineAddSummary {
    struct Failure {
        let link: String
        let error: Direct115OfflineError
    }

    /// 成功加入的条数（已经在列表里的也算）
    let succeeded: Int
    let failures: [Failure]
}

/// 清空离线任务时的范围；数值就是 115 接口的 flag
enum Direct115OfflineClearScope: Int {
    case completed = 0
    case all = 1
    case failed = 2
    case running = 3
    case completedWithFiles = 4
    case allWithFiles = 5
}

/// 离线完成后找到的视频，folder 是相对于下载结果的文件夹路径
struct Direct115CloudVideo {
    let file: P115File
    let folder: String
}

/// 文件夹路径上的一级：编号加名称
struct Direct115PathEntry: Equatable {
    let id: String
    let name: String
}

enum Direct115OfflineError: LocalizedError {
    case quotaExhausted
    case invalidLink
    case server(String)

    var errorDescription: String? {
        switch self {
        case .quotaExhausted: return "115 离线下载额度用完了"
        case .invalidLink: return "115 认为这个链接无效"
        case .server(let message): return message
        }
    }
}

/// 115 网页登录（Cookie）下的离线下载，接口参照开源项目 115driver 和 p115client。
/// 热门资源 115 服务器上已经有了，提交后几秒就会「秒离线」完成，之后用 115 在线播放观看。
extension Direct115Client {
    private static let offlineAppVersion = "27.0.5.7"
    private static let offlineUserAgent = "Mozilla/5.0 115Browser/27.0.5.7"
    /// 一次最多提交的链接数
    static let offlineAddLimit = 50

    /// 提交离线任务。任务已经存在也算成功。
    func addOfflineTask(_ link: String, userID: Int) async throws {
        let summary = try await addOfflineTasks([link], userID: userID, folderID: nil)
        if let failure = summary.failures.first { throw failure.error }
    }

    /// 一次提交多条链接。`folderID` 为空时保存到 115 默认的离线下载目录。
    /// 整个请求被拒绝时抛出错误；只有部分链接失败时返回结果，由调用方告诉用户是哪几条。
    func addOfflineTasks(_ links: [String], userID: Int, folderID: String?) async throws -> Direct115OfflineAddSummary {
        var cleaned: [String] = []
        var seen = Set<String>()
        for link in links {
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted { cleaned.append(trimmed) }
        }
        guard !cleaned.isEmpty else { throw Direct115OfflineError.invalidLink }
        guard cleaned.count <= Self.offlineAddLimit else {
            throw Direct115OfflineError.server("一次最多添加 \(Self.offlineAddLimit) 条链接")
        }
        var payload = [
            "ac": "add_task_urls",
            "app_ver": Self.offlineAppVersion,
            "uid": String(userID),
        ]
        if let folderID { payload["wp_path_id"] = try Self.validatedID(folderID, allowRoot: true) }
        for (index, link) in cleaned.enumerated() { payload["url[\(index)]"] = link }
        let endpoints = [
            "https://lixian.115.com/lixianssp/?ac=add_task_urls",
            "https://clouddownload.115.com/lixianssp/?ac=add_task_urls",
        ]
        var lastError: Error = Direct115OfflineError.server("115 离线下载接口没有响应")
        for endpoint in endpoints {
            do {
                let (json, key) = try await encryptedPost(endpoint, payload: payload, userAgent: Self.offlineUserAgent)
                if Self.succeeded(json) {
                    return Self.addSummary(json, key: key, links: cleaned)
                }
                let code = Self.errorCode(json)
                switch code {
                case 10008:
                    return Direct115OfflineAddSummary(succeeded: cleaned.count, failures: [])
                case 10010:
                    throw Direct115OfflineError.quotaExhausted
                case 10004:
                    throw Direct115OfflineError.invalidLink
                case 99, 990001:
                    throw Direct115FileError.notLoggedIn
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
            } catch let error as Direct115FileError {
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
        try await offlinePage(page).tasks
    }

    /// 读取离线任务列表的一页（页码从 1 开始）
    func offlinePage(_ page: Int) async throws -> Direct115OfflinePage {
        guard page >= 1 else { throw Direct115OfflineError.server("离线任务页码无效") }
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
                if let parsed = Self.parseTaskPage(json, requestedPage: page) { return parsed }
                if Self.succeeded(json) {
                    return Direct115OfflinePage(tasks: [], total: 0, page: page, pageCount: 0)
                }
                let code = Self.errorCode(json)
                if code == 99 || code == 990001 { throw Direct115FileError.notLoggedIn }
                let message = Self.errorMessage(json)
                lastError = Direct115OfflineError.server(message.isEmpty ? "读取 115 离线任务失败" : message)
            } catch let error as Direct115FileError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 删除任务。`deleteFiles` 为 true 时连已经下载到网盘里的文件一起删除（进回收站）。
    func deleteOfflineTasks(_ hashes: [String], deleteFiles: Bool) async throws {
        let list = hashes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        for (position, batch) in Self.batches(list, size: Self.fileBatchSize).enumerated() {
            try Task.checkCancellation()
            if position > 0 { try await Task.sleep(nanoseconds: 300_000_000) }
            var form = ["flag": deleteFiles ? "1" : "0"]
            for (index, hash) in batch.enumerated() { form["hash[\(index)]"] = hash }
            try await offlineAction("task_del", form: form)
        }
    }

    func clearOfflineTasks(_ scope: Direct115OfflineClearScope) async throws {
        try await offlineAction("task_clear", form: ["flag": String(scope.rawValue)])
    }

    /// 文件夹的完整路径（从「网盘」开始）。只取一条记录，很快；读不到时返回空数组。
    func folderPath(id: String) async throws -> [String] {
        let cid = try Self.validatedID(id, allowRoot: true)
        guard var components = URLComponents(string: "https://webapi.115.com/files") else { throw APIError.badURL }
        components.queryItems = [
            URLQueryItem(name: "aid", value: "1"), URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "show_dir", value: "1"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "fc_mix", value: "0"),
        ]
        guard let url = components.url else { throw APIError.badURL }
        let json = try jsonObject(try await send(url))
        return Self.parseFolderPath(json)
    }

    /// 文件夹从根目录开始的每一级（带编号），用来在网盘里定位到它。读不到时返回空数组。
    func folderTrail(id: String) async throws -> [Direct115PathEntry] {
        let cid = try Self.validatedID(id, allowRoot: true)
        guard var components = URLComponents(string: "https://webapi.115.com/files") else { throw APIError.badURL }
        components.queryItems = [
            URLQueryItem(name: "aid", value: "1"), URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "show_dir", value: "1"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "fc_mix", value: "0"),
        ]
        guard let url = components.url else { throw APIError.badURL }
        let json = try jsonObject(try await send(url))
        return Self.parseFolderTrail(json)
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

    /// 原文件下载地址，用来播放还没有转码的视频，也用来下载到手机。
    /// 地址和请求时的 User-Agent 绑定，播放器、下载器要用同一个。
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

    /// 删除、清空这类只要知道成败的离线操作。两个接口地址依次尝试：第一个地址没有认出请求（没有成败信息）才换下一个。
    private func offlineAction(_ action: String, form: [String: String]) async throws {
        var body = form
        body["ac"] = action
        let endpoints = [
            "https://lixian.115.com/lixian/?ct=lixian&ac=\(action)",
            "https://clouddownload.115.com/web/?ac=\(action)",
        ]
        var lastError: Error = Direct115OfflineError.server("115 离线下载接口没有响应")
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await send(url, form: body)
                guard (200..<300).contains(response.statusCode) else {
                    lastError = Direct115HTTPError(statusCode: response.statusCode)
                    continue
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    lastError = Direct115OfflineError.server("115 离线下载接口返回了无法识别的结果")
                    continue
                }
                if Self.succeeded(json) { return }
                let code = Self.errorCode(json)
                let message = Self.errorMessage(json)
                if code == 99 || code == 990001 { throw Direct115FileError.notLoggedIn }
                guard code != 0 || !message.isEmpty else {
                    lastError = Direct115OfflineError.server("115 离线下载接口返回了无法识别的结果")
                    continue
                }
                throw Direct115OfflineError.server(message.isEmpty ? "115 离线下载操作失败（\(code)）" : message)
            } catch let error as Direct115OfflineError {
                throw error
            } catch let error as Direct115FileError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 解开添加结果，逐条链接看成败。结果对不上号时，按全部成功处理（任务确实已经交给 115 了）。
    static func addSummary(_ json: [String: Any], key: [UInt8], links: [String]) -> Direct115OfflineAddSummary {
        guard let text = json["data"] as? String, !text.isEmpty,
              let decoded = try? M115Cipher.decode(text, key: key),
              let object = try? JSONSerialization.jsonObject(with: Data(decoded)) as? [String: Any] else {
            return Direct115OfflineAddSummary(succeeded: links.count, failures: [])
        }
        return addSummary(results: object["result"] as? [[String: Any]] ?? [], links: links)
    }

    static func addSummary(results: [[String: Any]], links: [String]) -> Direct115OfflineAddSummary {
        var failures: [Direct115OfflineAddSummary.Failure] = []
        for (index, link) in links.enumerated() {
            guard index < results.count else { continue }
            let item = results[index]
            let code = errorCode(item)
            if code == 0 || code == 10008 || succeeded(item) { continue }
            let error: Direct115OfflineError
            switch code {
            case 10010: error = .quotaExhausted
            case 10004: error = .invalidLink
            default:
                let message = errorMessage(item)
                error = .server(message.isEmpty ? "115 离线下载失败（\(code)）" : message)
            }
            failures.append(.init(link: link, error: error))
        }
        return Direct115OfflineAddSummary(succeeded: links.count - failures.count, failures: failures)
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

    static func parseTaskPage(_ json: [String: Any], requestedPage page: Int) -> Direct115OfflinePage? {
        let container = json["data"] as? [String: Any] ?? json
        guard let rows = container["tasks"] as? [[String: Any]] ?? json["tasks"] as? [[String: Any]] else { return nil }
        let tasks = rows.map(parseTask)
        let total = Int(text(container["count"] ?? json["count"])) ?? Int(text(container["total"] ?? json["total"])) ?? 0
        let reportedPages = Int(text(container["page_count"] ?? json["page_count"])) ?? 0
        let pageCount = reportedPages > 0 ? reportedPages : (tasks.isEmpty ? 0 : page)
        return Direct115OfflinePage(tasks: tasks, total: max(total, tasks.count), page: page, pageCount: pageCount)
    }

    static func parseTask(_ raw: [String: Any]) -> Direct115OfflineTask {
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
            folderID: text(raw["wp_path_id"]),
            remoteHash: text(raw["info_hash"]),
            sourceURL: text(raw["url"]),
            addedAt: Direct115Value.date(raw["add_time"]),
            speed: max(0, Double(text(raw["rateDownload"])) ?? 0),
            remainingSeconds: max(0, Int(text(raw["left_time"])) ?? 0)
        )
    }

    static func parseFolderPath(_ json: [String: Any]) -> [String] {
        (json["path"] as? [[String: Any]] ?? []).compactMap { entry in
            if text(entry["cid"]) == "0" { return "网盘" }
            let name = text(entry["name"])
            return name.isEmpty ? nil : name
        }
    }

    static func parseFolderTrail(_ json: [String: Any]) -> [Direct115PathEntry] {
        (json["path"] as? [[String: Any]] ?? []).compactMap { entry -> Direct115PathEntry? in
            let id = text(entry["cid"])
            guard !id.isEmpty else { return nil }
            if id == "0" { return Direct115PathEntry(id: "0", name: "网盘") }
            let name = text(entry["name"])
            return name.isEmpty ? nil : Direct115PathEntry(id: id, name: name)
        }
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
