import Foundation

/// 登录状态：115 的登录、浏览和播放都直接在手机上完成，不需要自己的服务器。
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool
    @Published var isLoading = false
    /// 查询的生命周期跟随会话，而不只跟随账号编号；重新登录同一账号也会更换凭证。
    @Published private(set) var sessionID = UUID()

    private let cookieLoader: () -> String?
    private let cookieValidator: (String) async throws -> Void
    private let cookieSaver: (String) -> Void
    private let cookieRemover: () -> Void
    private var connectionID = UUID()
    /// 读钥匙串要和系统服务通信，首页每刷新一次、打开播放页都会问一遍登录账号，
    /// 所以读到之后放在内存里；登录、退出时同步更新。
    private var cachedCookie: String?
    private var cookieIsCached = false

    init(cookieLoader: @escaping () -> String? = { Keychain.load("hplayer.115.cookie") },
         cookieValidator: @escaping (String) async throws -> Void = { _ = try await Direct115Client(cookie: $0).user() },
         cookieSaver: @escaping (String) -> Void = { Keychain.save($0, for: "hplayer.115.cookie") },
         cookieRemover: @escaping () -> Void = { Keychain.delete("hplayer.115.cookie") }) {
        self.cookieLoader = cookieLoader
        self.cookieValidator = cookieValidator
        self.cookieSaver = cookieSaver
        self.cookieRemover = cookieRemover
        let saved = cookieLoader()
        cachedCookie = saved
        cookieIsCached = true
        // 恢复本机登录状态不需要等页面的 task 或网络请求，首页首帧即可显示已保存的媒体库。
        isAuthenticated = Self.hasSavedSession(saved)
    }

    var directCookie: String? {
        if !cookieIsCached {
            cachedCookie = cookieLoader()
            cookieIsCached = true
        }
        return cachedCookie
    }

    /// 媒体库只使用账号编号分区，不把 Cookie 写进资料缓存。
    var libraryAccountID: String? { Self.accountID(in: directCookie) }

    static func hasSavedSession(_ cookie: String?) -> Bool {
        !(cookie?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static func accountID(in cookie: String?) -> String? {
        for part in (cookie ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0] == "UID",
                  let prefix = pair[1].split(separator: "_").first, !prefix.isEmpty,
                  prefix.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            return "device:\(prefix)"
        }
        return nil
    }

    func connectDirect(cookie: String) async throws {
        try Task.checkCancellation()
        let request = UUID()
        connectionID = request
        try await cookieValidator(cookie)
        try Task.checkCancellation()
        // 退出登录或新的登录请求会让较早的验证失效，即使服务没有及时响应取消。
        guard connectionID == request else { throw CancellationError() }
        cookieSaver(cookie)
        cachedCookie = cookie
        cookieIsCached = true
        isAuthenticated = true
        sessionID = UUID()
    }

    func directClient() -> Direct115Client? {
        guard isAuthenticated, let cookie = directCookie, Self.hasSavedSession(cookie) else { return nil }
        return Direct115Client(cookie: cookie)
    }

    func checkAuth() async {
        // 启动时重新读一次钥匙串：App 在手机解锁之前被系统预启动的话，第一次可能读不到
        let previous = directCookie
        cookieIsCached = false
        let restored = directCookie
        isAuthenticated = Self.hasSavedSession(restored)
        if previous != restored { sessionID = UUID() }
        isLoading = false
    }

    func logout() {
        connectionID = UUID()
        cookieRemover()
        cachedCookie = nil
        cookieIsCached = true
        isAuthenticated = false
        sessionID = UUID()
    }

    /// 115 开放平台接口（云下载、种子），在手机上本地实现
    func client() -> APIClient? { APIClient() }
}
