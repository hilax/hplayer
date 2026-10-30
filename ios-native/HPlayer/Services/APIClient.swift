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
            return "地址无效"
        }
    }
}

/// 115 开放平台的接口：请求直接交给手机上的 Direct115Open 处理，不经过任何服务器。
struct APIClient {
    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await send(path: path, method: "POST", body: data)
    }

    private func send<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        let result = try await Direct115Open.shared.route(path: path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: result)
    }
}
