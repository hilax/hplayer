import Foundation
import SwiftUI
import UIKit

// MARK: - 模型

/// HPlayer 账号（动漫接口的用户）。字段来自 `GET /app/users/info` 的 GUserInfo。
struct AnimeUser: Codable, Equatable {
    let id: Int
    let name: String
    let email: String
    let phone: String
    let avatarURL: String
    /// 金币
    let coin: Int
    /// 连续签到天数
    let signDays: Int
    let isVip: Bool

    init(json: [String: Any]) {
        id = AnimeJSON.int(json, ["id"]) ?? 0
        name = AnimeJSON.string(json, ["user_name", "uname", "nickname"]) ?? ""
        email = AnimeJSON.string(json, ["email"]) ?? ""
        phone = AnimeJSON.string(json, ["phone"]) ?? ""
        avatarURL = AnimeAccount.usableImageURL(AnimeJSON.string(json, ["pic_url"]) ?? "")
        coin = AnimeJSON.int(json, ["coin"]) ?? 0
        signDays = AnimeJSON.int(json, ["signnum"]) ?? 0
        isVip = AnimeJSON.bool(json["isvip"])
    }

    /// 卡片上显示的名字：没有昵称时用邮箱或手机号
    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        if !phone.isEmpty { return phone }
        return "HPlayer 用户"
    }
}

/// 任务中心的一项。`/app/task` 的字段没有完整文档，按签到规则（sign_rule）里见到的字段宽松解析。
struct AnimeTask: Identifiable, Equatable {
    let id: String
    let title: String
    let memo: String
    /// 完成奖励的金币
    let coin: Int
    /// sign / video / …
    let action: String
    /// 已完成次数 / 需要次数（接口没给时为 nil）
    let done: Int?
    let total: Int?
    let finished: Bool

    init?(json: [String: Any]) {
        guard let title = AnimeJSON.string(json, ["title", "name"]) else { return nil }
        id = AnimeJSON.string(json, ["id", "action"]) ?? title
        self.title = title
        memo = AnimeJSON.string(json, ["memo", "desc", "description"]) ?? ""
        coin = AnimeJSON.int(json, ["coin", "gold", "reward"]) ?? 0
        action = AnimeJSON.string(json, ["action"]) ?? ""
        total = AnimeJSON.int(json, ["num", "max", "total", "limit"])
        done = AnimeJSON.int(json, ["finish_num", "finished_num", "done", "count", "progress", "user_num"])
        // 完成标记的字段名没有文档：常见写法都认一遍（isfinish、is_complete、today_finish…）
        let flagKey = json.keys.first { key in
            let lower = key.lowercased()
            return ["finish", "complete", "issign", "is_sign", "signed", "is_done", "isdone"].contains { lower.contains($0) }
        }
        let flag = flagKey.flatMap { json[$0] }
        if let flag, !(flag is [Any]), !(flag is [String: Any]) {
            finished = AnimeJSON.bool(flag)
        } else if let done, let total, total > 0 {
            finished = done >= total
        } else {
            finished = false
        }
    }

    var isSign: Bool { action == "sign" || title.contains("签到") }
}

/// 一条消息（回复我的 / 系统通知 / 反馈）。`/app/messagebox/reply` 字段来自实测及反编译模型。
struct AnimeMessage: Identifiable, Equatable {
    let id: String
    let numericID: Int
    let sender: String
    let title: String
    let content: String
    /// 被回复的我的那条评论
    let quote: String
    /// 被引用原评论的作者名
    let quoteAuthor: String
    let time: String
    let videoID: Int?
    let videoName: String
    let unread: Bool

