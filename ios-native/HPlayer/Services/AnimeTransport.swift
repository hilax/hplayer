import Foundation

/// 本次会话里记住每个域名当前可用的节点，并保证同一域名同时只进行一次选路。
///
/// 背景：`*.cenmo.fun` 走腾讯 EdgeOne，DNS 返回多个节点，其中可能有的在当前网络下不通。
/// 系统按 DNS 顺序连第一个，要等约 7.5 秒 SYN 超时才切下一个；首页首屏并发六个请求时会一起卡住。
///
/// 选路按域名做一次：并发的请求共用同一个选路任务，而不是各自竞速——否则
/// 六个请求 × 五个节点会瞬间打出三十条连接，反而被服务端限流返回 502。
actor AnimeEndpointCache {
    static let shared = AnimeEndpointCache()

    private var locked: [String: String] = [:]
    private var pending: [String: Task<String, Error>] = [:]

    func target(for host: String) -> String? { locked[host] }
    func lock(_ target: String, for host: String) { locked[host] = target }

    func invalidate(_ host: String) {
        locked.removeValue(forKey: host)
        pending.removeValue(forKey: host)
    }

    /// 已锁定就直接返回；正在选路就等同一个任务；否则发起一次选路。
    func electedTarget(for host: String,
                       race: @escaping @Sendable () async throws -> String) async throws -> String {
        if let locked = locked[host] { return locked }
        if let task = pending[host] { return try await task.value }

        let task = Task<String, Error> { try await race() }
        pending[host] = task
        do {
            let winner = try await task.value
            locked[host] = winner
            pending[host] = nil
            return winner
        } catch {
            pending[host] = nil
            throw error
        }
    }
}

struct AnimeHTTPResult {
    let data: Data
    let status: Int
    let location: String?
}

enum AnimeTransportError: LocalizedError {
    case invalidURL
    case allNodesFailed(String)
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请求地址无效"
        case .allNodesFailed(let host): return "\(host) 的所有节点都连不上"
        case .badStatus(let code): return "服务器返回异常状态（\(code)）"
        }
    }
}

/// 动漫接口的共享传输层：一次选路 + 可用节点锁定。
///
/// 选路用 Happy Eyeballs 思路：先按域名试；`raceDelay` 内没回来就错峰并行直连备用 IP
/// （带 Host 头），谁先成功用谁并取消其余。网络正常时域名几十毫秒就返回，
/// 备用任务还在 sleep 就被取消，不产生额外请求。
struct AnimeTransport {
    let host: String
    let fallbackIPs: [String]
    var raceDelay: UInt64 = 1_200_000_000
    var stagger: UInt64 = 300_000_000
    var timeout: TimeInterval = 12

    private static func makeSession(direct: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        if direct {
            // 直连 IP 必须绕开系统代理：代理会自己解析和路由，
            // 「IP + Host 头」这种请求会被改写，实测直接返回 502，节点锁定也就失去意义。
            config.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: config)
    }

    /// 域名请求走系统代理（照顾必须靠代理才能访问的网络）；直连 IP 的请求绕开代理。
    /// 各自复用连接，锁定节点后后续请求走同一条 TCP。
    private static let proxiedSession = makeSession(direct: false)
    private static let directSession = makeSession(direct: true)

    func send(path: String, method: String = "GET",
              headers: [String: String], body: Data? = nil) async throws -> AnimeHTTPResult {
        // 快路径：本次会话已经验证过的节点
        if let target = await AnimeEndpointCache.shared.target(for: host) {
            do {
                return try await attempt(target: target, path: path, method: method,
                                         headers: headers, body: body)
            } catch {
                // 锁定的节点失效（换网络、节点下线），解锁后重新选路
                await AnimeEndpointCache.shared.invalidate(host)
            }
        }

        let target = try await AnimeEndpointCache.shared.electedTarget(for: host) {
            try await self.elect(path: path, method: method, headers: headers, body: body)
        }
        return try await attempt(target: target, path: path, method: method, headers: headers, body: body)
    }

    /// 竞速探一次，只返回胜出的节点；响应数据丢弃，调用方随后用锁定节点重发（此时已是快路径）。
    private func elect(path: String, method: String,
                       headers: [String: String], body: Data?) async throws -> String {
        let candidates = [host] + fallbackIPs
        var lastError: Error = AnimeTransportError.allNodesFailed(host)

        return try await withThrowingTaskGroup(of: String.self) { group in
            for (index, target) in candidates.enumerated() {
                group.addTask {
                    if index > 0 {
                        try await Task.sleep(nanoseconds: raceDelay + UInt64(index - 1) * stagger)
                    }
                    _ = try await attempt(target: target, path: path, method: method,
                                          headers: headers, body: body)
                    return target
                }
            }

            var remaining = candidates.count
            while remaining > 0 {
                do {
                    guard let winner = try await group.next() else { break }
                    group.cancelAll()
                    return winner
                } catch {
                    if error is CancellationError { throw error }
                    lastError = error
                    remaining -= 1
                }
            }
            throw lastError
        }
    }

    private func attempt(target: String, path: String, method: String,
                         headers: [String: String], body: Data?) async throws -> AnimeHTTPResult {
        guard let url = URL(string: "http://\(target)\(path)") else {
            throw AnimeTransportError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // 直连 IP 时必须带原始域名，否则 EdgeOne 返回 418
        request.setValue(host, forHTTPHeaderField: "Host")

        let session = (target == host) ? Self.proxiedSession : Self.directSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnimeTransportError.badStatus(-1)
        }
        guard (200..<400).contains(http.statusCode) else {
            throw AnimeTransportError.badStatus(http.statusCode)
        }
        return AnimeHTTPResult(data: data, status: http.statusCode,
                               location: http.value(forHTTPHeaderField: "Location"))
    }
}
