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
    /// 每组请求头与流标识一个编号，地址里只带编号，Cookie 不出现在 mpv 的日志里
    private var profiles: [String: StreamProfile] = [:]
    private var profileOrder: [String] = []
    private var streamGenerations: [String: Int] = [:]
    private var tasks: [Int: ProxyConnection] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var serialCounter = 0
    private var lastProblem = ""
    /// 最近几次上游出错的记录（带时间）。自动重试好几次之后，最初的出错原因不会被后面的覆盖掉。
    private var problemHistory: [String] = []
    /// 上游连不上、或下载到一半断了时，每次重试前等多久；用完了才把错误交给 mpv。
    /// 115 的服务器偶尔会掐掉连接再拒绝紧接着的新连接，隔一小会儿就恢复了。
    fileprivate var retryDelays: [TimeInterval] = [0.3, 0.8, 1.6, 3.0]
    /// 新换的地址也被 115 拒绝（同一个文件的下载连接太多、请求太密）时，等这么久再试
    fileprivate var refusalDelays: [TimeInterval] = [0.6, 1.5, 3.0]
    /// 115 大文件分段拉取大小（4 MiB），避免单条长连接被限速或中途掐断。
    fileprivate var chunkSize: Int64 = 4 * 1_048_576
    /// 单次上游请求停滞（0 字节）超时时间；比 URLSession 默认 30s 更早触发重连或换节点。
    fileprivate var stallTimeout: TimeInterval = 6.0
    /// 停滞检测最低有效速率门槛（8 KB/s）；低于该速率持续数秒则判定节点卡死。
    fileprivate var minHealthySpeed: Double = 8 * 1024
    /// 115 的下载地址有时效，过期（或被 115 收回）后上游回 403。登记了换地址办法的视频，
    /// 中转自己去换新地址、从原来的字节位置接着下，mpv 那边不会断，也不用整个重开。
    /// 键优先使用调用方指定的 streamID（同一个 pickCode 换地址后仍共用），否则回退到原始 URL。
    private var renewals: [String: UpstreamRenewal] = [:]
    private var renewalOrder: [String] = []
    private var playlistEntries: [String: PlaylistEntry] = [:]
    fileprivate let blockCache = StreamBlockCache()
    private static let historyClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // 测试里换成假的上游
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
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
    func localURL(
        for upstream: URL,
        headers: [String: String],
        streamID: String? = nil,
        renew: (() async throws -> URL)? = nil,
        playlistRenew: (() async throws -> URL)? = nil
    ) async -> URL? {
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
                        let generation = streamID.map { self.advanceGeneration(for: $0) } ?? 0
                        let profile = self.register(headers, streamID: streamID, generation: generation)
                        let key = self.renewalKey(streamID: streamID, upstream: upstream)
                        if let renew { self.registerRenewal(forKey: key, renew) }
                        if let playlistFetch = playlistRenew ?? (Self.looksLikePlaylistURL(upstream) ? renew : nil) {
                            self.registerPlaylistEntry(forKey: key, rootURL: upstream, headers: headers, fetchRoot: playlistFetch)
                        }
                        if streamID != nil {
                            self.preemptOlderConnections(forKey: key, activeGeneration: generation)
                        }
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

    /// 让当前本机代理地址对应的一条活跃连接立刻中断卡死请求，按需刷新 115 地址并从断点接着续传；
    /// mpv 侧响应流保持不断开（第一层静默恢复）。没有可刷新连接时返回 false。
    @discardableResult
    func refreshActiveUpstream(for localURL: URL) -> Bool {
        queue.sync {
            guard let target = resolve(path: localURL.path) else { return false }
            let key = target.streamID ?? target.url.absoluteString
            let candidates = connections.values
                .filter { $0.matchesStreamKey(key) && $0.canRefreshUpstream }
                .sorted { $0.serial > $1.serial }
            guard let active = candidates.first else { return false }
            return active.forceRefreshUpstream()
        }
    }

    /// 这个本机地址现在实际连的上游地址（换过新地址就是新的）。线路测速用它测「正在播放」的那条。
    func activeUpstream(for localURL: URL) -> URL? {
        queue.sync {
            guard let target = resolve(path: localURL.path) else { return nil }
            let key = renewalKey(streamID: target.streamID, upstream: target.url)
            return renewals[key]?.current ?? target.url
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

    /// 最近几次上游出错的完整记录（时间、错误码、已转发多少字节、第几次重试），放进诊断信息
    var problemHistoryLines: [String] {
        queue.sync { problemHistory }
    }

    /// 把系统的网络错误写成一行：说明、错误码，以及底层的系统错误号。
    /// 排查「连不上 115」到底是被拒绝、不可达还是超时，要看后面这几个数字。
    static func summary(of error: Error) -> String {
        let nsError = error as NSError
        var text = "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "，底层 \(underlying.domain) \(underlying.code)"
        }
        if let domain = nsError.userInfo["_kCFStreamErrorDomainKey"] as? Int,
           let code = nsError.userInfo["_kCFStreamErrorCodeKey"] as? Int {
            text += "，流错误 \(domain)/\(code)"
        }
        return text + "）"
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

    func setRetryDelaysForTesting(_ delays: [TimeInterval]) {
        queue.sync { retryDelays = delays }
    }

    func setRefusalDelaysForTesting(_ delays: [TimeInterval]) {
        queue.sync { refusalDelays = delays }
    }

    func setChunkSizeForTesting(_ bytes: Int64) {
        queue.sync { chunkSize = bytes }
    }

    func setStallTimeoutForTesting(_ seconds: TimeInterval, minSpeed: Double = 0) {
        queue.sync {
            stallTimeout = seconds
            minHealthySpeed = minSpeed
        }
    }

    func cachedByteCountForTesting() -> Int {
        queue.sync { blockCache.totalBytes }
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
        guard let key = handler.streamKey else { return }
        let activeGen = currentGeneration(forKey: key)
        // 先关闭已经属于旧播放会话或连接已断开的挂起请求，绝不唤醒僵尸连接抢占 115 并发数
        let same = connections.values.filter { $0.streamKey == key }
        for conn in same where conn.isYielding && (!conn.isClientAlive || (conn.hasExplicitStreamID && conn.profileGeneration != activeGen)) {
            conn.forceClosePreempted()
        }
        let aliveSame = connections.values.filter { $0.streamKey == key }
        // 让出过连接的那条（FFmpeg 跳转失败时会退回去接着读旧连接）：同一个视频没有别的下载了，就让它接着下
        guard !aliveSame.contains(where: { $0.holdsUpstream }),
              let waiting = aliveSame.filter({ $0.isYielding && $0.isClientAlive }).max(by: { $0.serial < $1.serial }) else { return }
        waiting.resumeAfterYield()
    }

    /// 115 同一个文件同时只认一两条下载连接，多了新连接会被 403 拒绝。mpv 跳转时 FFmpeg 先开新连接、
    /// 成功了才关旧的，旧连接的下载还挂着，新连接就被拒。所以同一个视频开新下载前，先把别的连接的下载停掉
    /// （记住下到哪了）；它们之后要么被 mpv 关掉，要么等别的下载都结束了再从原位置接着下。
    fileprivate func claimUpstream(for handler: ProxyConnection) {
        guard let key = handler.streamKey else { return }
        for other in connections.values where other !== handler && other.streamKey == key {
            if handler.hasExplicitStreamID && other.profileGeneration < handler.profileGeneration {
                other.forceClosePreempted()
            } else {
                other.yieldUpstream()
            }
        }
    }

    fileprivate func nextSerial() -> Int {
        serialCounter += 1
        return serialCounter
    }

    // MARK: 地址

    fileprivate func renewalKey(streamID: String?, upstream: URL) -> String {
        streamID ?? upstream.absoluteString
    }

    fileprivate static func looksLikePlaylistURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    private func advanceGeneration(for streamID: String) -> Int {
        let next = (streamGenerations[streamID] ?? 0) + 1
        streamGenerations[streamID] = next
        return next
    }

    private func currentGeneration(forKey key: String) -> Int {
        streamGenerations[key] ?? 0
    }

    private func preemptOlderConnections(forKey key: String, activeGeneration: Int) {
        for other in Array(connections.values) where other.matchesStreamKey(key) && other.profileGeneration < activeGeneration {
            other.forceClosePreempted()
        }
    }

    private func register(_ headers: [String: String], streamID: String?, generation: Int) -> String {
        if streamID == nil,
           let existing = profiles.first(where: { $0.value.streamID == nil && $0.value.headers == headers })?.key {
            return existing
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        profiles[id] = StreamProfile(headers: headers, streamID: streamID, generation: generation)
        profileOrder.append(id)
        if profileOrder.count > 32 {
            profiles.removeValue(forKey: profileOrder.removeFirst())
        }
        return id
    }

    private func registerRenewal(forKey key: String, _ renew: @escaping () async throws -> URL) {
        renewals[key] = UpstreamRenewal(renew)
        renewalOrder.removeAll { $0 == key }
        renewalOrder.append(key)
        if renewalOrder.count > 16 {
            let evicted = renewalOrder.removeFirst()
            renewals.removeValue(forKey: evicted)
            playlistEntries.removeValue(forKey: evicted)
        }
    }

    private func registerPlaylistEntry(forKey key: String, rootURL: URL, headers: [String: String], fetchRoot: @escaping () async throws -> URL) {
        playlistEntries[key] = PlaylistEntry(rootURL: rootURL, headers: headers, fetchRoot: fetchRoot)
    }

    fileprivate func ensurePlaylistEntry(forKey key: String, rootURL: URL, headers: [String: String]) {
        guard playlistEntries[key] == nil, let renewal = renewals[key] else { return }
        playlistEntries[key] = PlaylistEntry(rootURL: rootURL, headers: headers, fetchRoot: renewal.fetch)
    }

    fileprivate func isPlaylistChild(url: URL, forKey key: String) -> Bool {
        guard let entry = playlistEntries[key] else { return false }
        if url == entry.rootURL || Self.looksLikePlaylistURL(url) { return false }
        return entry.originalByChildURL[url.absoluteString] != nil || !entry.latestByOriginalURL.isEmpty
    }

    /// 原始地址现在该用哪个地址去连（换过新地址就用新的）
    fileprivate func currentUpstream(forKey key: String, fallback: URL) -> URL {
        if let entry = playlistEntries[key],
           fallback != entry.rootURL,
           let mapped = entry.latestByOriginalURL[fallback.absoluteString] {
            return mapped
        }
        return renewals[key]?.current ?? fallback
    }

    fileprivate func canRenew(forKey key: String) -> Bool {
        renewals[key] != nil || playlistEntries[key] != nil
    }

    /// 地址 `failed` 被拒绝了，值不值得换新地址：正在换、或者别的连接已经换好了 → 值得（直接用）；
    /// 拒绝的就是几秒前刚换来的地址 → 不是过期的问题（多半是连接太多），换了也没用，等一会儿再试。
    fileprivate func needsNewAddress(forKey key: String, failed: URL, ignoreCooldown: Bool = false) -> Bool {
        guard let renewal = renewals[key] else { return false }
        if renewal.refreshing { return true }
        if let current = renewal.current, current != failed { return true }
        if !ignoreCooldown, let last = renewal.renewedAt, renewal.current == failed, Date().timeIntervalSince(last) < 20 { return false }
        if ignoreCooldown, let last = renewal.renewedAt, Date().timeIntervalSince(last) < 5 { return false }
        return true
    }

    fileprivate func needsNewPlaylistAddress(forKey key: String, originalSegment: URL, failed: URL) -> Bool {
        guard let entry = playlistEntries[key] else { return false }
        if entry.refreshing { return true }
        if let current = entry.latestByOriginalURL[originalSegment.absoluteString], current != failed { return true }
        if let last = entry.renewedAt, Date().timeIntervalSince(last) < 15 { return false }
        return true
    }

    /// 地址 `failed` 被上游拒绝了：换一个新地址。好几条连接同时被拒时只换一次，大家共用结果；
    /// 别的连接已经换好了就直接用。换不到回调 nil。
    fileprivate func renew(forKey key: String, failed: URL, completion: @escaping (URL?) -> Void) {
        guard let renewal = renewals[key] else {
            completion(nil)
            return
        }
        if let current = renewal.current, current != failed {
            completion(current)
            return
        }
        renewal.waiters.append(completion)
        guard !renewal.refreshing else { return }
        renewal.refreshing = true
        let fetch = renewal.fetch
        Task {
            var fresh: URL?
            var failure = ""
            do { fresh = try await fetch() } catch { failure = LocalStreamProxy.summary(of: error) }
            self.queue.async {
                renewal.refreshing = false
                if let fresh {
                    renewal.current = fresh
                    renewal.renewedAt = Date()
                    self.note("已换新地址（\(fresh.host ?? "")）")
                } else {
                    self.note("换新地址失败：\(failure)")
                }
                let waiters = renewal.waiters
                renewal.waiters = []
                waiters.forEach { $0(fresh) }
            }
        }
    }

    /// m3u8 分片（.ts / init / key）403 过期时：重新拉取最新的 m3u8 播放列表并定位到同一个分片的新签名地址。
    fileprivate func renewPlaylistSegment(forKey key: String, originalSegment: URL, failed: URL, completion: @escaping (URL?) -> Void) {
        guard let entry = playlistEntries[key] else {
            completion(nil)
            return
        }
        if let latest = entry.latestByOriginalURL[originalSegment.absoluteString], latest != failed {
            completion(latest)
            return
        }
        entry.waiters.append { ok in
            completion(ok ? entry.resolveUpdatedSegment(forOriginal: originalSegment, avoiding: failed) : nil)
        }
        guard !entry.refreshing else { return }
        entry.refreshing = true
        let fetchRoot = entry.fetchRoot
        let headers = entry.headers
        let session = self.session!
        Task {
            var updatedSegments: [URL] = []
            var playlistBase: URL?
            var failure = ""
            do {
                let freshPlaylistURL = try await fetchRoot()
                playlistBase = freshPlaylistURL
                var req = URLRequest(url: freshPlaylistURL)
                for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
                req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let finalBase = (response as? HTTPURLResponse)?.url ?? freshPlaylistURL
                playlistBase = finalBase
                let text = String(decoding: data, as: UTF8.self)
                updatedSegments = LocalStreamProxy.extractPlaylistSegmentURLs(from: text, base: finalBase)
            } catch {
                failure = LocalStreamProxy.summary(of: error)
            }
            self.queue.async {
                entry.refreshing = false
                let success = !updatedSegments.isEmpty
                if success {
                    entry.renewedAt = Date()
                    if let renewal = self.renewals[key], let playlistBase {
                        renewal.current = playlistBase
                        renewal.renewedAt = Date()
                    }
                    entry.applyRefreshedSegments(updatedSegments)
                    self.note("已刷新 m3u8 分片地址（共 \(updatedSegments.count) 段）")
                } else {
                    self.note("刷新 m3u8 分片失败：\(failure.isEmpty ? "空列表" : failure)")
                }
                let waiters = entry.waiters
                entry.waiters = []
                waiters.forEach { $0(success) }
            }
        }
    }

    fileprivate func resolve(path: String) -> (url: URL, headers: [String: String], profile: String, streamID: String?, generation: Int)? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "v" else { return nil }
        var encoded = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
              let url = URL(string: text) else { return nil }
        let profile = profiles[parts[1]]
        return (url, profile?.headers ?? [:], parts[1], profile?.streamID, profile?.generation ?? 0)
    }

    /// m3u8 里的一行：分片地址、以及 URI="…"（密钥、字幕、初始化分片）都换成本机中转地址
    fileprivate func rewritePlaylist(_ text: String, base: URL, profile: String, streamKey: String?) -> String {
        var index = 0
        var recorded: [URL] = []
        let lines = text.components(separatedBy: "\n").map { line -> String in
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
                    let ref = String(rest[..<end])
                    if let abs = URL(string: ref, relativeTo: base)?.absoluteURL,
                       let scheme = abs.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        recorded.append(abs)
                        index += 1
                    }
                    result += proxied(ref, base: base, profile: profile)
                    rest = rest[end...]
                }
                return result + rest
            }
            if let abs = URL(string: trimmed, relativeTo: base)?.absoluteURL,
               let scheme = abs.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                recorded.append(abs)
                index += 1
            }
            return proxied(trimmed, base: base, profile: profile)
        }
        if let streamKey, !recorded.isEmpty, let entry = playlistEntries[streamKey] {
            entry.recordInitialSegments(recorded)
        }
        return lines.joined(separator: "\n")
    }

    private static func extractPlaylistSegmentURLs(from text: String, base: URL) -> [URL] {
        var urls: [URL] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                var rest = Substring(trimmed)
                while let start = rest.range(of: "URI=\"") {
                    rest = rest[start.upperBound...]
                    guard let end = rest.firstIndex(of: "\"") else { break }
                    let ref = String(rest[..<end])
                    if let abs = URL(string: ref, relativeTo: base)?.absoluteURL,
                       let scheme = abs.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        urls.append(abs)
                    }
                    rest = rest[end...]
                }
            } else if let abs = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                      let scheme = abs.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                urls.append(abs)
            }
        }
        return urls
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
        problemHistory.append("\(Self.historyClock.string(from: Date())) \(text)")
        if problemHistory.count > 12 { problemHistory.removeFirst(problemHistory.count - 12) }
    }

    /// 这个下载任务要重试了：它之后的回调（包括被取消的通知）都直接丢掉，不要再找到原来的连接
    fileprivate func detach(_ task: URLSessionDataTask) {
        tasks.removeValue(forKey: task.taskIdentifier)
    }
}

