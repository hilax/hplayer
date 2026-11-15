import Foundation
import SwiftUI
import UIKit

// MARK: - 模型

/// HPlayer 账号（动漫接口的用户）。字段来自 `GET /app/users/info` 的 GUserInfo。
struct AnimeUser: Equatable {
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
        isVip = DramaJSON.bool(json["isvip"])
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
        let flag = json["isfinish"] ?? json["is_finish"] ?? json["finished"] ?? json["is_sign"] ?? json["issign"] ?? json["complete"]
        if let flag {
            finished = DramaJSON.bool(flag)
        } else if let done, let total, total > 0 {
            finished = done >= total
        } else {
            finished = false
        }
    }

    var isSign: Bool { action == "sign" || title.contains("签到") }
}

/// 一条消息（回复我的 / 系统通知 / 反馈）。字段同样按常见名字宽松解析。
struct AnimeMessage: Identifiable, Equatable {
    let id: String
    let sender: String
    let title: String
    let content: String
    /// 被回复的我的那条评论
    let quote: String
    let time: String
    let videoID: Int?
    let videoName: String
    let unread: Bool

    init?(json: [String: Any]) {
        let text = AnimeJSON.string(json, ["content", "comments", "message", "msg", "reply", "body"]) ?? ""
        let title = AnimeJSON.string(json, ["title", "subject"]) ?? ""
        guard !text.isEmpty || !title.isEmpty else { return nil }
        id = AnimeJSON.string(json, ["id", "mid"]) ?? UUID().uuidString
        sender = AnimeJSON.string(json, ["uname", "user_name", "from_name", "sender", "nickname"]) ?? ""
        self.title = title
        content = text
        quote = AnimeJSON.string(json, ["last_comments", "last_content", "quote", "source_content", "my_comments"]) ?? ""
        time = AnimeComment.displayTime(AnimeJSON.string(json, ["created_at", "updated_at", "time"]) ?? "")
        videoID = AnimeJSON.int(json, ["vid", "video_id"])
        videoName = AnimeJSON.string(json, ["vname", "video_name", "name"]) ?? ""
        let read = json["isread"] ?? json["is_read"] ?? json["read"] ?? json["state"]
        unread = read.map { !DramaJSON.bool($0) } ?? false
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

    private var sessionObserver: NSObjectProtocol?

    private init() {
        isSignedIn = !InterfacePreview.active && AnimeSigner.shared.hasUserToken
        sessionObserver = NotificationCenter.default.addObserver(forName: .animeSessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clearSession(message: "登录已过期，请重新登录") }
        }
    }

    var totalUnread: Int { unread.values.reduce(0, +) }

    /// 今天的签到任务完成了没有
    var signedToday: Bool { tasks.first(where: \.isSign)?.finished ?? false }

    // MARK: 验证码

    /// 登录 / 注册前的图形验证码。scene：login、register
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
        return ["email": kind == .email ? value : "", "phone": kind == .phone ? value : "", "enum": kind.rawValue]
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

    func signIn(kind: AnimeAccountKind, account: String, password: String, captcha: AnimeCaptcha?, answer: String) async throws {
        var body = accountFields(kind, account)
        body["password"] = password
        if let captcha {
            body["uuid"] = captcha.uuid
            body["dots"] = answer.trimmingCharacters(in: .whitespaces)
        }
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
    }

    func refreshIfNeeded() async {
        guard isSignedIn, user == nil, !loadingUser else { return }
        await refresh()
    }

    private func loadUser() async {
        do {
            let data = try await AnimeClient.shared.perform("/app/users/info")
            if let json = data as? [String: Any] { user = AnimeUser(json: json) }
        } catch {
            if isSignedIn { lastError = error.localizedDescription }
        }
    }

    func loadTasks() async {
        if let rule = try? await AnimeClient.shared.perform("/app/task/sign_rule") as? [String: Any],
           let coin = AnimeJSON.int(rule, ["coin"]) {
            signCoin = coin
        }
        guard isSignedIn, let data = try? await AnimeClient.shared.perform("/app/task") else { return }
        tasks = AnimeJSON.records(in: data).compactMap(AnimeTask.init(json:))
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

    /// 每日签到
    func signToday() async throws {
        try await AnimeClient.shared.perform("/app/task/sign", method: "POST", body: [:])
        Haptics.success()
        await refresh()
    }

    func messages(_ kind: AnimeMessageKind, page: Int) async throws -> [AnimeMessage] {
        let data = try await AnimeClient.shared.perform("/app/messagebox/\(kind.rawValue)?limit=20&page=\(page)")
        return AnimeJSON.records(in: data).compactMap(AnimeMessage.init(json:))
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
