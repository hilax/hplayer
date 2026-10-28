import Foundation

@MainActor
final class AppState: ObservableObject {
    enum ConnectionMode: String { case device, server }
    @Published var serverURLString: String
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published private(set) var mode: ConnectionMode

    private var token: String?

    private static let serverKey = "hplayer.serverURL"
    private static let tokenKey = "hplayer.token"
    private static let modeKey = "hplayer.mode"
    private static let cookieKey = "hplayer.115.cookie"

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
        token = Keychain.load(Self.tokenKey)
        mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .device
    }

    var serverURL: URL? {
        guard let url = URL(string: serverURLString),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    var hasServer: Bool {
        !serverURLString.isEmpty && serverURL != nil
    }

    var isDirect: Bool { mode == .device }
    var directCookie: String? { Keychain.load(Self.cookieKey) }

    func setMode(_ newMode: ConnectionMode) {
        guard mode != newMode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        isAuthenticated = newMode == .device && directCookie != nil
    }

    func connectDirect(cookie: String) async throws {
        _ = try await Direct115Client(cookie: cookie).user()
        Keychain.save(cookie, for: Self.cookieKey)
        isAuthenticated = true
    }

    func directClient() -> Direct115Client? {
        guard isDirect, let cookie = directCookie, !cookie.isEmpty else { return nil }
        return Direct115Client(cookie: cookie)
    }

    func setServer(_ value: String) {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed != serverURLString {
            token = nil
            Keychain.delete(Self.tokenKey)
            isAuthenticated = false
        }
        serverURLString = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.serverKey)
    }

    func checkAuth() async {
        if isDirect {
            isAuthenticated = directCookie != nil
            isLoading = false
            return
        }
        guard let serverURL else {
            isAuthenticated = false
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let client = APIClient(baseURL: serverURL, token: token)
            let me: MeResponse = try await client.get("/api/me")
            isAuthenticated = me.authenticated
        } catch {
            isAuthenticated = false
        }
    }

    func login(password: String) async throws {
        guard let serverURL else { throw APIError.badURL }
        let client = APIClient(baseURL: serverURL, token: nil)
        let result: LoginResponse = try await client.post("/api/login", body: ["password": password])
        token = result.token
        Keychain.save(result.token, for: Self.tokenKey)
        isAuthenticated = true
    }

    func logout() {
        if isDirect {
            Keychain.delete(Self.cookieKey)
            isAuthenticated = false
            return
        }
        token = nil
        Keychain.delete(Self.tokenKey)
        isAuthenticated = false
    }

    func client() -> APIClient? {
        if isDirect { return APIClient(baseURL: URL(string: "https://115.com/")!, token: nil, direct: true) }
        guard let serverURL else { return nil }
        return APIClient(baseURL: serverURL, token: token)
    }

    /// 播放地址需要把 token 拼进 query —— AVPlayer 带不了自定义 header
    func mediaURL(_ path: String) -> URL? {
        guard let serverURL, let url = URL(string: path, relativeTo: serverURL) else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        if let token {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
        }
        return components.url
    }
}
