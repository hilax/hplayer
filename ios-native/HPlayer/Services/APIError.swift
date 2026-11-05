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