private struct StreamProfile {
    let headers: [String: String]
    let streamID: String?
    let generation: Int
}

/// 一个视频的换地址办法和换来的最新地址（只在中转队列上读写）
private final class UpstreamRenewal: @unchecked Sendable {
    let fetch: () async throws -> URL
    var current: URL?
    var renewedAt: Date?
    var refreshing = false
    var waiters: [(URL?) -> Void] = []

    init(_ fetch: @escaping () async throws -> URL) {
        self.fetch = fetch
    }
}

/// m3u8 播放列表的分片索引映射（只在中转队列上读写）
private final class PlaylistEntry: @unchecked Sendable {
    let rootURL: URL
    let headers: [String: String]
    let fetchRoot: () async throws -> URL
    var renewedAt: Date?
    var refreshing = false
    var waiters: [(Bool) -> Void] = []
    var originalByChildURL: [String: (index: Int, lastPath: String)] = [:]
    var latestByOriginalURL: [String: URL] = [:]
    var latestByIndex: [Int: URL] = [:]
    var latestByLastPath: [String: URL] = [:]

    init(rootURL: URL, headers: [String: String], fetchRoot: @escaping () async throws -> URL) {
        self.rootURL = rootURL
        self.headers = headers
        self.fetchRoot = fetchRoot
    }

