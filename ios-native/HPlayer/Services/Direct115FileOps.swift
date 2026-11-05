import Foundation

/// 从 115 的 JSON 里取值。同一个字段有时是数字、有时是带引号的文字，统一在这里转换。
enum Direct115Value {
    static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    static func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return Int(truncating: number) }
        if let text = value as? String {
            if let int = Int(text) { return int }
            if let double = Double(text), double.isFinite, abs(double) < 9e18 { return Int(double) }
        }
        return 0
    }

    /// 秒或毫秒级的时间戳，或者「2024-05-01 12:30」这样的文字
    static func date(_ value: Any?) -> Date? {
        let raw = text(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let number = Double(raw) {
            guard number.isFinite, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        for formatter in dateParsers {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static let dateParsers: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { (format: String) -> DateFormatter in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }
}

/// 115 网盘文件管理失败的原因，说明文字直接给用户看。
enum Direct115FileError: LocalizedError, Equatable {
    case invalidName
    case invalidID
    case nameExists
    case cyclicMove
    case cyclicCopy
    case notLoggedIn
    case needsSecurityKey(String)
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return "名称不能为空，也不能包含 / 或 \\"
        case .invalidID: return "文件编号无效，请刷新目录后重试"
        case .nameExists: return "这个位置已经有同名的文件或文件夹"
        case .cyclicMove: return "不能把文件夹移动到它自己里面"
        case .cyclicCopy: return "不能把文件夹复制到它自己里面"
        case .notLoggedIn: return "115 登录已失效，请重新登录"
        case .needsSecurityKey(let message): return message.isEmpty ? "需要正确的 115 安全密钥" : message
        case .server(let code, let message):
            if !message.isEmpty { return message }
            return code == 0 ? "115 操作失败，请稍后重试" : "115 操作失败（\(code)）"
        }
    }
}

/// 文件或文件夹的详细信息（来自 115 的「属性」接口）
struct Direct115FileInfo: Equatable {
    var name: String
    var isDirectory: Bool
    var pickCode: String
    var sha1: String
    /// 所在位置，从网盘根目录开始，例如 ["网盘", "电影"]
    var location: [String]
    var fileCount: Int
    var folderCount: Int
    /// 115 给出的带单位的大小，例如 "4.37GB"
    var sizeText: String
    var createdAt: Date?
    var modifiedAt: Date?
}

/// 回收站里的一项
struct Direct115RecycleItem: Identifiable, Equatable {
    /// 回收站里的编号（还原、彻底删除都用它）
    let id: String
    let name: String
    let size: Int
    let parentName: String
    let deletedAt: Date?
    let isDirectory: Bool
}

struct Direct115RecyclePage: Equatable {
    var items: [Direct115RecycleItem]
    var total: Int
    /// nil 表示已经到最后一页
    var nextOffset: Int?
}

/// 115 网盘文件管理：新建文件夹、重命名、移动、复制、删除到回收站、查看信息、回收站。
/// 接口和参数对照开源项目 115driver 与 p115client；都走网页登录的 Cookie，不经过任何服务器。
extension Direct115Client {
    /// 一次提交给 115 的文件数上限，更多的分批发送
    static let fileBatchSize = 100
    /// 分批之间稍作停顿，避免被 115 当成刷接口
    private static let batchPause: UInt64 = 300_000_000
    /// 回收站彻底删除默认使用的安全密钥；没有开启安全密钥的账号 115 接受这个值
    static let defaultSecurityKey = "000000"

    // MARK: 新建、重命名

    /// 在 `parentID` 下新建文件夹，返回新文件夹
    func createFolder(named rawName: String, in parentID: String) async throws -> P115File {
        let name = try Self.validatedName(rawName)
        let parent = try Self.validatedID(parentID, allowRoot: true)
        let json = try await formPost("https://webapi.115.com/files/add", form: ["pid": parent, "cname": name])
        if let failure = Self.operationFailure(json) { throw failure }
        let id = Direct115Value.text(json["cid"])
        guard !id.isEmpty, id != "0" else {
            throw Direct115FileError.server(code: 0, message: "115 没有返回新文件夹的编号，请刷新目录确认是否已创建")
        }
        let shown = Direct115Value.text(json["cname"])
        return P115File(id: id, parentId: parent, name: shown.isEmpty ? name : shown, isDir: true, kind: "folder", size: 0,
                        pickCode: "", sha1: "", updatedAt: String(Int(Date().timeIntervalSince1970)), thumbUrl: "")
    }

    func rename(_ id: String, to rawName: String) async throws {
        let name = try Self.validatedName(rawName)
        let fid = try Self.validatedID(id)
        let json = try await formPost("https://webapi.115.com/files/batch_rename",
                                      form: ["fid": fid, "file_name": name, "files_new_name[\(fid)]": name])
        if let failure = Self.operationFailure(json) { throw failure }
    }

    // MARK: 移动、复制、删除

    func move(_ ids: [String], to parentID: String) async throws {
        try await transfer("https://webapi.115.com/files/move", ids: ids, to: parentID)
    }

    func copy(_ ids: [String], to parentID: String) async throws {
        try await transfer("https://webapi.115.com/files/copy", ids: ids, to: parentID)
    }

    /// 删除：文件和文件夹都先进回收站，可以还原
    func moveToRecycleBin(_ ids: [String]) async throws {
        let list = try ids.map { try Self.validatedID($0) }
        try await Self.inBatches(list) { batch in
            var form: [String: String] = [:]
            for (index, id) in batch.enumerated() { form["fid[\(index)]"] = id }
            let json = try await self.formPost("https://webapi.115.com/rb/delete", form: form)
            if let failure = Self.operationFailure(json) { throw failure }
        }
    }

    private func transfer(_ address: String, ids: [String], to parentID: String) async throws {
        let parent = try Self.validatedID(parentID, allowRoot: true)
        let list = try ids.map { try Self.validatedID($0) }
        try await Self.inBatches(list) { batch in
            var form: [String: String] = ["pid": parent]
            for (index, id) in batch.enumerated() { form["fid[\(index)]"] = id }
            let json = try await self.formPost(address, form: form)
            if let failure = Self.operationFailure(json) { throw failure }
        }
    }

    // MARK: 文件信息

    /// 读取文件或文件夹的属性。文件夹要现算里面的数量和大小，可能要等几秒。
    func fileInfo(id: String) async throws -> Direct115FileInfo {
        let fid = try Self.validatedID(id)
        guard var components = URLComponents(string: "https://webapi.115.com/category/get") else { throw APIError.badURL }
        components.queryItems = [URLQueryItem(name: "cid", value: fid)]
        guard let url = components.url else { throw APIError.badURL }
        let json = try jsonObject(try await send(url, timeout: 60))
        return try Self.parseFileInfo(json, id: fid)
    }

    static func parseFileInfo(_ json: [String: Any], id: String) throws -> Direct115FileInfo {
        if (json["state"] as? Bool) == false, let failure = operationFailure(json) { throw failure }
        let name = Direct115Value.text(json["file_name"])
        guard !name.isEmpty else {
            throw Direct115FileError.server(code: 0, message: "115 没有返回这一项的信息，它可能已经被删除")
        }
        var location: [String] = []
        for entry in json["paths"] as? [[String: Any]] ?? [] {
            let entryID = Direct115Value.text(entry["file_id"])
            // 路径的最后一项有时就是它自己，位置里不需要
            if entryID == id { continue }
            let entryName = Direct115Value.text(entry["file_name"])
            location.append(entryID == "0" ? "网盘" : entryName)
        }
        return Direct115FileInfo(
            name: name,
            isDirectory: Direct115Value.text(json["file_category"]) == "0",
            pickCode: Direct115Value.text(json["pick_code"]),
            sha1: Direct115Value.text(json["sha1"]),
            location: location,
            fileCount: Direct115Value.integer(json["count"]),
            folderCount: Direct115Value.integer(json["folder_count"]),
            sizeText: Direct115Value.text(json["size"]),
            createdAt: Direct115Value.date(json["ptime"]),
            modifiedAt: Direct115Value.date(json["utime"])
        )
    }

    // MARK: 回收站

    func recycleBin(offset: Int = 0, limit: Int = 100) async throws -> Direct115RecyclePage {
        guard offset >= 0, (1...200).contains(limit) else { throw APIError.server("回收站分页参数无效") }
        guard var components = URLComponents(string: "https://webapi.115.com/rb") else { throw APIError.badURL }
        components.queryItems = [
            URLQueryItem(name: "aid", value: "7"), URLQueryItem(name: "cid", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw APIError.badURL }
        let json = try jsonObject(try await send(url))
        return try Self.parseRecyclePage(json, requestedOffset: offset, limit: limit)
    }

    static func parseRecyclePage(_ json: [String: Any], requestedOffset offset: Int, limit: Int) throws -> Direct115RecyclePage {
        if let state = json["state"] as? Bool, !state {
            throw operationFailure(json) ?? Direct115FileError.server(code: 0, message: "")
        }
        let rows = json["data"] as? [[String: Any]] ?? []
        let items = rows.compactMap { row -> Direct115RecycleItem? in
            let id = Direct115Value.text(row["id"])
            guard !id.isEmpty else { return nil }
            let name = Direct115Value.text(row["file_name"])
            let icon = Direct115Value.text(row["ico"])
            // 回收站的返回里没有明确的文件夹标记：图标是 folder 就是文件夹；没有图标时，没有校验值也没有扩展名的当文件夹
            let looksLikeFolder = icon == "folder"
                || (icon.isEmpty && Direct115Value.text(row["sha1"]).isEmpty && (name as NSString).pathExtension.isEmpty)
            return Direct115RecycleItem(
                id: id, name: name.isEmpty ? "未命名" : name,
                size: Direct115Value.integer(row["file_size"]),
                parentName: Direct115Value.text(row["parent_name"]),
                deletedAt: Direct115Value.date(row["dtime"]),
                isDirectory: looksLikeFolder
            )
        }
        let total = Direct115Value.integer(json["count"])
        let next = offset + rows.count
        let hasMore = !rows.isEmpty && (total > 0 ? next < total : rows.count >= limit)
        return Direct115RecyclePage(items: items, total: max(total, offset + items.count), nextOffset: hasMore ? next : nil)
    }

    func restoreFromRecycleBin(_ ids: [String]) async throws {
        let list = try ids.map { try Self.validatedID($0) }
        try await Self.inBatches(list) { batch in
            var form: [String: String] = [:]
            for (index, id) in batch.enumerated() { form["rid[\(index)]"] = id }
            let json = try await self.formPost("https://webapi.115.com/rb/revert", form: form)
            if let failure = Self.operationFailure(json) { throw failure }
        }
    }

    /// 从回收站彻底删除。`ids` 为空表示清空回收站。
    /// 安全密钥是 6 位数字；账号没有开启时用默认值即可。
    func deleteFromRecycleBin(_ ids: [String], securityKey: String = Direct115Client.defaultSecurityKey) async throws {
        let key = try Self.validatedSecurityKey(securityKey)
        let list = try ids.map { try Self.validatedID($0) }
        let batches: [[String]] = list.isEmpty ? [[]] : Self.batches(list, size: Self.fileBatchSize)
        for (position, batch) in batches.enumerated() {
            if position > 0 { try await Task.sleep(nanoseconds: Self.batchPause) }
            var form: [String: String] = ["password": key]
            for (index, id) in batch.enumerated() { form["rid[\(index)]"] = id }
            let json = try await formPost("https://webapi.115.com/rb/clean", form: form)
            if var failure = Self.operationFailure(json) {
                if case .server(_, let message) = failure, message.contains("密") {
                    failure = .needsSecurityKey(message)
                }
                throw failure
            }
        }
    }

    // MARK: 下载到手机

    /// 请求头里用的 Cookie：去掉保存下来的 Cookie 文本里的 path、domain、expires 这类属性，只留名称=值
    var requestCookie: String {
        cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { pair in
                guard let equals = pair.firstIndex(of: "=") else { return false }
                let name = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !name.isEmpty && !["path", "domain", "expires", "max-age", "samesite"].contains(name)
            }
            .joined(separator: "; ")
    }

    /// 下载原文件的请求：请求头和播放器打开原画时一致（同一个 User-Agent、Referer 和登录 Cookie）
    func downloadRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        let header = requestCookie
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        return request
    }

    // MARK: 校验与请求

    static func validatedID(_ raw: String, allowRoot: Bool = false) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }), allowRoot || id != "0" else {
            throw Direct115FileError.invalidID
        }
        return id
    }

    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Direct115FileError.invalidName
        }
        return name
    }

    static func validatedSecurityKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 6, key.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Direct115FileError.needsSecurityKey("安全密钥是 6 位数字")
        }
        return key
    }

    static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private static func inBatches(_ items: [String], _ body: ([String]) async throws -> Void) async throws {
        for (position, batch) in batches(items, size: fileBatchSize).enumerated() {
            try Task.checkCancellation()
            if position > 0 { try await Task.sleep(nanoseconds: batchPause) }
            try await body(batch)
        }
    }

    /// 解析 115 的操作结果。成功返回 nil，失败返回给用户看的原因。
    static func operationFailure(_ json: [String: Any]) -> Direct115FileError? {
        if let state = json["state"] as? Bool, state { return nil }
        if let state = json["state"] as? NSNumber, state.intValue != 0 { return nil }
        var code = 0
        for key in ["errno", "errNo", "errcode", "errCode", "error_code", "code"] {
            let value = Direct115Value.integer(json[key])
            if value != 0 { code = value; break }
        }
        var message = ""
        for key in ["error", "msg", "message", "error_msg"] {
            let value = Direct115Value.text(json[key])
            if !value.isEmpty { message = value; break }
        }
        switch code {
        case 20004: return .nameExists
        case 91002: return .cyclicCopy
        case 800006: return .cyclicMove
        case 99, 990001: return .notLoggedIn
        default: return .server(code: code, message: message)
        }
    }

    func formPost(_ address: String, form: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw APIError.badURL }
        return try jsonObject(try await send(url, form: form))
    }

    func jsonObject(_ result: (Data, HTTPURLResponse)) throws -> [String: Any] {
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else { throw Direct115HTTPError(statusCode: response.statusCode) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.server("115 返回的数据无法识别")
        }
        return json
    }
}