    init?(json: [String: Any], kind: AnimeMessageKind? = nil) {
        let text = AnimeJSON.string(json, ["content", "comments", "message", "msg", "reply", "body"]) ?? ""
        let title = AnimeJSON.string(json, ["title", "subject"]) ?? ""
        guard !text.isEmpty || !title.isEmpty else { return nil }
        id = AnimeJSON.string(json, ["id", "mid"]) ?? UUID().uuidString
        numericID = AnimeJSON.int(json, ["id", "mid"]) ?? 0
        let isReply = (kind == .reply) || json["quote_comments"] != nil || json["quote_name"] != nil
        sender = AnimeJSON.string(json, isReply
            ? ["uname", "user_name", "name", "from_name", "sender", "nickname"]
            : ["uname", "user_name", "from_name", "sender", "nickname"]) ?? ""
        self.title = title
        content = text
        quote = AnimeJSON.string(json, ["quote_comments", "last_comments", "last_content", "quote", "source_content", "my_comments"]) ?? ""
        quoteAuthor = AnimeJSON.string(json, ["quote_name", "last_name"]) ?? ""
        time = AnimeComment.displayTime(AnimeJSON.string(json, ["created_at", "updated_at", "time"]) ?? "")
        videoID = AnimeJSON.int(json, ["vid", "video_id"])
        videoName = AnimeJSON.string(json, isReply ? ["vname", "video_name"] : ["vname", "video_name", "name"]) ?? ""
        let read = json["isread"] ?? json["is_read"] ?? json["read"] ?? json["state"]
        unread = read.map { !AnimeJSON.bool($0) } ?? false
    }
}

/// 消息的四类（`/app/messagebox/…`）
enum AnimeMessageKind: String, CaseIterable, Identifiable {
    case reply, sys, fromReport = "from_report", helpReport = "help_report"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reply: return "回复"
        case .sys: return "系统"
        case .fromReport: return "影片反馈"
        case .helpReport: return "求片反馈"
        }
    }
}

/// 登录、注册用哪种账号
enum AnimeAccountKind: String, CaseIterable, Identifiable {
    case email, phone
    var id: String { rawValue }
    var title: String { self == .email ? "邮箱" : "手机号" }
    /// 接口里的 enum 字段：整数，1 = 邮箱，2 = 手机号（传字符串或 0 都返回「参数错误」，实测）
    var code: Int { self == .email ? 1 : 2 }
}

/// 图片算术验证码（例：「6 × 9 = ?」）。答案填进 dots 提交。
struct AnimeCaptcha: Equatable {
    let uuid: String
    let image: UIImage

    static func == (lhs: AnimeCaptcha, rhs: AnimeCaptcha) -> Bool { lhs.uuid == rhs.uuid }
}

// MARK: - 账号状态

/// HPlayer 账号：登录 / 注册 / 退出，用户资料、签到任务、消息。
/// 令牌存在钥匙串（AnimeSigner），这里只管界面要的状态。115 网盘账号在「网盘」页，和这里无关。
@MainActor
final class AnimeAccount: ObservableObject {
    static let shared = AnimeAccount()

    @Published private(set) var isSignedIn: Bool
    @Published private(set) var user: AnimeUser?
    @Published private(set) var tasks: [AnimeTask] = []
    @Published private(set) var signCoin = 30
    /// 各类消息的未读数（汇总接口给的话）
    @Published private(set) var unread: [AnimeMessageKind: Int] = [:]
    @Published private(set) var loadingUser = false
    @Published var lastError = ""

    nonisolated private static let cachedUserKey = "hplayer.anime.cachedUser"
    private var sessionObserver: NSObjectProtocol?
    private var lastRefreshedAt: Date?
    private let refreshThrottle: TimeInterval = 60

