import Foundation

// MARK: - 弹幕

/// 一条弹幕。接口里 `content` 本身是一个 JSON 字符串：{"color": ARGB 整数, "content": 文本}。
struct AnimeDanmaku: Identifiable, Hashable {
    let id: String
    /// 出现时间（秒）
    let time: Double
    let text: String
    /// ARGB；nil = 默认白色
    let color: UInt32?

    init(id: String, time: Double, text: String, color: UInt32?) {
        self.id = id
        self.time = time
        self.text = text
        self.color = color
    }

    init?(json: [String: Any]) {
        let rawID = json["id"].map { "\($0)" } ?? UUID().uuidString
        let point = AnimeJSON.double(json["time_point"]) ?? 0
        guard let content = json["content"] as? String, !content.isEmpty else { return nil }
        var text = content
        var color: UInt32?
        if let data = content.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            text = (inner["content"] as? String) ?? content
            if let value = AnimeJSON.double(inner["color"]), value > 0, value <= Double(UInt32.max) {
                color = UInt32(value)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.init(id: rawID, time: point / 1000, text: text, color: color)
    }

    static func list(from data: Any) -> [AnimeDanmaku] {
        AnimeJSON.records(in: data).compactMap(AnimeDanmaku.init(json:))
    }
}

// MARK: - 评论

enum AnimeCommentKind: Hashable {
    case top, hot, list
}

/// 一页评论。rawCount 是接口返回的记录数：有记录却一条都解析不出来，说明字段对不上。
struct AnimeCommentPage {
    let items: [AnimeComment]
    let rawCount: Int
}

/// 一条评论。API 文档没有展开评论的解密结构，这里按常见字段名宽松解析；
/// 认不出正文的记录直接跳过（页面会提示「评论格式暂不支持」）。
struct AnimeComment: Identifiable, Hashable {
    let id: String
    let userName: String
    let content: String
    let time: String
    let likes: Int
    let replies: Int
    let pinned: Bool
    let hot: Bool
    let vip: Bool
    /// 身份标签，例如「管理员」
    let role: String

    init?(json: [String: Any], kind: AnimeCommentKind) {
        let user = json["user"] as? [String: Any] ?? json["users"] as? [String: Any] ?? [:]
        guard let content = AnimeJSON.string(json, ["comments", "content", "comment", "text", "body"]),
              !content.isEmpty else { return nil }
        id = AnimeJSON.string(json, ["id", "cid", "comment_id"]) ?? UUID().uuidString
        userName = AnimeJSON.string(json, ["user_name", "username", "nickname", "nick_name", "uname", "name"])
            ?? AnimeJSON.string(user, ["user_name", "username", "nickname", "nick_name", "name"]) ?? "动漫用户"
        self.content = content
        time = AnimeComment.displayTime(AnimeJSON.string(json, ["created_at", "create_time", "createtime", "addtime", "time", "updated_at"]) ?? "")
        likes = AnimeJSON.int(json, ["likes", "like", "like_num", "likes_count", "like_count", "zan", "up", "hits"]) ?? 0
        let replyList = (json["sub"] as? [Any]) ?? (json["children"] as? [Any]) ?? (json["replies"] as? [Any])
        replies = AnimeJSON.int(json, ["children_total", "sub_count", "reply_count", "replies_count", "child_count", "subcount", "reply_num"]) ?? replyList?.count ?? 0
        pinned = kind == .top || (AnimeJSON.int(json, ["istop"]) ?? 0) > 0
        hot = kind == .hot
        vip = DramaJSON.bool(json["isvip"])
        role = AnimeJSON.string(((json["roles"] as? [[String: Any]]) ?? []).first ?? [:], ["group_name"]) ?? ""
    }

    static func list(from data: Any, kind: AnimeCommentKind) -> [AnimeComment] {
        AnimeJSON.records(in: data).compactMap { AnimeComment(json: $0, kind: kind) }
    }

    /// 「2026-11-09T21:05:33+08:00」→「11-09 21:05」；纯数字按秒或毫秒时间戳处理。
    static func displayTime(_ raw: String) -> String {
        if let number = Double(raw), number > 0 {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        let cleaned = raw.replacingOccurrences(of: "T", with: " ")
        if cleaned.count >= 16 {
            let start = cleaned.index(cleaned.startIndex, offsetBy: 5)
            let end = cleaned.index(cleaned.startIndex, offsetBy: 16)
            return String(cleaned[start..<end])
        }
        return cleaned
    }
}

// MARK: - 宽松 JSON 读取

enum AnimeJSON {
    /// 从 `data` 里找出记录数组：可能本身就是数组，也可能包在 items / list / rows / data 里。
    static func records(in data: Any) -> [[String: Any]] {
        if let array = data as? [[String: Any]] { return array }
        if let dict = data as? [String: Any] {
            for key in ["items", "list", "rows", "data", "records", "comments"] {
                if let value = dict[key] {
                    let found = records(in: value)
                    if !found.isEmpty { return found }
                }
            }
        }
        return []
    }

    static func string(_ json: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] {
                if let text = value as? String, !text.isEmpty { return text }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    static func int(_ json: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = double(json[key]) { return Int(value) }
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
