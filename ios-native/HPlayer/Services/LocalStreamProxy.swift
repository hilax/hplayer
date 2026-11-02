import Darwin
import Foundation
import Network
import UIKit

/// 本机播放中转。
///
/// mpv 自带的 FFmpeg 用 GnuTLS 连 115 的 HTTPS 时，握手会被对方直接断开（日志里是
/// `tls: Error in the pull function` / `IO error: End of file`），原画和转码地址都打不开。
/// 这里在本机回环地址上开一个很小的 HTTP 服务：mpv 只连本机，真正的网络请求交给系统的 URLSession
/// （苹果自己的 TLS，和 App 里调 115 接口用的是同一套），并带上 115 需要的 User-Agent / Referer / Cookie。
/// 支持 Range（跳转、边播边存），m3u8 播放列表里的分片地址也会改成走这里。
final class LocalStreamProxy: NSObject, @unchecked Sendable {
    static let shared = LocalStreamProxy()

    /// 所有状态只在这个串行队列上读写（监听、连接、URLSession 回调都在这里）
    let queue = DispatchQueue(label: "app.hplayer.stream-proxy", qos: .userInitiated)
    /// 端口自检可能等待 socket，不能占用转发队列或主线程。
    private let probeQueue = DispatchQueue(label: "app.hplayer.stream-proxy.probe", qos: .utility)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var checkingListener = false
    private var lastPortCheck: Bool?
    private var listenerWaiters: [UUID: (UInt16?) -> Void] = [:]
    private var portProbe: (UInt16) -> Bool = LocalStreamProxy.accepts
    private var session: URLSession!
    /// 每组请求头一个编号，地址里只带编号，Cookie 不出现在 mpv 的日志里
    private var profiles: [String: [String: String]] = [:]
    private var profileOrder: [String] = []
    private var tasks: [Int: ProxyConnection] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var lastProblem = ""

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // 30 秒一个字节都没有才算超时；整个请求不限时（一部电影要读很久）
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        // 手机锁屏或切到别的 App 再回来，系统可能已经收走了监听端口，但监听对象还显示「就绪」。
        // 回到前台时检查一次，端口连不上就丢掉，下次播放时重建。
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.checkListenerIfNeeded() }
        }
    }

    /// 真的往这个端口连一次。监听对象的状态可能过期（显示就绪，实际端口已被系统收走），以连接结果为准。
    static func accepts(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        // 连 socket 都建不出来（句柄耗尽）时没法检查，按正常处理，别因此反复重建监听
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 300) > 0 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
    }

    // MARK: 对外

    /// 把网络地址换成本机中转地址；中转服务起不来时返回 nil，调用方就直接用原地址
    func localURL(for upstream: URL, headers: [String: String]) async -> URL? {
        let id = UUID()
        let cancellation = ListenerCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.listenerWaiters[id] = { port in
                        guard let port, !cancellation.isCancelled else {
                            continuation.resume(returning: nil)
                            return
                        }
                        self.lastProblem = ""
                        let profile = self.register(headers)
                        continuation.resume(returning: Self.localURL(for: upstream, port: port, profile: profile))
                    }
                    // A previously ready listener can later enter .waiting without a new startup timer.
                    self.queue.asyncAfter(deadline: .now() + 2.5) {
                        self.listenerWaiters.removeValue(forKey: id)?(nil)
                    }
                    self.ensureListener()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { self.listenerWaiters.removeValue(forKey: id)?(nil) }
        }
    }

    private static func localURL(for upstream: URL, port: UInt16, profile: String) -> URL? {
        let encoded = Data(upstream.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // 末尾保留原文件名，FFmpeg 靠扩展名判断格式（.m3u8 / .mp4 / .ts）
        let rawName = upstream.lastPathComponent.isEmpty || upstream.lastPathComponent == "/" ? "stream" : upstream.lastPathComponent
        let name = rawName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "stream"
        return URL(string: "http://127.0.0.1:\(port)/v/\(profile)/\(encoded)/\(name)")
    }

    /// 最近一次上游出错的说明，放进诊断信息
    var problem: String {
        queue.sync { lastProblem }
    }

    /// 诊断信息里的最近一次自检结果；诊断不能在主线程重新等待 socket。
    var statusText: String {
        queue.sync {
            guard listener != nil, port != 0 else { return "未启动" }
            guard let lastPortCheck else { return "端口 \(port)，监听已就绪" }
            return "端口 \(port)，上次自检\(lastPortCheck ? "可连接" : "被拒绝（监听已失效，下次打开会重建）")"
        }
    }

    #if DEBUG
    /// 测试用：把记录的端口改成一个没人监听的值，模拟监听被系统收走但状态还显示就绪
    func simulateStalePortForTesting() {
        queue.sync { port = port == 1 ? 2 : 1; lastPortCheck = false }
    }

    func setPortProbeForTesting(_ probe: @escaping (UInt16) -> Bool) {
        queue.sync { portProbe = probe }
    }

    func listenerWaiterCountForTesting() -> Int {
        queue.sync { listenerWaiters.count }
    }
    #endif

    // MARK: 监听

    /// 所有等待者共用一次监听器启动或端口检查。
    private func ensureListener() {
        guard let listener else { startListener(); return }
        switch listener.state {
        case .ready where port != 0:
            checkListenerIfNeeded()
        case .waiting where port != 0:
            self.listener = nil
            port = 0
            lastPortCheck = nil
            listener.cancel()
            startListener()
        case .failed, .cancelled:
            self.listener = nil
            port = 0
            lastPortCheck = nil
            startListener()
        default:
            // 启动中，等待 stateUpdateHandler 或超时。
            break
        }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let created = try? NWListener(using: parameters, on: .any) else {
            finishListenerWaiters(nil)
            return
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created, self.listener === created else { return }
            switch state {
            case .ready:
                self.port = created.port?.rawValue ?? 0
                self.lastPortCheck = nil
                guard self.port != 0 else {
                    self.listener = nil
                    created.cancel()
                    self.finishListenerWaiters(nil)
                    return
                }
                self.finishListenerWaiters(self.port)
            case .failed, .cancelled:
                self.listener = nil
                self.port = 0
                self.lastPortCheck = nil
                self.finishListenerWaiters(nil)
            default:
                break
            }
        }
        listener = created
        created.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak created] in
            guard let self, let created, self.listener === created, self.port == 0 else { return }
            self.listener = nil
            created.cancel()
            self.finishListenerWaiters(nil)
        }
    }

    private func checkListenerIfNeeded() {
        guard !checkingListener, let checked = listener, port != 0 else { return }
        let checkedPort = port
        let probe = portProbe
        checkingListener = true
        probeQueue.async {
            let alive = probe(checkedPort)
            self.queue.async {
                self.checkingListener = false
                guard self.listener === checked, self.port == checkedPort else {
                    if !self.listenerWaiters.isEmpty { self.ensureListener() }
                    return
                }
                self.lastPortCheck = alive
                if alive {
                    self.finishListenerWaiters(checkedPort)
                } else {
                    self.listener = nil
                    self.port = 0
                    checked.cancel()
                    if !self.listenerWaiters.isEmpty { self.startListener() }
                }
            }
        }
    }

    private func finishListenerWaiters(_ port: UInt16?) {
        let waiters = Array(listenerWaiters.values)
        listenerWaiters.removeAll()
        waiters.forEach { $0(port) }
    }

    private func accept(_ connection: NWConnection) {
        let handler = ProxyConnection(connection: connection, proxy: self)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    fileprivate func closed(_ handler: ProxyConnection) {
        connections.removeValue(forKey: ObjectIdentifier(handler))
    }

    // MARK: 地址

    private func register(_ headers: [String: String]) -> String {
        if let existing = profiles.first(where: { $0.value == headers })?.key { return existing }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        profiles[id] = headers
        profileOrder.append(id)
        if profileOrder.count > 16 {
            profiles.removeValue(forKey: profileOrder.removeFirst())
        }
        return id
    }

    fileprivate func resolve(path: String) -> (url: URL, headers: [String: String], profile: String)? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "v" else { return nil }
        var encoded = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
              let url = URL(string: text) else { return nil }
        return (url, profiles[parts[1]] ?? [:], parts[1])
    }

    /// m3u8 里的一行：分片地址、以及 URI="…"（密钥、字幕、初始化分片）都换成本机中转地址
    fileprivate func rewritePlaylistLine(_ line: String, base: URL, profile: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return line }
        if trimmed.hasPrefix("#") {
            guard trimmed.contains("URI=\"") else { return line }
            var result = ""
            var rest = Substring(trimmed)
            while let start = rest.range(of: "URI=\"") {
                result += rest[..<start.upperBound]
                rest = rest[start.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { break }
                result += proxied(String(rest[..<end]), base: base, profile: profile)
                rest = rest[end...]
            }
            return result + rest
        }
        return proxied(trimmed, base: base, profile: profile)
    }

    private func proxied(_ reference: String, base: URL, profile: String) -> String {
        guard let absolute = URL(string: reference, relativeTo: base)?.absoluteURL,
              let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return reference }
        let encoded = Data(absolute.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let name = absolute.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "segment"
        return "http://127.0.0.1:\(port)/v/\(profile)/\(encoded)/\(name.isEmpty ? "segment" : name)"
    }

    // MARK: 上游请求

    fileprivate func startTask(_ request: URLRequest, for handler: ProxyConnection) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        tasks[task.taskIdentifier] = handler
        task.resume()
        return task
    }

    fileprivate func note(_ text: String) {
        lastProblem = text
    }
}