    func recordInitialSegments(_ segments: [URL]) {
        for (idx, url) in segments.enumerated() {
            let key = url.absoluteString
            if originalByChildURL[key] == nil {
                originalByChildURL[key] = (idx, url.lastPathComponent)
            }
            latestByIndex[idx] = url
            latestByLastPath[url.lastPathComponent] = url
        }
    }

    func applyRefreshedSegments(_ segments: [URL]) {
        for (idx, url) in segments.enumerated() {
            latestByIndex[idx] = url
            latestByLastPath[url.lastPathComponent] = url
        }
        for (origString, meta) in originalByChildURL {
            if meta.index < segments.count {
                latestByOriginalURL[origString] = segments[meta.index]
            } else if let byName = latestByLastPath[meta.lastPath] {
                latestByOriginalURL[origString] = byName
            }
        }
    }

    func resolveUpdatedSegment(forOriginal original: URL, avoiding failed: URL) -> URL? {
        if let mapped = latestByOriginalURL[original.absoluteString], mapped != failed {
            return mapped
        }
        if let meta = originalByChildURL[original.absoluteString] {
            if let byIdx = latestByIndex[meta.index], byIdx != failed {
                latestByOriginalURL[original.absoluteString] = byIdx
                return byIdx
            }
            if let byName = latestByLastPath[meta.lastPath], byName != failed {
                latestByOriginalURL[original.absoluteString] = byName
                return byName
            }
        }
        if let byName = latestByLastPath[original.lastPathComponent], byName != failed {
            latestByOriginalURL[original.absoluteString] = byName
            return byName
        }
        return nil
    }
}

/// 视频头尾和热点字节块内存 LRU 缓存（40 MiB 上限，只在中转串行队列上访问）
private final class StreamBlockCache {
    struct Metadata {
        let totalSize: Int64
        let supportsRanges: Bool
        let contentType: String?
        let etag: String?
        let lastModified: String?
        let acceptRanges: String?
    }

    struct Hit {
        let meta: Metadata
        let data: Data
        let resolvedEnd: Int64
        var isComplete: Bool { false } // Helper unused; callers compare count vs (resolvedEnd - start + 1)
    }

    private struct Block {
        let start: Int64
        var data: Data
        var lastUsed: UInt64
        var pinned: Bool
        var end: Int64 { start + Int64(data.count) - 1 }
    }

    private struct Entry {
        var meta: Metadata
        var blocks: [Block] = []
    }

