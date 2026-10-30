import Foundation

/// 测试用的假网络：每个测试装一个路由函数，按请求地址决定返回什么，并记下所有请求。
final class RoutedURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    private static let lock = NSLock()
    private static var route: (URLRequest) -> Reply = { _ in Reply(status: 404) }
    private static var recorded: [URLRequest] = []

    /// 换上新的路由并清空记录。
    static func install(_ route: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.route = route
        recorded = []
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let route = Self.route
        Self.lock.unlock()
        let reply = route(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
