import Foundation

/// 登录状态：115 的登录、浏览和播放都直接在手机上完成，不需要自己的服务器。
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true

    private static let cookieKey = "hplayer.115.cookie"

    init() {}

    var directCookie: String? { Keychain.load(Self.cookieKey) }

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
        isAuthenticated = directCookie != nil
        isLoading = false
    }

    func logout() {
        Keychain.delete(Self.cookieKey)
        isAuthenticated = false
    }

    /// 115 开放平台接口（云下载、种子），在手机上本地实现
    func client() -> APIClient? { APIClient() }
}