    private static let headPinBytes: Int64 = 2 * 1_048_576
    private static let tailPinBytes: Int64 = 2 * 1_048_576
    private static let maxSingleBlockBytes = 2 * 1_048_576
    private let maxTotalBytes = 40 * 1_048_576
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var totalBytes = 0

    func record(key: String, meta: Metadata, offset: Int64, data: Data) {
        guard meta.totalSize > 0, offset >= 0, !data.isEmpty else { return }
        if var existing = entries[key] {
            let sameTotal = existing.meta.totalSize == meta.totalSize
            let sameETag = existing.meta.etag == nil || meta.etag == nil || existing.meta.etag == meta.etag
            if !sameTotal || !sameETag {
                removeEntry(key: key)
                existing = Entry(meta: meta, blocks: [])
            } else {
                existing.meta = meta
            }
            entries[key] = existing
        } else {
            entries[key] = Entry(meta: meta, blocks: [])
        }

        // 按不超过 2 MiB 的块切分写入，方便局部淘汰
        var cursor = 0
        while cursor < data.count {
            let endCursor = min(data.count, cursor + Self.maxSingleBlockBytes)
            let slice = Data(data[cursor..<endCursor])
            let sliceStart = offset + Int64(cursor)
            insertSlice(key: key, totalSize: meta.totalSize, start: sliceStart, slice: slice)
            cursor = endCursor
        }
        evictIfNeeded()
    }

    func lookup(key: String, start: Int64, requestedEnd: Int64?) -> (meta: Metadata, data: Data, resolvedEnd: Int64)? {
        guard var entry = entries[key], entry.meta.supportsRanges, entry.meta.totalSize > 0 else { return nil }
        let resolvedEnd = min(requestedEnd ?? (entry.meta.totalSize - 1), entry.meta.totalSize - 1)
        guard start >= 0, start <= resolvedEnd else { return nil }

        var output = Data()
        var needOffset = start
        clock += 1
        for i in 0..<entry.blocks.count {
            let block = entry.blocks[i]
            if block.end < needOffset { continue }
            if block.start > needOffset { break }
            let takeStart = Int(needOffset - block.start)
            let takeLimit = min(block.data.count, takeStart + Int(resolvedEnd - needOffset + 1))
            guard takeLimit > takeStart else { break }
            let piece = block.data[takeStart..<takeLimit]
            output.append(piece)
            entry.blocks[i].lastUsed = clock
            needOffset += Int64(piece.count)
            if output.count >= 4 * 1_048_576 || needOffset > resolvedEnd { break }
        }
        entries[key] = entry
        guard !output.isEmpty else { return nil }
        return (entry.meta, output, resolvedEnd)
    }

    private func insertSlice(key: String, totalSize: Int64, start: Int64, slice: Data) {
        guard var entry = entries[key] else { return }
        let end = start + Int64(slice.count) - 1
        let tailFloor = max(0, totalSize - Self.tailPinBytes)
        let pinned = start < Self.headPinBytes || end >= tailFloor
        clock += 1

        // 丢弃完全被覆盖的旧块或与新块区间重叠的旧块（简单清晰，不留碎片）
        var removedBytes = 0
        entry.blocks.removeAll { block in
            let overlaps = !(block.end < start || block.start > end)
            if overlaps { removedBytes += block.data.count }
            return overlaps
        }
        totalBytes -= removedBytes

        // 尽量与相邻且未超限的前一个同类型块合并，减少数组碎片
        if let prevIdx = entry.blocks.lastIndex(where: { $0.end + 1 == start && $0.data.count + slice.count <= Self.maxSingleBlockBytes }) {
            entry.blocks[prevIdx].data.append(slice)
            entry.blocks[prevIdx].lastUsed = clock
            entry.blocks[prevIdx].pinned = entry.blocks[prevIdx].pinned || pinned
            totalBytes += slice.count
        } else {
            let block = Block(start: start, data: slice, lastUsed: clock, pinned: pinned)
            let insertIdx = entry.blocks.firstIndex(where: { $0.start > start }) ?? entry.blocks.count
            entry.blocks.insert(block, at: insertIdx)
            totalBytes += slice.count
        }
        entries[key] = entry
    }

    func invalidate(key: String) {
        removeEntry(key: key)
    }

    private func removeEntry(key: String) {
        guard let existing = entries.removeValue(forKey: key) else { return }
        for b in existing.blocks { totalBytes -= b.data.count }
    }

