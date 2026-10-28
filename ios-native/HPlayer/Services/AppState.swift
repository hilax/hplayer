import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var serverURLString: String
    @Published var isAuthenticated = false
    @Published var isLoading = true

    private var token: String?

    private static let serverKey = "hplayer.serverURL"
    private static let tokenKey = "hplayer.token"

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
        token = Keychain.load(Self.tokenKey)
    }

    var serverURL: URL? {
        URL(string: serverURLString)
    }

    var hasServer: Bool {
        !serverURLString.isEmpty && serverURL != nil
    }

    func setServer(_ value: String) {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        serverURLString = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.serverKey)
    }

    func checkAuth() async {
        guard let serverURL else {
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
        token = nil
        Keychain.delete(Self.tokenKey)
        isAuthenticated = false
    }

    func client() -> APIClient? {
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
