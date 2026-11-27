import Foundation

/// 测试用的假网络：每个测试装一个路由函数，按请求地址决定返回什么，并记下所有请求。
final class RoutedURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
        var error: Error? = nil

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        static func fail(_ error: Error, delay: TimeInterval = 0) -> Reply {
            Reply(delay: delay, error: error)
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

    /// URLSession 会把 POST 的 httpBody 换成数据流交给协议；这里先读出来放回 httpBody，路由函数和测试断言都能直接看到表单内容。
    private static func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }

    /// 把表单请求的内容拆成键值对
    static func form(of request: URLRequest) -> [String: String] {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            result[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? "") : ""
        }
        return result
    }

    private let instanceLock = NSLock()
    private var isCancelled = false
    private var pendingWork: DispatchWorkItem?

    override func startLoading() {
        let request = Self.materialized(self.request)
        Self.lock.lock()
        Self.recorded.append(request)
        let route = Self.route
        Self.lock.unlock()
        let reply = route(request)
        if reply.delay <= 0 {
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.instanceLock.lock()
            let stopped = self.isCancelled
            self.pendingWork = nil
            self.instanceLock.unlock()
            guard !stopped else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        instanceLock.lock()
        if isCancelled {
            instanceLock.unlock()
            return
        }
        pendingWork = work
        instanceLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
    }

    override func stopLoading() {
        instanceLock.lock()
        isCancelled = true
        let work = pendingWork
        pendingWork = nil
        instanceLock.unlock()
        work?.cancel()
    }
}