    private func evictIfNeeded() {
        while totalBytes > maxTotalBytes {
            var bestKey: String?
            var bestIdx: Int?
            var bestScore: UInt64 = .max
            var bestPinned = true

            for (key, entry) in entries {
                for (idx, block) in entry.blocks.enumerated() {
                    if !block.pinned {
                        if bestPinned || block.lastUsed < bestScore {
                            bestPinned = false
                            bestScore = block.lastUsed
                            bestKey = key
                            bestIdx = idx
                        }
                    } else if bestPinned && block.lastUsed < bestScore {
                        bestScore = block.lastUsed
                        bestKey = key
                        bestIdx = idx
                    }
                }
            }
            guard let victimKey = bestKey, let victimIdx = bestIdx, var entry = entries[victimKey] else { break }
            let evicted = entry.blocks.remove(at: victimIdx)
            totalBytes -= evicted.data.count
            if entry.blocks.isEmpty { entries.removeValue(forKey: victimKey) } else { entries[victimKey] = entry }
        }
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
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        let originalScheme = task.originalRequest?.url?.scheme?.lowercased()
        let schemeOK = scheme == "https" || (scheme == "http" && originalScheme == "http")
        guard schemeOK else {
            completionHandler(nil)
            return
        }
        var next = request
        if host != "115.com" && !host.hasSuffix(".115.com") {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        if let dataTask = task as? URLSessionDataTask {
            tasks[dataTask.taskIdentifier]?.didRedirect(to: url)
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let handler = tasks[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        completionHandler(handler.didReceive(response, from: dataTask) ? .allow : .cancel)
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
    /// 播放器请求的原始地址（换地址时按它找）
    private var originalURL: URL?
    private var requestHeaders: [String: String] = [:]
    private var explicitStreamID: String?
    fileprivate var profileGeneration = 0
    private var connectionReady = true
    /// 这条连接已经因为地址被拒换过几次地址、等过几次再试
    private var renewCount = 0
    private var refusalWaits = 0
    /// 为了让同一个视频的新连接能连上，这条连接的下载先停了（mpv 还连着），之后从断开的位置接着下
    private var yielded = false
    /// 连接建立的先后（让出的连接里优先恢复最近的那条）
    fileprivate let serial: Int
    /// 文件总长度（Content-Range 里的 /总长），换地址续传时用它确认还是同一个文件
    private var bodyTotal: Int64?
    private var profile = ""
    private var pending = 0
    private var suspended = false
    private var closed = false

    // 上游连不上或下载到一半断了：自己等一会儿重试，下载到一半的就从断开的位置接着下，
    // mpv 那边看到的仍是一条不间断的响应。
    private var baseRequest: URLRequest?
    /// 已经交给 mpv 的响应内容有多少字节（不含响应头）
    private var deliveredBody: Int64 = 0
    /// 这条响应的内容在文件里从第几个字节开始、到第几个字节结束（206 或带长度的 200 才知道，续传靠这个）
    private var bodyStart: Int64 = 0
    private var bodyEnd: Int64?
    private var validator: String?
    private var cachedContentType: String?
    private var cachedAcceptRanges: String?
    private var cachedLastModified: String?
    private var cachedSupportsRanges = false
    /// 正在进行的这次请求是续传（或下一分段），要求上游从这个位置接上
    private var resumeFrom: Int64?
    private var retryCount = 0
    private var retryProgressMark: Int64 = 0
    private var renewProgressMark: Int64 = 0
    private var retryWork: DispatchWorkItem?

    // 分段滑动窗口与停滞检测
    private var clientRangeStart: Int64?
    private var clientRangeEnd: Int64?
    private var chunkingActive = false
    private var currentChunkActualEnd: Int64?
    private var fellBackFromBoundedRange = false
    private var stallTimer: DispatchSourceTimer?
    private var lastProgressUptime: TimeInterval = 0
    private var windowStartUptime: TimeInterval = 0
    private var windowBytes: Int64 = 0

    init(connection: NWConnection, proxy: LocalStreamProxy) {
        self.connection = connection
        self.proxy = proxy
        self.serial = proxy.nextSerial()
    }

    private var renewalKey: String? {
        if let explicitStreamID { return explicitStreamID }
        return originalURL?.absoluteString
    }

    fileprivate var hasExplicitStreamID: Bool { explicitStreamID != nil }

    fileprivate func matchesStreamKey(_ key: String) -> Bool {
        explicitStreamID == key || originalURL?.absoluteString == key
    }

    private var isPlaylistChildStream: Bool {
        guard let originalURL, let key = renewalKey else { return false }
        return proxy.isPlaylistChild(url: originalURL, forKey: key)
    }

    /// 同一个 115 视频的连接用同一个键（m3u8 子分片可并发，不参与单流抢占）
    fileprivate var streamKey: String? {
        if isPlaylistChildStream { return nil }
        if let explicitStreamID { return explicitStreamID }
        guard let originalURL, proxy.canRenew(forKey: originalURL.absoluteString) else { return nil }
        return originalURL.absoluteString
    }

    /// 这条连接的下载正在进行（或者马上要重发）
    fileprivate var holdsUpstream: Bool { !closed && (task != nil || retryWork != nil) }

    fileprivate var isYielding: Bool { !closed && yielded }

    fileprivate var isClientAlive: Bool { !closed && connectionReady }

    fileprivate var canRefreshUpstream: Bool {
        guard !closed, !isHead, !isPlaylist else { return false }
        if !headersSent { return task != nil || retryWork != nil }
        return bodyEnd != nil && !bodyComplete && (task != nil || retryWork != nil || yielded)
    }

    fileprivate func didRedirect(to url: URL) {
        upstreamURL = url
    }

    fileprivate func forceClosePreempted() {
        close()
    }

    @discardableResult
    fileprivate func forceRefreshUpstream() -> Bool {
        guard canRefreshUpstream else { return false }
        let resumeAt: Int64? = headersSent ? (bodyStart + deliveredBody) : nil
        retryWork?.cancel()
        retryWork = nil
        stopStallTimer()
        if let task {
            proxy.detach(task)
            task.cancel()
            self.task = nil
        }
        yielded = false
        suspended = false
        retryCount = 0
        refusalWaits = 0

        if let key = renewalKey, let orig = originalURL, let failed = upstreamURL, proxy.canRenew(forKey: key) {
            if isPlaylistChildStream {
                proxy.renewPlaylistSegment(forKey: key, originalSegment: orig, failed: failed) { [weak self] fresh in
                    guard let self, !self.closed else { return }
                    if let fresh {
                        self.upstreamURL = fresh
                        self.baseRequest?.url = fresh
                    }
                    self.relaunch(resumingAt: resumeAt)
                }
                return true
            }
            if proxy.needsNewAddress(forKey: key, failed: failed, ignoreCooldown: true) {
                proxy.note("主动切换 115 下载线路" + (resumeAt.map { "（从 \($0) 字节续传）" } ?? ""))
                proxy.renew(forKey: key, failed: failed) { [weak self] fresh in
                    guard let self, !self.closed else { return }
                    if let fresh {
                        self.upstreamURL = fresh
                        self.baseRequest?.url = fresh
                    }
                    self.relaunch(resumingAt: resumeAt)
                }
                return true
            }
            let current = proxy.currentUpstream(forKey: key, fallback: orig)
            upstreamURL = current
            baseRequest?.url = current
        }
        proxy.note("重连上游下载节点" + (resumeAt.map { "（从 \($0) 字节续传）" } ?? ""))
        relaunch(resumingAt: resumeAt)
        return true
    }

    /// 把上游下载停掉，给同一个视频的新连接腾位置。只停已经在传内容、能续传的；其余的不动。
    fileprivate func yieldUpstream() {
        guard !closed, !yielded, headersSent, !isHead, !isPlaylist, bodyEnd != nil, !bodyComplete else { return }
        guard task != nil || retryWork != nil else { return }
        retryWork?.cancel()
        retryWork = nil
        stopStallTimer()
        if let task {
            proxy.detach(task)
            task.cancel()
        }
        task = nil
        resumeFrom = nil
        suspended = false
        yielded = true
        proxy.note("同一个视频开了新连接，旧连接先停在 \(bodyStart + deliveredBody) 字节")
    }

    /// 同一个视频别的下载都结束了，mpv 还连着这条：从停下的位置接着下
    fileprivate func resumeAfterYield() {
        guard yielded, isClientAlive else { return }
        yielded = false
        if bodyComplete {
            finish()
            return
        }
        proxy.note("接着下旧连接，从 \(bodyStart + deliveredBody) 字节开始")
        relaunch(resumingAt: bodyStart + deliveredBody)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.connectionReady = true
            case .failed, .cancelled:
                self?.connectionReady = false
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
                self.connectionReady = false
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
        originalURL = target.url
        requestHeaders = target.headers
        explicitStreamID = target.streamID
        profileGeneration = target.generation
        profile = target.profile
        let key = renewalKey ?? target.url.absoluteString
        let upstream = proxy.currentUpstream(forKey: key, fallback: target.url)
        upstreamURL = upstream

        var rawRange: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Range") == .orderedSame {
                rawRange = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let parsedRange = Self.parseBytesRange(rawRange)
        clientRangeStart = parsedRange?.start
        clientRangeEnd = parsedRange?.end

        var request = URLRequest(url: upstream)
        request.httpMethod = isHead ? "HEAD" : "GET"
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let rawRange {
            request.setValue(rawRange, forHTTPHeaderField: "Range")
        }
        // 不要压缩：视频的字节位置要和 Range 对得上
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        baseRequest = request

        let playlistCandidate = LocalStreamProxy.looksLikePlaylistURL(target.url) || isPlaylistChildStream
        let canChunk = !isHead && !playlistCandidate && proxy.chunkSize > 0 && parsedRange != nil

        // 先查内存头尾与热点缓存：命中的话可直接返回（或仅向 115 拉取剩余部分）
        if !isHead, !playlistCandidate, let parsed = parsedRange,
           let hit = proxy.blockCache.lookup(key: key, start: parsed.start, requestedEnd: parsed.end) {
            let meta = hit.meta
            let resolvedEnd = hit.resolvedEnd
            let total = meta.totalSize
            let expectedTotal = resolvedEnd - parsed.start + 1
            var head = "HTTP/1.1 206 Partial Content\r\n"
            if let ct = meta.contentType { head += "Content-Type: \(ct)\r\n" }
            head += "Content-Length: \(expectedTotal)\r\n"
            head += "Content-Range: bytes \(parsed.start)-\(resolvedEnd)/\(total)\r\n"
            if let ar = meta.acceptRanges { head += "Accept-Ranges: \(ar)\r\n" }
            if let lm = meta.lastModified { head += "Last-Modified: \(lm)\r\n" }
            if let et = meta.etag { head += "ETag: \(et)\r\n" }
            head += "Connection: close\r\n\r\n"

            headersSent = true
            bodyStart = parsed.start
            bodyEnd = resolvedEnd
            bodyTotal = total
            validator = meta.etag
            cachedContentType = meta.contentType
            cachedAcceptRanges = meta.acceptRanges
            cachedLastModified = meta.lastModified
            cachedSupportsRanges = meta.supportsRanges
            chunkingActive = canChunk && ((resolvedEnd - (parsed.start + Int64(hit.data.count)) + 1) > proxy.chunkSize)
            deliveredBody = Int64(hit.data.count)

            write(Data(head.utf8))
            write(hit.data)
            if bodyComplete {
                finish()
                return
            }
            if !isHead { proxy.claimUpstream(for: self) }
            relaunch(resumingAt: parsed.start + Int64(hit.data.count))
            return
        }

        if canChunk, let parsed = parsedRange {
            let maxEnd = parsed.start + proxy.chunkSize - 1
            if let cEnd = parsed.end {
                if cEnd > maxEnd {
                    request.setValue("bytes=\(parsed.start)-\(maxEnd)", forHTTPHeaderField: "Range")
                    chunkingActive = true
                }
            } else {
                request.setValue("bytes=\(parsed.start)-\(maxEnd)", forHTTPHeaderField: "Range")
                chunkingActive = true
            }
        }

        if !isHead { proxy.claimUpstream(for: self) }
        startUpstreamTask(request)
    }

    private func startUpstreamTask(_ request: URLRequest) {
        let now = ProcessInfo.processInfo.systemUptime
        lastProgressUptime = now
        windowStartUptime = now
        windowBytes = 0
        task = proxy.startTask(request, for: self)
        startStallTimer()
    }

    private func startStallTimer() {
        stopStallTimer()
        let timeout = proxy.stallTimeout
        guard timeout > 0 else { return }
        let interval = max(0.05, min(1.0, timeout / 2.0))
        let timer = DispatchSource.makeTimerSource(queue: proxy.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkStall() }
        stallTimer = timer
        timer.resume()
    }

    private func stopStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkStall() {
        guard !closed, !yielded, !suspended, let running = task else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let silentFor = now - lastProgressUptime
        var stalledReason: String?
        if silentFor >= proxy.stallTimeout {
            stalledReason = "上游节点 \(String(format: "%.1f", silentFor)) 秒无响应（\(upstreamURL?.host ?? "")），已转发 \(deliveredBody) 字节"
        } else if proxy.minHealthySpeed > 0, headersSent, windowBytes > 0 {
            let windowElapsed = now - windowStartUptime
            let slowWindow = max(proxy.stallTimeout + 2.0, 8.0)
            if windowElapsed >= slowWindow {
                let speed = Double(windowBytes) / windowElapsed
                if speed < proxy.minHealthySpeed {
                    stalledReason = "上游节点过慢（\(Int(speed / 1024)) KB/s），已转发 \(deliveredBody) 字节"
                } else {
                    windowStartUptime = now
                    windowBytes = 0
                }
            }
        }
        guard let reason = stalledReason else { return }
        stopStallTimer()
        proxy.detach(running)
        running.cancel()
        task = nil

        // 若已经在这个节点失败过且允许换新地址，直接切一个新的 115 CDN 地址
        if retryCount >= 1, !isPlaylistChildStream, let key = renewalKey, let failed = upstreamURL,
           proxy.canRenew(forKey: key), proxy.needsNewAddress(forKey: key, failed: failed, ignoreCooldown: true),
           renewUpstream(reason, cancelling: nil, resumeAt: headersSent ? (bodyStart + deliveredBody) : nil, ignoreCooldown: true) {
            return
        }
        if scheduleRetry(reason, cancelling: nil) { return }
        if headersSent { close() } else { respond(status: 502, text: "Bad Gateway") }
    }

    /// 返回 false：这次响应不要了（已经安排好重试，或者连接已经关了），系统会取消这个下载
    func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        guard !closed else { return false }
        guard let http = response as? HTTPURLResponse else {
            respond(status: 502, text: "Bad Gateway")
            return false
        }
        lastProgressUptime = ProcessInfo.processInfo.systemUptime
        if let start = resumeFrom {
            // 续传或下一分段：响应头早就发给 mpv 了，这里只确认上游真的从断开的位置接上，而且还是同一个文件
            resumeFrom = nil
            if Self.isRefused(status: http.statusCode),
               renewUpstream("续传时上游返回 HTTP \(http.statusCode)", cancelling: dataTask, resumeAt: start) {
                return false
            }
            if Self.isTransient(status: http.statusCode),
               scheduleRetry("续传时上游返回 HTTP \(http.statusCode)", cancelling: dataTask) {
                return false
            }
            let newValidator = http.value(forHTTPHeaderField: "ETag")
            let newTotal = Self.totalLength(of: http)
            let sameSize = bodyTotal != nil && newTotal == bodyTotal
            let sameFile = validator == nil || newValidator == nil || validator == newValidator || sameSize
            guard http.statusCode == 206, let chunkRange = Self.contentRange(of: http), chunkRange.start == start, sameFile else {
                if let key = renewalKey, !sameFile {
                    proxy.blockCache.invalidate(key: key)
                }
                proxy.note("续传失败：上游返回 HTTP \(http.statusCode)，没能从 \(start) 字节接上")
                close()
                return false
            }
            currentChunkActualEnd = chunkRange.end
            return true
        }
        responseURL = http.url
        if http.statusCode == 416, chunkingActive, clientRangeEnd == nil, !fellBackFromBoundedRange,
           let start = clientRangeStart {
            // 万一某个非 115 服务器不接受有界的分段 Range，退回开放式 bytes=start- 重发一次
            fellBackFromBoundedRange = true
            chunkingActive = false
            proxy.detach(dataTask)
            task = nil
            stopStallTimer()
            baseRequest?.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            relaunch(resumingAt: nil)
            return false
        }
        if Self.isRefused(status: http.statusCode),
           renewUpstream("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）", cancelling: dataTask, resumeAt: nil) {
            return false
        }
        if Self.isTransient(status: http.statusCode),
           scheduleRetry("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）", cancelling: dataTask) {
            return false
        }
        if http.statusCode >= 400 {
            proxy.note("上游返回 HTTP \(http.statusCode)：\(http.url?.host ?? "")")
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let path = (http.url?.path ?? upstreamURL?.path ?? "").lowercased()
        if (200..<300).contains(http.statusCode), type.contains("mpegurl") || path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") {
            // 播放列表整份收完，改好地址再发
            isPlaylist = true
            chunkingActive = false
            playlistStatus = http.statusCode
            return true
        }

        let arHeader = http.value(forHTTPHeaderField: "Accept-Ranges")
        let lmHeader = http.value(forHTTPHeaderField: "Last-Modified")
        let etagHeader = http.value(forHTTPHeaderField: "ETag")
        let ctHeader = http.value(forHTTPHeaderField: "Content-Type")
        validator = etagHeader
        cachedContentType = ctHeader
        cachedAcceptRanges = arHeader
        cachedLastModified = lmHeader

        var forwardContentRange = http.value(forHTTPHeaderField: "Content-Range")
        var forwardContentLength = http.value(forHTTPHeaderField: "Content-Length")

        if http.statusCode == 206, let range = Self.contentRange(of: http) {
            bodyStart = range.start
            currentChunkActualEnd = range.end
            let total = Self.totalLength(of: http)
            bodyTotal = total
            cachedSupportsRanges = true
            if chunkingActive, let total, total > 0 {
                let targetEnd = max(range.start, min(clientRangeEnd ?? (total - 1), total - 1))
                bodyEnd = targetEnd
                forwardContentRange = "bytes \(range.start)-\(targetEnd)/\(total)"
                forwardContentLength = String(targetEnd - range.start + 1)
            } else {
                chunkingActive = false
                bodyEnd = range.end
            }
        } else if http.statusCode == 200, let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length > 0 {
            chunkingActive = false
            bodyStart = 0
            bodyEnd = length - 1
            bodyTotal = length
            cachedSupportsRanges = (arHeader ?? "").lowercased().contains("bytes")
        } else {
            chunkingActive = false
            bodyTotal = Self.totalLength(of: http) ?? bodyEnd.map { $0 + 1 }
            cachedSupportsRanges = http.statusCode == 206 || (arHeader ?? "").lowercased().contains("bytes")
        }

        var head = "HTTP/1.1 \(http.statusCode) \(Self.reason(http.statusCode))\r\n"
        if let ctHeader { head += "Content-Type: \(ctHeader)\r\n" }
        if let forwardContentLength { head += "Content-Length: \(forwardContentLength)\r\n" }
        if let forwardContentRange { head += "Content-Range: \(forwardContentRange)\r\n" }
        if let arHeader { head += "Accept-Ranges: \(arHeader)\r\n" }
        if let lmHeader { head += "Last-Modified: \(lmHeader)\r\n" }
        if let etagHeader { head += "ETag: \(etagHeader)\r\n" }
        head += "Connection: close\r\n\r\n"
        headersSent = true
        write(Data(head.utf8))
        return true
    }

    func didReceive(_ data: Data) {
        guard !closed else { return }
        lastProgressUptime = ProcessInfo.processInfo.systemUptime
        windowBytes += Int64(data.count)
        if isPlaylist {
            playlistData.append(data)
        } else if !isHead {
            let offset = bodyStart + deliveredBody
            if !isPlaylistChildStream, let key = renewalKey, let total = bodyTotal, total > 0 {
                let meta = StreamBlockCache.Metadata(
                    totalSize: total,
                    supportsRanges: cachedSupportsRanges,
                    contentType: cachedContentType,
                    etag: validator,
                    lastModified: cachedLastModified,
                    acceptRanges: cachedAcceptRanges
                )
                proxy.blockCache.record(key: key, meta: meta, offset: offset, data: data)
            }
            deliveredBody += Int64(data.count)
            // 换地址/重试后已经稳定收到至少 64 KiB 实质视频数据，清零本次故障计数以支持多小时长片续命
            if renewCount > 0, deliveredBody - renewProgressMark >= 65_536 {
                renewCount = 0
                refusalWaits = 0
            }
            write(data)
        }
    }

    func didComplete(_ error: Error?) {
        task = nil
        stopStallTimer()
        guard !closed else { return }
        if let error {
            let detail = "上游连接失败：\(LocalStreamProxy.summary(of: error))（\(upstreamURL?.host ?? "")），已转发 \(deliveredBody) 字节"
            // 数据其实已经全部交给 mpv 了，只是收尾时断开：当作正常结束
            if bodyComplete {
                finish()
                return
            }
            if Self.isTransient(error) {
                if scheduleRetry(detail, cancelling: nil) { return }
            } else {
                proxy.note("\(detail)；这种错误重试没有用")
            }
            // 重试也没用：已经开始传数据了就直接断开，FFmpeg 会带着 Range 自己重新请求
            if headersSent { close() } else { respond(status: 502, text: "Bad Gateway") }
            return
        }
        if isPlaylist {
            sendPlaylist()
        } else if bodyComplete {
            finish()
        } else if chunkingActive, headersSent, let targetEnd = bodyEnd, let chunkEnd = currentChunkActualEnd,
                  bodyStart + deliveredBody == chunkEnd + 1, chunkEnd < targetEnd {
            // 当前分段完整收完且未到文件请求终点：立刻平滑衔接下一分段，mpv 侧毫无察觉
            retryCount = 0
            refusalWaits = 0
            retryProgressMark = deliveredBody
            relaunch(resumingAt: chunkEnd + 1)
        } else if headersSent, !isHead, bodyEnd != nil, !bodyComplete {
            // 上游未报错却提前断开：按断点续传处理，不直接截断给 mpv 的流
            if scheduleRetry("上游提前结束传输（已转发 \(deliveredBody) 字节）", cancelling: nil) { return }
            close()
        } else {
            finish()
        }
    }

    // MARK: 上游出错时重试、续传

    /// 响应内容已经全部交给 mpv
    private var bodyComplete: Bool {
        guard headersSent, !isHead, !isPlaylist, let end = bodyEnd else { return false }
        return bodyStart + deliveredBody > end
    }

    /// 等一会儿再向上游发一次请求。响应头已经发给 mpv 的，从断开的位置接着下；还没发的，原样重发。
    /// 返回 false：不能重试，或者重试的次数用完了，由调用方把错误交给 mpv。
    private func scheduleRetry(_ detail: String, cancelling running: URLSessionDataTask?) -> Bool {
        // 上次重试之后又传了实质数据，说明中间连上过：重新计数，长时间播放偶尔断一次不会把次数用光
        if deliveredBody > retryProgressMark {
            retryCount = 0
            retryProgressMark = deliveredBody
        }
        var resume: Int64?
        if headersSent {
            // 响应头已经发出去了：只有知道文件范围的普通下载才能接上
            guard !isHead, !isPlaylist, let end = bodyEnd, bodyStart + deliveredBody <= end else {
                proxy.note("\(detail)；这种响应没法续传")
                return false
            }
            resume = bodyStart + deliveredBody
        }
        let delays = proxy.retryDelays
        guard retryCount < delays.count else {
            proxy.note("\(detail)；重试 \(delays.count) 次都没成功")
            return false
        }
        let delay = delays[retryCount]
        retryCount += 1
        proxy.note("\(detail)；\(delay) 秒后第 \(retryCount) 次重试" + (resume.map { "，从 \($0) 字节接着下" } ?? ""))
        if let running { proxy.detach(running) }
        task = nil
        stopStallTimer()
        if !headersSent {
            // 播放列表只收了一半：丢掉重来
            playlistData = Data()
            isPlaylist = false
        }
        let resumePoint = resume
        let work = DispatchWorkItem { [weak self] in self?.relaunch(resumingAt: resumePoint) }
        retryWork = work
        proxy.queue.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    /// 上游拒绝了这个地址（115 回 403）：地址过期就换新地址重发；刚换来的地址也被拒（同一个文件的连接太多、
    /// 请求太密），就停掉同一个视频别的下载，等一会儿再试。响应头已经发给 mpv 的，从断开的位置接着下。
    /// 返回 false：这个视频没有登记换地址的办法，或者换地址、等待重试都用完了，由调用方照常处理。
    private func renewUpstream(_ detail: String, cancelling running: URLSessionDataTask?, resumeAt: Int64?, ignoreCooldown: Bool = false) -> Bool {
        guard let original = originalURL, let failed = upstreamURL, let key = renewalKey, proxy.canRenew(forKey: key) else { return false }
        if headersSent && resumeAt == nil { return false }

        if isPlaylistChildStream {
            let needRefresh = renewCount < 2 && proxy.needsNewPlaylistAddress(forKey: key, originalSegment: original, failed: failed)
            let waits = proxy.refusalDelays
            guard needRefresh || refusalWaits < waits.count else {
                proxy.note("\(detail)；m3u8 分片刷新和等待均未成功")
                return false
            }
            if let running { proxy.detach(running) }
            task = nil
            stopStallTimer()
            let tail = resumeAt.map { "后从 \($0) 字节接着下" } ?? "后重发"
            if needRefresh {
                renewCount += 1
                proxy.note("\(detail)，m3u8 分片可能过期，刷新列表\(tail)")
                proxy.renewPlaylistSegment(forKey: key, originalSegment: original, failed: failed) { [weak self] fresh in
                    guard let self, !self.closed else { return }
                    guard let fresh else {
                        if self.headersSent { self.close() } else { self.respond(status: 403, text: "Forbidden") }
                        return
                    }
                    self.upstreamURL = fresh
                    self.baseRequest?.url = fresh
                    self.relaunch(resumingAt: resumeAt)
                }
            } else {
                let delay = waits[refusalWaits]
                refusalWaits += 1
                proxy.note("\(detail)；新分片仍被拒，\(delay) 秒后再试\(tail)")
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed else { return }
                    let current = self.proxy.currentUpstream(forKey: key, fallback: original)
                    self.upstreamURL = current
                    self.baseRequest?.url = current
                    self.relaunch(resumingAt: resumeAt)
                }
                retryWork = work
                proxy.queue.asyncAfter(deadline: .now() + delay, execute: work)
            }
            return true
        }

        let renew = renewCount < 2 && proxy.needsNewAddress(forKey: key, failed: failed, ignoreCooldown: ignoreCooldown)
        let waits = proxy.refusalDelays
        guard renew || refusalWaits < waits.count else {
            proxy.note("\(detail)；换地址、等待重试都没成功")
            return false
        }
        if let running { proxy.detach(running) }
        task = nil
        stopStallTimer()
        if !headersSent {
            playlistData = Data()
            isPlaylist = false
        }
        // 先把同一个视频别的下载停掉，免得新请求又因为连接太多被拒
        proxy.claimUpstream(for: self)
        let tail = resumeAt.map { "后从 \($0) 字节接着下" } ?? "后重发"
        if renew {
            renewCount += 1
            renewProgressMark = deliveredBody
            proxy.note("\(detail)，地址可能过期了，换新地址\(tail)")
            proxy.renew(forKey: key, failed: failed) { [weak self] fresh in
                guard let self, !self.closed else { return }
                guard let fresh else {
                    if self.headersSent { self.close() } else { self.respond(status: 403, text: "Forbidden") }
                    return
                }
                self.upstreamURL = fresh
                self.baseRequest?.url = fresh
                self.relaunch(resumingAt: resumeAt)
            }
        } else {
            let delay = waits[refusalWaits]
            refusalWaits += 1
            proxy.note("\(detail)；新地址也被拒，多半是同一个文件的连接太多，\(delay) 秒后再试\(tail)")
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.closed else { return }
                let current = self.proxy.currentUpstream(forKey: key, fallback: original)
                self.upstreamURL = current
                self.baseRequest?.url = current
                self.relaunch(resumingAt: resumeAt)
            }
            retryWork = work
            proxy.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        return true
    }

    private func relaunch(resumingAt start: Int64?) {
        retryWork = nil
        guard !closed, var request = baseRequest else { return }
        if let start {
            let endBound: Int64?
            if chunkingActive, proxy.chunkSize > 0 {
                let chunkLimit = start + proxy.chunkSize - 1
                endBound = bodyEnd.map { min($0, chunkLimit) } ?? chunkLimit
            } else {
                endBound = bodyEnd
            }
            request.setValue("bytes=\(start)-" + (endBound.map { String($0) } ?? ""), forHTTPHeaderField: "Range")
            resumeFrom = start
        }
        // 旧的下载已经没了，积压的数据发完之后别去恢复它
        suspended = false
        proxy.claimUpstream(for: self)
        startUpstreamTask(request)
    }

    private static func parseBytesRange(_ value: String?) -> (start: Int64, end: Int64?)? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = String(spec[..<dash]).trimmingCharacters(in: .whitespaces)
        let endText = String(spec[spec.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        guard let start = Int64(startText), start >= 0 else { return nil }
        if endText.isEmpty { return (start, nil) }
        guard let end = Int64(endText), end >= start else { return nil }
        return (start, end)
    }

    /// 这些错误过一会儿再试多半就好了（对方掐断连接、暂时连不上、超时）
    private static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// 上游拒绝这个地址：115 的下载地址过期、或被收回时是 403
    private static func isRefused(status: Int) -> Bool {
        status == 401 || status == 403 || status == 410
    }

    /// `Content-Range: bytes 100-199/1000` 里的 1000
    private static func totalLength(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let total = value.split(separator: "/").last else { return nil }
        return Int64(total.trimmingCharacters(in: .whitespaces))
    }

    private static func isTransient(status: Int) -> Bool {
        status == 500 || status == 502 || status == 503 || status == 504
    }

    /// 解析 `Content-Range: bytes 100-199/1000`
    private static func contentRange(of response: HTTPURLResponse) -> (start: Int64, end: Int64)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        guard let span = parts[1].split(separator: "/", maxSplits: 1).first else { return nil }
        let bounds = span.split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return (start, end)
    }

    private func sendPlaylist() {
        let base = responseURL ?? upstreamURL ?? URL(string: "http://127.0.0.1/")!
        if let key = renewalKey, let orig = originalURL {
            proxy.ensurePlaylistEntry(forKey: key, rootURL: orig, headers: requestHeaders)
        }
        let text = String(decoding: playlistData, as: UTF8.self)
        let rewritten = proxy.rewritePlaylist(text, base: base, profile: profile, streamKey: renewalKey)
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
                self.lastProgressUptime = ProcessInfo.processInfo.systemUptime
                self.windowStartUptime = self.lastProgressUptime
                self.windowBytes = 0
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
        connectionReady = false
        stopStallTimer()
        retryWork?.cancel()
        retryWork = nil
        if let task {
            proxy.detach(task)
            task.cancel()
        }
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