    private init() {
        isSignedIn = !InterfacePreview.active && AnimeSigner.shared.hasUserToken
        if isSignedIn, let cached = Self.loadCachedUser() {
            user = cached
            signedDay = UserDefaults.standard.string(forKey: signedDayKey) ?? ""
        }
        sessionObserver = NotificationCenter.default.addObserver(forName: .animeSessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clearSession(message: "登录已过期，请重新登录") }
        }
    }

    var totalUnread: Int { unread.values.reduce(0, +) }

    /// 今天的签到任务完成了没有：任务列表说完成了，或者本机记着今天签过（签到成功 / 服务端说已经签过）
    var signedToday: Bool {
        (tasks.first(where: \.isSign)?.finished ?? false) || signedDay == Self.today()
    }

    /// 本机记的最近一次签到日期（按账号分开记）
    @Published private var signedDay: String = ""

    private var signedDayKey: String { "anime.signedDay.\(user?.id ?? 0)" }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func rememberSignedToday() {
        signedDay = Self.today()
        UserDefaults.standard.set(signedDay, forKey: signedDayKey)
    }

    // MARK: 验证码

    /// 注册发验证码前的图形验证码。scene：register
    func captcha(scene: String) async throws -> AnimeCaptcha {
        let data = try await AnimeClient.shared.perform("/app/users/captcha", method: "POST", body: ["type": scene])
        return try Self.decodeCaptcha(data)
    }

    /// 发评论、发弹幕被要求验证时的验证码
    func commentCaptcha() async throws -> AnimeCaptcha {
        try Self.decodeCaptcha(try await AnimeClient.shared.perform("/app/vod_comment/captcha"))
    }

    private static func decodeCaptcha(_ data: Any) throws -> AnimeCaptcha {
        guard let json = data as? [String: Any],
              let uuid = AnimeJSON.string(json, ["uuid"]),
              let base64 = AnimeJSON.string(json, ["image_base64", "image", "img"]) else {
            throw AnimeClientError.emptyData
        }
        let payload = base64.components(separatedBy: ",").last ?? base64
        guard let bytes = Data(base64Encoded: payload), let image = UIImage(data: bytes) else {
            throw AnimeClientError.emptyData
        }
        return AnimeCaptcha(uuid: uuid, image: image)
    }

    // MARK: 注册 / 登录 / 退出

    private func accountFields(_ kind: AnimeAccountKind, _ account: String) -> [String: Any] {
        let value = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["email": kind == .email ? value : "", "phone": kind == .phone ? value : "", "enum": kind.code]
    }

    /// 发邮箱 / 短信验证码（注册用），要先答对图形验证码
    func sendCode(kind: AnimeAccountKind, account: String, captcha: AnimeCaptcha, answer: String) async throws {
        var body = accountFields(kind, account)
        body["type"] = "register"
        body["uuid"] = captcha.uuid
        body["dots"] = answer.trimmingCharacters(in: .whitespaces)
        try await AnimeClient.shared.perform("/app/users/smscode", method: "POST", body: body)
    }

    func register(kind: AnimeAccountKind, account: String, nickname: String, code: String, password: String) async throws {
        var body = accountFields(kind, account)
        body["user_name"] = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        body["smscode"] = code.trimmingCharacters(in: .whitespaces)
        body["password"] = password
        try await AnimeClient.shared.perform("/app/users/register", method: "POST", body: body)
    }

    /// 登录只要账号和密码，不用验证码
    func signIn(kind: AnimeAccountKind, account: String, password: String) async throws {
        var body = accountFields(kind, account)
        body["password"] = password
        let data = try await AnimeClient.shared.perform("/app/users/login", method: "POST", body: body)
        guard let json = data as? [String: Any], let token = AnimeJSON.string(json, ["token"]),
              token.split(separator: ".").count == 3 else {
            throw AnimeClientError.emptyData
        }
        AnimeSigner.shared.setUserToken(token)
        isSignedIn = true
        lastError = ""
        Haptics.success()
        await refresh()
    }

    func signOut() async {
        // 先告诉服务端；失败也照样清掉本机的登录
        _ = try? await AnimeClient.shared.call("/app/users/logout", method: "POST")
        clearSession(message: "")
    }

    private func clearSession(message: String) {
        AnimeSigner.shared.setUserToken(nil)
        isSignedIn = false
        user = nil
        tasks = []
        unread = [:]
        signedDay = ""
        lastRefreshedAt = nil
        Self.clearCachedUser()
        lastError = message
    }

    // MARK: 资料、任务、消息

    /// 登录后拉一遍资料、任务和消息汇总（原 App 登录后也是这三个请求）
    func refresh() async {
        guard isSignedIn, !InterfacePreview.active else { return }
        loadingUser = true
        defer { loadingUser = false }
        async let info: Void = loadUser()
        async let taskList: Void = loadTasks()
        async let summary: Void = loadUnread()
        _ = await (info, taskList, summary)
        if user != nil { lastRefreshedAt = Date() }
    }

    func refreshIfNeeded() async {
        guard isSignedIn, !InterfacePreview.active, !loadingUser else { return }
        if let lastRefreshedAt, user != nil, Date().timeIntervalSince(lastRefreshedAt) < refreshThrottle {
            return
        }
        await refresh()
    }

    private func loadUser() async {
        do {
            let data = try await AnimeClient.shared.perform("/app/users/info")
            if let json = data as? [String: Any] {
                let fetched = AnimeUser(json: json)
                user = fetched
                Self.saveCachedUser(fetched)
                signedDay = UserDefaults.standard.string(forKey: signedDayKey) ?? ""
            }
        } catch {
            if isSignedIn { lastError = error.userMessage }
        }
    }

    func loadTasks() async {
        if let rule = try? await AnimeClient.shared.perform("/app/task/sign_rule") as? [String: Any],
           let coin = AnimeJSON.int(rule, ["coin"]) {
            signCoin = coin
        }
        guard isSignedIn, let data = try? await AnimeClient.shared.perform("/app/task") else { return }
        tasks = AnimeJSON.records(in: data).compactMap(AnimeTask.init(json:))
        if tasks.first(where: \.isSign)?.finished == true {
            rememberSignedToday()
        }
    }

    nonisolated static func saveCachedUser(_ user: AnimeUser, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: cachedUserKey)
    }

    nonisolated static func loadCachedUser(from defaults: UserDefaults = .standard) -> AnimeUser? {
        guard let data = defaults.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(AnimeUser.self, from: data)
    }

    nonisolated static func clearCachedUser(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: cachedUserKey)
    }

    private func loadUnread() async {
        guard let data = try? await AnimeClient.shared.perform("/app/messagebox") else { return }
        unread = Self.unreadCounts(in: data)
    }

    /// 汇总接口的结构没有展开：可能是 {sys: n, reply: n…}，也可能是 [{type, count}]
    static func unreadCounts(in data: Any) -> [AnimeMessageKind: Int] {
        var result: [AnimeMessageKind: Int] = [:]
        if let dict = data as? [String: Any] {
            for kind in AnimeMessageKind.allCases {
                if let value = dict[kind.rawValue] {
                    if let count = AnimeJSON.double(value) { result[kind] = Int(count) }
                    else if let inner = value as? [String: Any],
                            let count = AnimeJSON.int(inner, ["unread", "count", "num", "total"]) { result[kind] = count }
                }
            }
        }
        for record in AnimeJSON.records(in: data) {
            guard let type = AnimeJSON.string(record, ["type", "key", "action"]),
                  let kind = AnimeMessageKind(rawValue: type),
                  let count = AnimeJSON.int(record, ["unread", "count", "num", "total"]) else { continue }
            result[kind] = count
        }
        return result.filter { $0.value > 0 }
    }

    /// 每日签到。服务端回「任务已被完成」说明今天已经签过：当成签到成功，不再提示错误
    func signToday() async throws {
        do {
            try await AnimeClient.shared.perform("/app/task/sign", method: "POST", body: [:])
            Haptics.success()
        } catch {
            let text = error.userMessage
            guard text.contains("已被完成") || text.contains("已签到") || text.contains("已经签到") else { throw error }
        }
        rememberSignedToday()
        await refresh()
    }

    func messages(_ kind: AnimeMessageKind, page: Int) async throws -> [AnimeMessage] {
        let data = try await AnimeClient.shared.perform("/app/messagebox/\(kind.rawValue)?limit=20&page=\(page)")
        return AnimeJSON.records(in: data).compactMap { AnimeMessage(json: $0, kind: kind) }
    }

    func markRead(_ kind: AnimeMessageKind) {
        unread[kind] = nil
    }

    /// 接口里的头像地址是占位域名（6666.com），换不出真实地址时当作没有头像
    nonisolated static func usableImageURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host, !host.contains("6666.com") else { return "" }
        return raw
    }
}