/// Cancellation can race with registering a continuation on the proxy queue.
private final class ListenerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

extension LocalStreamProxy: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let handler = tasks[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        handler.didReceive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        tasks[dataTask.taskIdentifier]?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        tasks.removeValue(forKey: task.taskIdentifier)?.didComplete(error)
    }
}

/// mpv 发来的一个请求：读请求头，转成 URLSession 请求，再把响应原样写回去。一个连接只服务一个请求。
private final class ProxyConnection {
    /// 写给 mpv 的数据积压超过 8MB 就暂停下载，降到 2MB 再继续，免得内存涨上去
    private static let pauseBytes = 8 * 1_048_576
    private static let resumeBytes = 2 * 1_048_576

    private let connection: NWConnection
    private let proxy: LocalStreamProxy
    private var requestData = Data()
    private var task: URLSessionDataTask?
    private var isHead = false
    private var headersSent = false
    private var isPlaylist = false
    private var playlistStatus = 200
    private var playlistData = Data()
    private var responseURL: URL?
    private var upstreamURL: URL?
    private var profile = ""
    private var pending = 0
    private var suspended = false
    private var closed = false

    init(connection: NWConnection, proxy: LocalStreamProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: proxy.queue)
        receiveRequest()
    }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.requestData.append(data) }
            if let end = self.requestData.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(String(decoding: self.requestData[..<end.lowerBound], as: UTF8.self))
                self.watchForClose()
            } else if isComplete || error != nil || self.requestData.count > 65536 {
                self.close()
            } else {
                self.receiveRequest()
            }
        }
    }

    /// mpv 跳转或关闭视频时会断开连接，这时把对应的下载也停掉
    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self, !self.closed else { return }
            if isComplete || error != nil {
                self.close()
            } else {
                self.watchForClose()
            }
        }
    }

    private func handleRequest(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let target = proxy.resolve(path: String(parts[1])) else {
            respond(status: 404, text: "Not Found")
            return
        }
        isHead = parts[0] == "HEAD"
        upstreamURL = target.url
        profile = target.profile
        var request = URLRequest(url: target.url)
        request.httpMethod = isHead ? "HEAD" : "GET"
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Range") == .orderedSame {
                request.setValue(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
            }
        }
        // 不要压缩：视频的字节位置要和 Range 对得上
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        task = proxy.startTask(request, for: self)
    }

    func didReceive(_ response: URLResponse) {
        guard !closed else { return }
        guard let http = response as? HTTPURLResponse else {
            respond(status: 502, text: "Bad Gateway")
            return
        }
        responseURL = http.url
        if http.statusCode >= 400 {
            proxy.note("上游返回 HTTP \(http.statusCode)：\(http.url?.host ?? "")")
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let path = (http.url?.path ?? upstreamURL?.path ?? "").lowercased()
        if (200..<300).contains(http.statusCode), type.contains("mpegurl") || path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") {
            // 播放列表整份收完，改好地址再发
            isPlaylist = true
            playlistStatus = http.statusCode
            return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(Self.reason(http.statusCode))\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
            if let value = http.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
        }
        head += "Connection: close\r\n\r\n"
        headersSent = true
        write(Data(head.utf8))
    }

    func didReceive(_ data: Data) {
        guard !closed else { return }
        if isPlaylist {
            playlistData.append(data)
        } else if !isHead {
            write(data)
        }
    }

    func didComplete(_ error: Error?) {
        task = nil
        guard !closed else { return }
        if let error {
            proxy.note("上游连接失败：\(error.localizedDescription)（\(upstreamURL?.host ?? "")）")
            // 已经开始传数据了就直接断开，FFmpeg 会带着 Range 自己重新请求
            if headersSent { close() } else { respond(status: 502, text: "Bad Gateway") }
            return
        }
        if isPlaylist {
            sendPlaylist()
        } else {
            finish()
        }
    }

    private func sendPlaylist() {
        let base = responseURL ?? upstreamURL ?? URL(string: "http://127.0.0.1/")!
        let text = String(decoding: playlistData, as: UTF8.self)
        let rewritten = text.components(separatedBy: "\n")
            .map { proxy.rewritePlaylistLine($0, base: base, profile: profile) }
            .joined(separator: "\n")
        let body = Data(rewritten.utf8)
        let head = "HTTP/1.1 \(playlistStatus) \(Self.reason(playlistStatus))\r\n"
            + "Content-Type: application/vnd.apple.mpegurl\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        headersSent = true
        write(Data(head.utf8))
        if !isHead { write(body) }
        finish()
    }

    private func respond(status: Int, text: String) {
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        headersSent = true
        write(Data(head.utf8))
        if !isHead { write(body) }
        finish()
    }

    private func write(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        pending += data.count
        let count = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pending -= count
            if error != nil {
                self.close()
                return
            }
            if self.suspended, self.pending < Self.resumeBytes {
                self.suspended = false
                self.task?.resume()
            }
        })
        if !suspended, pending > Self.pauseBytes, let task {
            suspended = true
            task.suspend()
        }
    }

    private func finish() {
        guard !closed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        connection.cancel()
        proxy.closed(self)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301, 302, 303, 307, 308: return "Redirect"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        default: return "Status"
        }
    }
}
