import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case badURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .server(let message):
            return message
        case .badURL:
            return "服务器地址无效"
        }
    }
}

struct APIClient {
    let baseURL: URL
    let token: String?

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await send(path: path, method: "POST", body: data)
    }

    private func send<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = path == "/api/115/torrent/upload" ? 180 : (path == "/api/115/status" ? 15 : 45)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server("无效的服务器响应")
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw APIError.server(message ?? "请求失败（\(http.statusCode)）")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
