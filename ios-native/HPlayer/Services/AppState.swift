import Foundation

/// 登录状态：115 的登录、浏览和播放都直接在手机上完成，不需要自己的服务器。
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool
    @Published var isLoading = false

    private static let cookieKey = "hplayer.115.cookie"
    private let cookieLoader: () -> String?

    init(cookieLoader: @escaping () -> String? = { Keychain.load("hplayer.115.cookie") }) {
        self.cookieLoader = cookieLoader
        // 恢复本机登录状态不需要等页面的 task 或网络请求，首页首帧即可显示已保存的媒体库。
        isAuthenticated = Self.hasSavedSession(cookieLoader())
    }

    var directCookie: String? { cookieLoader() }

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
        _ = try await Direct115Client(cookie: cookie).user()
        Keychain.save(cookie, for: Self.cookieKey)
        isAuthenticated = true
    }

    func directClient() -> Direct115Client? {
        guard let cookie = directCookie, !cookie.isEmpty else { return nil }
        return Direct115Client(cookie: cookie)
    }

    func checkAuth() async {
        isAuthenticated = Self.hasSavedSession(directCookie)
        isLoading = false
    }

    func logout() {
        Keychain.delete(Self.cookieKey)
        isAuthenticated = false
    }

    /// 115 开放平台接口（云下载、种子），在手机上本地实现
    func client() -> APIClient? { APIClient() }
}
