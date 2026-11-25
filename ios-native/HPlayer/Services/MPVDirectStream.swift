import Foundation
import Libmpv

/// `mpv_stream_cb_add_ro` C 回调桥接层，把 `hplayer115://` 协议直接接入进程内 `Direct115StreamStore`，
/// 跳过本机回环 TCP socket 与 HTTP 头编解码开销，同时保持 Apple TLS、16 MiB 分段、滑动预取与自动续链。
enum Direct115StreamBridge {
    static let scheme = "hplayer115"

    @discardableResult
    static func register(on mpv: OpaquePointer, store: Direct115StreamStore? = nil) -> Int32 {
        let userData = store.map { UnsafeMutableRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        return mpv_stream_cb_add_ro(mpv, scheme, userData, openCallback)
    }

    private static let openCallback: mpv_stream_cb_open_ro_fn = { userData, rawURI, info in
        guard let rawURI, let info else {
            return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
        }
        let uri = String(cString: rawURI)
        guard let url = URL(string: uri),
              url.scheme?.lowercased() == Direct115StreamBridge.scheme,
              let token = url.host, !token.isEmpty else {
            return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
        }
        let store: Direct115StreamStore
        if let userData {
            store = Unmanaged<Direct115StreamStore>.fromOpaque(userData).takeUnretainedValue()
        } else {
            store = Direct115StreamStore.shared
        }
        guard let handle = store.openHandle(token: token) else {
            return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
        }
        info.pointee.cookie = Unmanaged.passRetained(handle).toOpaque()
        info.pointee.read_fn = readCallback
        info.pointee.seek_fn = seekCallback
        info.pointee.size_fn = sizeCallback
        info.pointee.close_fn = closeCallback
        info.pointee.cancel_fn = cancelCallback
        return Int32(MPV_ERROR_SUCCESS.rawValue)
    }

    private static let readCallback: mpv_stream_cb_read_fn = { cookie, buf, nbytes in
        guard let cookie, let buf else { return -1 }
        let handle = Unmanaged<Direct115StreamHandle>.fromOpaque(cookie).takeUnretainedValue()
        return handle.read(into: buf, maxBytes: Int(min(nbytes, UInt64(Int.max))))
    }

    private static let seekCallback: mpv_stream_cb_seek_fn = { cookie, offset in
        guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        let handle = Unmanaged<Direct115StreamHandle>.fromOpaque(cookie).takeUnretainedValue()
        return handle.seek(to: offset)
    }

    private static let sizeCallback: mpv_stream_cb_size_fn = { cookie in
        guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        let handle = Unmanaged<Direct115StreamHandle>.fromOpaque(cookie).takeUnretainedValue()
        return handle.size()
    }

    private static let cancelCallback: mpv_stream_cb_cancel_fn = { cookie in
        guard let cookie else { return }
        let handle = Unmanaged<Direct115StreamHandle>.fromOpaque(cookie).takeUnretainedValue()
        handle.cancel()
    }

    private static let closeCallback: mpv_stream_cb_close_fn = { cookie in
        guard let cookie else { return }
        let handle = Unmanaged<Direct115StreamHandle>.fromOpaque(cookie).takeRetainedValue()
        handle.close()
    }
}

/// 进程内 115 原画直连流管理器（`hplayer115://`）。
/// 复用 `StreamBlockCache`、`ContainerIndexProbe` 与 115 域名 Cookie 守卫，
/// 为 mpv 提供零回环拷贝、支持头尾索引预热、滑动 1 段预取、403 自动降级与自动换链的数据通道。
final class Direct115StreamStore: NSObject, @unchecked Sendable {
    static let shared = Direct115StreamStore()
    static let scheme = Direct115StreamBridge.scheme

    fileprivate struct RegisteredStream {
        let token: String
        let streamKey: String
        let hasExplicitStreamID: Bool
        let generation: Int
        let initialStream: Direct115ResolvedStream
    }

    let queue = DispatchQueue(label: "app.hplayer.direct115-stream", qos: .userInitiated)
    private var session: URLSession!
    private var entries: [String: RegisteredStream] = [:]
    private var entryOrder: [String] = []
    private var streamGenerations: [String: Int] = [:]
    private var tasks: [Int: Direct115TaskHandler] = [:]
    private var handles: [ObjectIdentifier: Direct115StreamHandle] = [:]
    private var prewarms: [String: Direct115PrewarmTransfer] = [:]
    private var renewals: [String: Direct115StreamRenewal] = [:]
    private var renewalOrder: [String] = []
    private var lookaheadSuppressedUntil: [String: TimeInterval] = [:]
    private var serialCounter = 0
    private var lastProblem = ""
    private var problemHistory: [String] = []

    let blockCache = StreamBlockCache()
    fileprivate var retryDelays: [TimeInterval] = [0.3, 0.8, 1.6, 3.0]
    fileprivate var refusalDelays: [TimeInterval] = [0.6, 1.5, 3.0]
    fileprivate var chunkSize: Int64 = 16 * 1_048_576
    fileprivate var stallTimeout: TimeInterval = 10.0
    fileprivate var minHealthySpeed: Double = 8 * 1024
    fileprivate var lookaheadTriggerRatio: Double = 0.65
    fileprivate static let recoveryGrace: TimeInterval = 7.0

    private static let historyClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
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
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: 对外注册与预热

    /// 拿到 115 原画直链后立即在后台预热：建立 TLS 连接、拉取片头字节并自动探测 MP4 `moov` 或 MKV `Cues` 尾部索引写入内存缓存。
    func prewarm(
        stream: Direct115ResolvedStream,
        streamID: String? = nil,
        resume: Bool = false,
        renew: (() async throws -> Direct115ResolvedStream)? = nil
    ) {
        guard !LocalStreamProxy.looksLikePlaylistURL(stream.url) else { return }
        queue.async {
            let key = streamID ?? stream.url.absoluteString
            if let renew { self.registerRenewal(forKey: key, renew) }
            for (otherKey, other) in self.prewarms where otherKey != key {
                other.cancel()
                self.prewarms.removeValue(forKey: otherKey)
            }
            let hasActive = self.handles.values.contains { $0.streamKey == key && $0.isActiveOnStoreQueue }
            guard !hasActive, self.prewarms[key] == nil else { return }

            let activeStream = self.currentStream(forKey: key, fallback: stream)
            if let headHit = self.blockCache.lookup(key: key, start: 0, requestedEnd: 65_535) {
                if case .indexAtTail(let tailStart, let tailEnd, _) = ContainerIndexProbe.inspect(prefix: headHit.data, totalSize: headHit.meta.totalSize),
                   let missing = self.missingCacheRange(forKey: key, start: tailStart, end: tailEnd) {
                    self.startPrewarmTransfer(
                        key: key,
                        stream: activeStream,
                        start: missing.start,
                        end: missing.end,
                        resume: resume,
                        followTailIndex: false
                    )
                }
                return
            }

            let headEnd: Int64 = resume ? (256 * 1024 - 1) : (2 * 1_048_576 - 1)
            self.startPrewarmTransfer(
                key: key,
                stream: activeStream,
                start: 0,
                end: headEnd,
                resume: resume,
                followTailIndex: true
            )
        }
    }

    /// 注册一个 `hplayer115://` 进程内直连流，供 mpv 通过 `mpv_stream_cb` 打开。
    func register(
        stream: Direct115ResolvedStream,
        streamID: String? = nil,
        renew: (() async throws -> Direct115ResolvedStream)? = nil
    ) -> URL {
        queue.sync {
            lastProblem = ""
            let key = streamID ?? stream.url.absoluteString
            let generation: Int
            if let streamID {
                let next = (streamGenerations[streamID] ?? 0) + 1
                streamGenerations[streamID] = next
                generation = next
            } else {
                generation = 0
            }
            if let renew { registerRenewal(forKey: key, renew) }
            if streamID != nil {
                for handle in Array(handles.values) where handle.streamKey == key && handle.generation < generation {
                    handle.preemptClosedOnStoreQueue()
                }
            }
            let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            entries[token] = RegisteredStream(
                token: token,
                streamKey: key,
                hasExplicitStreamID: streamID != nil,
                generation: generation,
                initialStream: stream
            )
            entryOrder.append(token)
            if entryOrder.count > 32 {
                entries.removeValue(forKey: entryOrder.removeFirst())
            }
            let rawName = stream.url.lastPathComponent.isEmpty || stream.url.lastPathComponent == "/" ? "stream.mp4" : stream.url.lastPathComponent
            let safeName = rawName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "stream.mp4"
            return URL(string: "\(Self.scheme)://\(token)/\(safeName)")!
        }
    }

    func openHandle(token: String) -> Direct115StreamHandle? {
        queue.sync {
            guard let entry = entries[token] else { return nil }
            serialCounter += 1
            let handle = Direct115StreamHandle(
                entry: entry,
                serial: serialCounter,
                store: self
            )
            handles[ObjectIdentifier(handle)] = handle
            return handle
        }
    }

    // MARK: 播放控制器健康检查与续链钩子

    func currentUpstream(for engineURL: URL) -> Direct115ResolvedStream? {
        guard engineURL.scheme?.lowercased() == Self.scheme, let token = engineURL.host else { return nil }
        return queue.sync {
            guard let entry = entries[token] else { return nil }
            return currentStream(forKey: entry.streamKey, fallback: entry.initialStream)
        }
    }

    @discardableResult
    func refreshActiveUpstream(for engineURL: URL) -> Bool {
        guard engineURL.scheme?.lowercased() == Self.scheme, let token = engineURL.host else { return false }
        return queue.sync {
            guard let entry = entries[token] else { return false }
            if renewals[entry.streamKey]?.refreshing == true { return false }
            let candidates = handles.values
                .filter { $0.token == token && $0.canRefreshUpstreamOnStoreQueue }
                .sorted { $0.serial > $1.serial }
            guard let active = candidates.first else { return false }
            return active.forceRefreshUpstreamOnStoreQueue()
        }
    }

    func isRecovering(for engineURL: URL, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard engineURL.scheme?.lowercased() == Self.scheme, let token = engineURL.host else { return false }
        return queue.sync {
            guard let entry = entries[token] else { return false }
            let active = handles.values.filter { $0.token == token && $0.isActiveOnStoreQueue }
            return active.filter { $0.streamKey == entry.streamKey }.max { $0.serial < $1.serial }?.isRecoveringOnStoreQueue(at: uptime) == true
        }
    }

    func isStreamHealthyOrRecovering(for engineURL: URL) -> Bool {
        guard engineURL.scheme?.lowercased() == Self.scheme, let token = engineURL.host else { return false }
        return queue.sync {
            guard let entry = entries[token] else { return false }
            if renewals[entry.streamKey]?.refreshing == true { return true }
            let now = ProcessInfo.processInfo.systemUptime
            return handles.values.contains {
                $0.token == token && ($0.isActivelyReceivingOrRecoveringOnStoreQueue || $0.isRecoveringOnStoreQueue(at: now))
            }
        }
    }

    var statusText: String {
        queue.sync {
            "进程内直连（活跃流 \(handles.count) 条，块缓存 \(blockCache.totalBytes / 1024) KiB）"
        }
    }

    var problem: String {
        queue.sync { lastProblem }
    }

    var problemHistoryLines: [String] {
        queue.sync { problemHistory }
    }

    #if DEBUG
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

    func setLookaheadTriggerRatioForTesting(_ ratio: Double) {
        queue.sync { lookaheadTriggerRatio = ratio }
    }

    func isLookaheadSuppressedForTesting(streamKey: String) -> Bool {
        queue.sync { isLookaheadSuppressed(forKey: streamKey) }
    }

    func cachedByteCountForTesting() -> Int {
        blockCache.totalBytes
    }
    #endif

    // MARK: 内部调度（仅在 queue 上调用）

    fileprivate func startTask(_ request: URLRequest, for handler: Direct115TaskHandler) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        tasks[task.taskIdentifier] = handler
        task.resume()
        return task
    }

    fileprivate func reassignTask(_ task: URLSessionDataTask, to handler: Direct115TaskHandler) {
        tasks[task.taskIdentifier] = handler
    }

    fileprivate func detach(_ task: URLSessionDataTask) {
        tasks.removeValue(forKey: task.taskIdentifier)
    }

    fileprivate func note(_ text: String) {
        lastProblem = text
        problemHistory.append("\(Self.historyClock.string(from: Date())) \(text)")
        if problemHistory.count > 12 { problemHistory.removeFirst(problemHistory.count - 12) }
    }

    fileprivate func currentStream(forKey key: String, fallback: Direct115ResolvedStream) -> Direct115ResolvedStream {
        renewals[key]?.current ?? fallback
    }

    fileprivate func canRenew(forKey key: String) -> Bool {
        renewals[key] != nil
    }

    fileprivate func needsNewAddress(forKey key: String, failed: URL, ignoreCooldown: Bool = false) -> Bool {
        guard let renewal = renewals[key] else { return false }
        if renewal.refreshing { return true }
        if let current = renewal.current, current.url != failed { return true }
        let cooldown: TimeInterval = ignoreCooldown ? 20 : 30
        if let last = renewal.renewedAt, renewal.current?.url == failed, Date().timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }

    fileprivate func renew(forKey key: String, failed: URL, completion: @escaping (Direct115ResolvedStream?) -> Void) {
        guard let renewal = renewals[key] else {
            completion(nil)
            return
        }
        if let current = renewal.current, current.url != failed {
            completion(current)
            return
        }
        renewal.waiters.append(completion)
        guard !renewal.refreshing else { return }
        renewal.refreshing = true
        let fetch = renewal.fetch
        Task {
            var fresh: Direct115ResolvedStream?
            var failure = ""
            do { fresh = try await fetch() } catch { failure = LocalStreamProxy.summary(of: error) }
            self.queue.async {
                renewal.refreshing = false
                if let fresh {
                    renewal.current = fresh
                    renewal.renewedAt = Date()
                    self.note("进程内直连已换新地址（\(fresh.url.host ?? "")）")
                } else {
                    self.note("进程内直连换新地址失败：\(failure)")
                }
                let waiters = renewal.waiters
                renewal.waiters = []
                waiters.forEach { $0(fresh) }
            }
        }
    }

    fileprivate func claimUpstream(for handle: Direct115StreamHandle) {
        let key = handle.streamKey
        cancelPrewarm(forKey: key)
        for other in Array(handles.values) where other !== handle && other.streamKey == key {
            if handle.hasExplicitStreamID && other.generation < handle.generation {
                other.preemptClosedOnStoreQueue()
            } else {
                other.yieldUpstreamOnStoreQueue()
            }
        }
    }

    fileprivate func handleClosed(_ handle: Direct115StreamHandle) {
        handles.removeValue(forKey: ObjectIdentifier(handle))
        let key = handle.streamKey
        let activeGen = streamGenerations[key] ?? 0
        let same = handles.values.filter { $0.streamKey == key }
        for other in same where other.isYieldingOnStoreQueue && other.hasExplicitStreamID && other.generation != activeGen {
            other.preemptClosedOnStoreQueue()
        }
        let aliveSame = handles.values.filter { $0.streamKey == key }
        guard !aliveSame.contains(where: { $0.holdsUpstreamOnStoreQueue }),
              let waiting = aliveSame.filter({ $0.isYieldingOnStoreQueue }).max(by: { $0.serial < $1.serial }) else { return }
        waiting.resumeAfterYieldOnStoreQueue()
    }

    fileprivate func takeAdoptablePrewarm(forKey key: String, start: Int64) -> Direct115PrewarmTransfer? {
        guard let transfer = prewarms[key], transfer.canBeAdopted(forStart: start) else { return nil }
        prewarms.removeValue(forKey: key)
        return transfer
    }

    fileprivate func cancelPrewarm(forKey key: String) {
        prewarms.removeValue(forKey: key)?.cancel()
    }

    fileprivate func prewarmDidFinish(_ transfer: Direct115PrewarmTransfer, nextTailRange: (start: Int64, end: Int64)?) {
        guard prewarms[transfer.key] === transfer else { return }
        prewarms.removeValue(forKey: transfer.key)
        guard let tail = nextTailRange else { return }
        let hasActive = handles.values.contains { $0.streamKey == transfer.key && $0.isActiveOnStoreQueue }
        guard !hasActive else { return }
        guard let missing = missingCacheRange(forKey: transfer.key, start: tail.start, end: tail.end) else { return }
        let activeStream = currentStream(forKey: transfer.key, fallback: transfer.stream)
        startPrewarmTransfer(
            key: transfer.key,
            stream: activeStream,
            start: missing.start,
            end: missing.end,
            resume: transfer.resume,
            followTailIndex: false
        )
    }

    fileprivate func isLookaheadSuppressed(forKey key: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let until = lookaheadSuppressedUntil[key] else { return false }
        if until <= now {
            lookaheadSuppressedUntil.removeValue(forKey: key)
            return false
        }
        return true
    }

    fileprivate func suppressLookahead(forKey key: String, duration: TimeInterval = 60) {
        lookaheadSuppressedUntil[key] = ProcessInfo.processInfo.systemUptime + duration
    }

    private func registerRenewal(forKey key: String, _ renew: @escaping () async throws -> Direct115ResolvedStream) {
        renewals[key] = Direct115StreamRenewal(renew)
        renewalOrder.removeAll { $0 == key }
        renewalOrder.append(key)
        if renewalOrder.count > 16 {
            let evicted = renewalOrder.removeFirst()
            renewals.removeValue(forKey: evicted)
        }
    }

    private func startPrewarmTransfer(
        key: String,
        stream: Direct115ResolvedStream,
        start: Int64,
        end: Int64,
        resume: Bool,
        followTailIndex: Bool
    ) {
        guard end >= start else { return }
        prewarms[key]?.cancel()
        var request = URLRequest(url: stream.url)
        request.httpMethod = "GET"
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let transfer = Direct115PrewarmTransfer(
            key: key,
            stream: stream,
            rangeStart: start,
            rangeEnd: end,
            resume: resume,
            followTailIndex: followTailIndex,
            store: self
        )
        prewarms[key] = transfer
        transfer.start(request: request)
    }

    private func missingCacheRange(forKey key: String, start: Int64, end: Int64) -> (start: Int64, end: Int64)? {
        guard end >= start else { return nil }
        guard let hit = blockCache.lookup(key: key, start: start, requestedEnd: end) else {
            return (start, end)
        }
        let coveredEnd = start + Int64(hit.data.count) - 1
        guard coveredEnd < hit.resolvedEnd else { return nil }
        return (coveredEnd + 1, hit.resolvedEnd)
    }
}

extension Direct115StreamStore: URLSessionDataDelegate {
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
        if !Direct115Client.is115CookieHost(host) {
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

// MARK: - 内部传输组件

private protocol Direct115TaskHandler: AnyObject {
    func didRedirect(to url: URL)
    func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool
    func didReceive(_ data: Data)
    func didComplete(_ error: Error?)
}

private final class Direct115StreamRenewal: @unchecked Sendable {
    let fetch: () async throws -> Direct115ResolvedStream
    var current: Direct115ResolvedStream?
    var renewedAt: Date?
    var refreshing = false
    var waiters: [(Direct115ResolvedStream?) -> Void] = []

    init(_ fetch: @escaping () async throws -> Direct115ResolvedStream) {
        self.fetch = fetch
    }
}

private enum Direct115HTTPHelper {
    static func totalLength(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let total = value.split(separator: "/").last else { return nil }
        return Int64(total.trimmingCharacters(in: .whitespaces))
    }

    static func contentRange(of response: HTTPURLResponse) -> (start: Int64, end: Int64)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        guard let span = parts[1].split(separator: "/", maxSplits: 1).first else { return nil }
        let bounds = span.split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return (start, end)
    }

    static func isRefused(status: Int) -> Bool {
        status == 401 || status == 403 || status == 410
    }

    static func isTransient(status: Int) -> Bool {
        status == 500 || status == 502 || status == 503 || status == 504
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

/// 进程内直连预热传输：预取片头字节并自动探测 MP4 `moov` 或 MKV `Cues` 尾部索引写入共享块缓存。
private final class Direct115PrewarmTransfer: Direct115TaskHandler {
    let key: String
    let stream: Direct115ResolvedStream
    var url: URL
    let rangeStart: Int64
    let rangeEnd: Int64
    let resume: Bool
    let followTailIndex: Bool
    private weak var store: Direct115StreamStore?

    private(set) var task: URLSessionDataTask?
    private(set) var responseReceived = false
    private(set) var meta: StreamBlockCache.Metadata?
    private(set) var actualStart: Int64 = 0
    private(set) var actualEnd: Int64 = 0
    private(set) var bufferedData = Data()
    private var probedIndex = false
    private var detectedTailRange: (start: Int64, end: Int64)?
    private var tailSwitchThreshold = 65_536
    private var finished = false

    init(
        key: String,
        stream: Direct115ResolvedStream,
        rangeStart: Int64,
        rangeEnd: Int64,
        resume: Bool,
        followTailIndex: Bool,
        store: Direct115StreamStore
    ) {
        self.key = key
        self.stream = stream
        self.url = stream.url
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.resume = resume
        self.followTailIndex = followTailIndex
        self.store = store
    }

    func start(request: URLRequest) {
        guard let store, !finished else { return }
        task = store.startTask(request, for: self)
    }

    func canBeAdopted(forStart start: Int64) -> Bool {
        guard !finished, task != nil, start == rangeStart else { return false }
        if responseReceived {
            return meta != nil && actualStart == start
        }
        return true
    }

    func detachTaskForAdoption() -> URLSessionDataTask? {
        finished = true
        let running = task
        task = nil
        return running
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        if let task {
            store?.detach(task)
            task.cancel()
        }
        task = nil
    }

    func didRedirect(to url: URL) {
        self.url = url
    }

    func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        guard !finished, let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              let range = Direct115HTTPHelper.contentRange(of: http),
              range.start == rangeStart,
              let total = Direct115HTTPHelper.totalLength(of: http), total > 0 else {
            finish(nextTail: nil)
            return false
        }
        responseReceived = true
        actualStart = range.start
        actualEnd = range.end
        meta = StreamBlockCache.Metadata(
            totalSize: total,
            supportsRanges: true,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            acceptRanges: http.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes"
        )
        return true
    }

    func didReceive(_ data: Data) {
        guard !finished, let meta, let store, !data.isEmpty else { return }
        let offset = actualStart + Int64(bufferedData.count)
        bufferedData.append(data)
        store.blockCache.record(key: key, meta: meta, offset: offset, data: data)

        if followTailIndex && !probedIndex && actualStart == 0 && bufferedData.count >= 64 {
            switch ContainerIndexProbe.inspect(prefix: bufferedData, totalSize: meta.totalSize) {
            case .indexAtHead:
                probedIndex = true
            case .indexAtTail(let tailStart, let tailEnd, let threshold):
                probedIndex = true
                detectedTailRange = (tailStart, tailEnd)
                tailSwitchThreshold = threshold
            case .undetermined:
                if bufferedData.count >= 32_768 { probedIndex = true }
            }
        }
        if followTailIndex && detectedTailRange != nil && bufferedData.count >= tailSwitchThreshold {
            if let running = task {
                store.detach(running)
                running.cancel()
                task = nil
            }
            finish(nextTail: detectedTailRange)
        }
    }

    func didComplete(_ error: Error?) {
        task = nil
        guard !finished else { return }
        finish(nextTail: error == nil ? detectedTailRange : nil)
    }

    private func finish(nextTail: (start: Int64, end: Int64)?) {
        guard !finished else { return }
        finished = true
        if let task {
            store?.detach(task)
            task.cancel()
            self.task = nil
        }
        store?.prewarmDidFinish(self, nextTailRange: nextTail)
    }
}

/// 进程内滑动 1 段预取：消除 16 MiB 分段切换时的 RTT 停顿，遇 403/401/410 自动降回单连接。
private final class Direct115LookaheadTransfer: Direct115TaskHandler {
    let streamKey: String
    let rangeStart: Int64
    let rangeEnd: Int64
    let expectedTotal: Int64?
    let expectedValidator: String?
    private let maxBufferBytes: Int
    private weak var store: Direct115StreamStore?

    var url: URL
    private(set) var task: URLSessionDataTask?
    private(set) var responseReceived = false
    private(set) var actualEnd: Int64 = 0
    private(set) var bufferedData = Data()
    private(set) var completed = false
    private(set) var failed = false

    init(
        streamKey: String,
        url: URL,
        rangeStart: Int64,
        rangeEnd: Int64,
        expectedTotal: Int64?,
        expectedValidator: String?,
        maxBufferBytes: Int,
        store: Direct115StreamStore
    ) {
        self.streamKey = streamKey
        self.url = url
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.expectedTotal = expectedTotal
        self.expectedValidator = expectedValidator
        self.maxBufferBytes = maxBufferBytes
        self.store = store
    }

    func start(request: URLRequest) {
        guard let store, !failed else { return }
        task = store.startTask(request, for: self)
    }

    func detachTaskForAdoption() -> URLSessionDataTask? {
        let running = task
        task = nil
        return running
    }

    func cancel() {
        failed = true
        if let task {
            store?.detach(task)
            task.cancel()
            self.task = nil
        }
    }

    func didRedirect(to url: URL) {
        self.url = url
    }

    func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        guard !failed, let http = response as? HTTPURLResponse else { return false }
        if Direct115HTTPHelper.isRefused(status: http.statusCode) {
            store?.suppressLookahead(forKey: streamKey, duration: 60)
            store?.note("进程内预取收到 HTTP \(http.statusCode)，自动降级为单连接")
            cancel()
            return false
        }
        guard http.statusCode == 206, let range = Direct115HTTPHelper.contentRange(of: http), range.start == rangeStart else {
            cancel()
            return false
        }
        let newTotal = Direct115HTTPHelper.totalLength(of: http)
        let newValidator = http.value(forHTTPHeaderField: "ETag")
        let sameSize = expectedTotal != nil && newTotal == expectedTotal
        let sameFile = expectedValidator == nil || newValidator == nil || expectedValidator == newValidator || sameSize
        guard sameFile else {
            cancel()
            return false
        }
        responseReceived = true
        actualEnd = range.end
        return true
    }

    func didReceive(_ data: Data) {
        guard !failed, !data.isEmpty else { return }
        if bufferedData.count + data.count > maxBufferBytes {
            cancel()
            return
        }
        bufferedData.append(data)
    }

    func didComplete(_ error: Error?) {
        task = nil
        if error != nil {
            failed = true
        } else if !failed {
            completed = true
        }
    }
}

/// 对应一次 `mpv_stream_cb` 打开实例的句柄：
/// - `read / seek / size` 由 mpv 的解复用线程调用，通过 `NSCondition` 零忙等阻塞；
/// - `cancel` 可从任意线程调用且永不阻塞；
/// - 网络任务与重试/换链/预取全部运行在 `store.queue` 上，严格遵循单向锁顺序杜绝死锁。
final class Direct115StreamHandle: Direct115TaskHandler, @unchecked Sendable {
    private static let pauseBytes = 8 * 1_048_576
    private static let resumeBytes = 2 * 1_048_576

    let token: String
    let streamKey: String
    let hasExplicitStreamID: Bool
    let generation: Int
    let serial: Int
    private unowned let store: Direct115StreamStore

    // MARK: 跨线程共享状态（由 `condition` 保护，只做微秒级内存操作）
    private let condition = NSCondition()
    private var cursor: Int64 = 0
    private var bufferStart: Int64 = 0
    private var streamBuffer = Data()
    private var totalSize: Int64?
    private var responseHeaderArrived = false
    private var eofReached = false
    private var terminalError = false
    private var cancelled = false
    private var closed = false
    private var seekGeneration: UInt64 = 1
    private var upstreamRequestedGeneration: UInt64 = 0

    // MARK: 网络状态（仅在 `store.queue` 上读写）
    private var activeStream: Direct115ResolvedStream
    private var redirectedURL: URL
    private var activeSeekGeneration: UInt64 = 0
    private var task: URLSessionDataTask?
    private var lookahead: Direct115LookaheadTransfer?
    private var adoptedFromLookahead = false
    private var suspended = false
    private var yielded = false
    private var closedOnQueue = false
    private var expectedChunkStart: Int64 = 0
    private var currentChunkActualEnd: Int64?
    private var nextFetchOffset: Int64 = 0
    private var deliveredSinceOpen: Int64 = 0
    private var validator: String?
    private var cachedContentType: String?
    private var cachedAcceptRanges: String?
    private var cachedLastModified: String?
    private var cachedSupportsRanges = false
    private var knownTotalOnQueue: Int64?
    private var retryCount = 0
    private var retryProgressMark: Int64 = 0
    private var renewCount = 0
    private var renewProgressMark: Int64 = 0
    private var refusalWaits = 0
    private var retryWork: DispatchWorkItem?
    private var renewalID: UUID?
    private var recoveryWindow: (deadline: TimeInterval, bytes: Int64)?
    private var stallTimer: DispatchSourceTimer?
    private var lastProgressUptime: TimeInterval = 0
    private var lastReceivedBytesUptime: TimeInterval = 0
    private var recentSampleStartUptime: TimeInterval = 0
    private var recentSampleBytes: Int64 = 0
    private var windowStartUptime: TimeInterval = 0
    private var windowBytes: Int64 = 0

    fileprivate init(entry: Direct115StreamStore.RegisteredStream, serial: Int, store: Direct115StreamStore) {
        self.token = entry.token
        self.streamKey = entry.streamKey
        self.hasExplicitStreamID = entry.hasExplicitStreamID
        self.generation = entry.generation
        self.serial = serial
        self.store = store
        let resolved = store.currentStream(forKey: entry.streamKey, fallback: entry.initialStream)
        self.activeStream = resolved
        self.redirectedURL = resolved.url
        if let meta = store.blockCache.metadata(forKey: entry.streamKey), meta.totalSize > 0 {
            self.totalSize = meta.totalSize
            self.knownTotalOnQueue = meta.totalSize
            self.validator = meta.etag
            self.cachedContentType = meta.contentType
            self.cachedAcceptRanges = meta.acceptRanges
            self.cachedLastModified = meta.lastModified
            self.cachedSupportsRanges = meta.supportsRanges
        }
    }

    // MARK: mpv_stream_cb 回调实现

    func read(into destination: UnsafeMutablePointer<CChar>, maxBytes: Int) -> Int64 {
        guard maxBytes > 0 else { return 0 }
        condition.lock()
        while true {
            if cancelled || closed {
                condition.unlock()
                return -1
            }
            if let total = totalSize, cursor >= total {
                condition.unlock()
                return 0
            }

            // 路径 1：命中活跃内存流缓冲区（零拷贝之外的最快路径）
            if cursor >= bufferStart && cursor < bufferStart + Int64(streamBuffer.count) {
                let offsetInBuffer = Int(cursor - bufferStart)
                let available = streamBuffer.count - offsetInBuffer
                let copyCount = min(maxBytes, available)
                streamBuffer.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    memcpy(destination, base.advanced(by: offsetInBuffer), copyCount)
                }
                cursor += Int64(copyCount)
                let consumeEnd = offsetInBuffer + copyCount
                if consumeEnd >= streamBuffer.count {
                    streamBuffer.removeAll(keepingCapacity: true)
                    bufferStart = cursor
                } else {
                    streamBuffer.removeFirst(consumeEnd)
                    bufferStart = cursor
                }
                let remainingBuffered = streamBuffer.count
                let gen = seekGeneration
                condition.unlock()
                if remainingBuffered < Self.resumeBytes {
                    store.queue.async { [weak self] in
                        self?.resumeIfSuspendedOnStoreQueue(generation: gen)
                    }
                }
                return Int64(copyCount)
            }

            // 路径 2：直接命中共享头尾/热点块缓存（MP4 moov / MKV Cues / 刚预热的片头毫秒返回）
            let cacheQueryOffset = cursor
            let cacheLimit = min(maxBytes, 1_048_576)
            condition.unlock()
            if let hit = store.blockCache.lookup(
                key: streamKey,
                start: cacheQueryOffset,
                requestedEnd: cacheQueryOffset + Int64(cacheLimit) - 1,
                maxReturnBytes: cacheLimit
            ), !hit.data.isEmpty {
                condition.lock()
                if cancelled || closed {
                    condition.unlock()
                    return -1
                }
                if cursor == cacheQueryOffset {
                    if totalSize == nil, hit.meta.totalSize > 0 {
                        totalSize = hit.meta.totalSize
                    }
                    let copyCount = min(maxBytes, hit.data.count)
                    hit.data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        memcpy(destination, base, copyCount)
                    }
                    cursor += Int64(copyCount)
                    if !streamBuffer.isEmpty {
                        let bufferEnd = bufferStart + Int64(streamBuffer.count)
                        if cursor >= bufferEnd {
                            streamBuffer.removeAll(keepingCapacity: true)
                            bufferStart = cursor
                        } else if cursor > bufferStart {
                            streamBuffer.removeFirst(Int(cursor - bufferStart))
                            bufferStart = cursor
                        }
                    } else {
                        bufferStart = cursor
                    }
                    condition.unlock()
                    return Int64(copyCount)
                }
                // cursor 在查缓存期间被修改，重新循环
                continue
            }

            condition.lock()
            if cancelled || closed {
                condition.unlock()
                return -1
            }
            if let total = totalSize, cursor >= total {
                condition.unlock()
                return 0
            }
            if cursor >= bufferStart && cursor < bufferStart + Int64(streamBuffer.count) {
                continue
            }
            if eofReached {
                condition.unlock()
                return 0
            }
            if terminalError {
                condition.unlock()
                return -1
            }

            // 路径 3：触发/等待网络分段流式拉取
            if upstreamRequestedGeneration != seekGeneration {
                upstreamRequestedGeneration = seekGeneration
                let targetOffset = cursor
                let gen = seekGeneration
                condition.unlock()
                store.queue.async { [weak self] in
                    self?.startOrAdoptUpstreamOnStoreQueue(offset: targetOffset, generation: gen)
                }
                condition.lock()
                continue
            }

            condition.wait()
        }
    }

    func seek(to offset: Int64) -> Int64 {
        guard offset >= 0 else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        condition.lock()
        if cancelled || closed {
            condition.unlock()
            return Int64(MPV_ERROR_GENERIC.rawValue)
        }
        if let total = totalSize, offset > total {
            condition.unlock()
            return Int64(MPV_ERROR_GENERIC.rawValue)
        }
        if offset == cursor {
            condition.unlock()
            return offset
        }
        // 目标偏移仍在已收到的内存缓冲区内：直接移动游标，零网络中断
        if offset >= bufferStart && offset < bufferStart + Int64(streamBuffer.count) {
            let skip = Int(offset - bufferStart)
            if skip > 0 {
                streamBuffer.removeFirst(skip)
                bufferStart = offset
            }
            cursor = offset
            eofReached = false
            let remaining = streamBuffer.count
            let gen = seekGeneration
            condition.unlock()
            if remaining < Self.resumeBytes {
                store.queue.async { [weak self] in
                    self?.resumeIfSuspendedOnStoreQueue(generation: gen)
                }
            }
            return offset
        }

        cursor = offset
        bufferStart = offset
        streamBuffer.removeAll(keepingCapacity: true)
        eofReached = false
        terminalError = false
        seekGeneration &+= 1
        upstreamRequestedGeneration = 0
        let gen = seekGeneration
        condition.unlock()

        store.queue.async { [weak self] in
            self?.handleSeekResetOnStoreQueue(generation: gen)
        }
        return offset
    }

    func size() -> Int64 {
        if let cachedMeta = store.blockCache.metadata(forKey: streamKey), cachedMeta.totalSize > 0 {
            condition.lock()
            if totalSize == nil { totalSize = cachedMeta.totalSize }
            condition.unlock()
            return cachedMeta.totalSize
        }

        condition.lock()
        while true {
            if let total = totalSize {
                condition.unlock()
                return total
            }
            if cancelled || closed || terminalError || responseHeaderArrived {
                condition.unlock()
                return Int64(MPV_ERROR_UNSUPPORTED.rawValue)
            }
            if upstreamRequestedGeneration != seekGeneration {
                upstreamRequestedGeneration = seekGeneration
                let targetOffset = cursor
                let gen = seekGeneration
                condition.unlock()
                store.queue.async { [weak self] in
                    self?.startOrAdoptUpstreamOnStoreQueue(offset: targetOffset, generation: gen)
                }
                condition.lock()
                continue
            }
            condition.wait()
        }
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
        store.queue.async { [weak self] in
            self?.cancelNetworkOnStoreQueue()
        }
    }

    func close() {
        condition.lock()
        closed = true
        cancelled = true
        streamBuffer.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        store.queue.async { [weak self] in
            self?.teardownOnStoreQueue()
        }
    }

    // MARK: 队列状态查询与抢占（仅在 store.queue 调用）

    fileprivate var holdsUpstreamOnStoreQueue: Bool {
        !closedOnQueue && (task != nil || retryWork != nil || renewalID != nil)
    }

    fileprivate var isYieldingOnStoreQueue: Bool { !closedOnQueue && yielded }

    fileprivate var isActiveOnStoreQueue: Bool { !closedOnQueue && !yielded && holdsUpstreamOnStoreQueue }

    fileprivate func isRecoveringOnStoreQueue(at uptime: TimeInterval) -> Bool {
        guard let recoveryWindow else { return false }
        return uptime < recoveryWindow.deadline
    }

    fileprivate var canRefreshUpstreamOnStoreQueue: Bool {
        guard !closedOnQueue, renewalID == nil, !suspended else { return false }
        return task != nil || retryWork != nil || yielded
    }

    fileprivate var isActivelyReceivingOrRecoveringOnStoreQueue: Bool {
        guard !closedOnQueue else { return false }
        if suspended || retryWork != nil { return true }
        condition.lock()
        let buffered = streamBuffer.count
        condition.unlock()
        if buffered >= Self.resumeBytes { return true }
        guard task != nil, lastReceivedBytesUptime > 0 else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReceivedBytesUptime <= 4.0 else { return false }
        let elapsed = max(1.0, now - recentSampleStartUptime)
        let rate = Double(recentSampleBytes) / elapsed
        return rate >= max(store.minHealthySpeed, 16 * 1024)
    }

    @discardableResult
    fileprivate func forceRefreshUpstreamOnStoreQueue() -> Bool {
        guard canRefreshUpstreamOnStoreQueue else { return false }
        beginRecoveryOnStoreQueue()
        cancelLookaheadOnStoreQueue()
        retryWork?.cancel()
        retryWork = nil
        stopStallTimerOnStoreQueue()
        if let running = task {
            store.detach(running)
            running.cancel()
            task = nil
        }
        yielded = false
        suspended = false
        retryCount = 0
        refusalWaits = 0
        let resumeAt = nextFetchOffset
        let gen = activeSeekGeneration

        if store.canRenew(forKey: streamKey),
           store.needsNewAddress(forKey: streamKey, failed: activeStream.url, ignoreCooldown: true) {
            store.note("进程内直连主动切换 115 下载线路（从 \(resumeAt) 字节续传）")
            requestRenewalOnStoreQueue(at: resumeAt, generation: gen, allowSameURL: true)
            return true
        }
        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url
        store.note("进程内直连重连上游节点（从 \(resumeAt) 字节续传）")
        launchChunkOnStoreQueue(from: resumeAt, generation: gen)
        return true
    }

    fileprivate func yieldUpstreamOnStoreQueue() {
        guard isActiveOnStoreQueue else { return }
        cancelLookaheadOnStoreQueue()
        retryWork?.cancel()
        retryWork = nil
        renewalID = nil
        stopStallTimerOnStoreQueue()
        if let running = task {
            store.detach(running)
            running.cancel()
            task = nil
        }
        suspended = false
        yielded = true
        store.note("进程内直连让出旧流（停在 \(nextFetchOffset) 字节）")
    }

    fileprivate func resumeAfterYieldOnStoreQueue() {
        guard yielded, !closedOnQueue else { return }
        yielded = false
        condition.lock()
        let isStillAlive = !cancelled && !closed && activeSeekGeneration == seekGeneration
        condition.unlock()
        guard isStillAlive else { return }
        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url
        launchChunkOnStoreQueue(from: nextFetchOffset, generation: activeSeekGeneration)
    }

    fileprivate func preemptClosedOnStoreQueue() {
        condition.lock()
        cancelled = true
        terminalError = true
        condition.broadcast()
        condition.unlock()
        cancelNetworkOnStoreQueue()
    }

    // MARK: 网络调度与分段滑动预取（store.queue）

    private func handleSeekResetOnStoreQueue(generation: UInt64) {
        guard !closedOnQueue else { return }
        activeSeekGeneration = generation
        cancelNetworkOnStoreQueue()
    }

    private func startOrAdoptUpstreamOnStoreQueue(offset: Int64, generation: UInt64) {
        guard !closedOnQueue else { return }
        condition.lock()
        let stale = cancelled || closed || generation != seekGeneration
        condition.unlock()
        guard !stale else { return }

        activeSeekGeneration = generation
        cancelNetworkOnStoreQueue()
        yielded = false
        retryCount = 0
        refusalWaits = 0
        nextFetchOffset = offset
        expectedChunkStart = offset
        currentChunkActualEnd = nil
        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url

        // 优先直接接管同起始偏移的在途预热任务，零重复建连
        if let prewarm = store.takeAdoptablePrewarm(forKey: streamKey, start: offset),
           let runningTask = prewarm.detachTaskForAdoption() {
            store.claimUpstream(for: self)
            redirectedURL = prewarm.url
            if prewarm.responseReceived, let meta = prewarm.meta {
                knownTotalOnQueue = meta.totalSize
                validator = meta.etag
                cachedContentType = meta.contentType
                cachedAcceptRanges = meta.acceptRanges
                cachedLastModified = meta.lastModified
                cachedSupportsRanges = meta.supportsRanges
                expectedChunkStart = prewarm.actualStart
                currentChunkActualEnd = prewarm.actualEnd
                nextFetchOffset = prewarm.actualStart + Int64(prewarm.bufferedData.count)
                deliveredSinceOpen += Int64(prewarm.bufferedData.count)

                condition.lock()
                if !cancelled && !closed && generation == seekGeneration {
                    totalSize = meta.totalSize
                    responseHeaderArrived = true
                    if !prewarm.bufferedData.isEmpty {
                        if streamBuffer.isEmpty { bufferStart = prewarm.actualStart }
                        streamBuffer.append(prewarm.bufferedData)
                    }
                    condition.broadcast()
                }
                condition.unlock()

                if nextFetchOffset > prewarm.actualEnd {
                    store.detach(runningTask)
                    runningTask.cancel()
                    advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: prewarm.actualEnd, generation: generation)
                    return
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            lastProgressUptime = now
            windowStartUptime = now
            windowBytes = 0
            task = runningTask
            store.reassignTask(runningTask, to: self)
            startStallTimerOnStoreQueue()
            return
        }

        launchChunkOnStoreQueue(from: offset, generation: generation)
    }

    private func launchChunkOnStoreQueue(from start: Int64, generation: UInt64) {
        guard !closedOnQueue, !yielded else { return }
        condition.lock()
        let stale = cancelled || closed || generation != seekGeneration
        condition.unlock()
        guard !stale else { return }

        if let total = knownTotalOnQueue, start >= total {
            markEOFOnStoreQueue(generation: generation)
            return
        }

        retryWork?.cancel()
        retryWork = nil
        suspended = false
        expectedChunkStart = start
        nextFetchOffset = start
        currentChunkActualEnd = nil

        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url

        var request = URLRequest(url: activeStream.url)
        request.httpMethod = "GET"
        for (name, value) in activeStream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if store.chunkSize > 0 {
            let chunkEnd: Int64
            if let total = knownTotalOnQueue, total > 0 {
                chunkEnd = min(total - 1, start + store.chunkSize - 1)
            } else {
                chunkEnd = start + store.chunkSize - 1
            }
            request.setValue("bytes=\(start)-\(chunkEnd)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }

        store.claimUpstream(for: self)
        let now = ProcessInfo.processInfo.systemUptime
        lastProgressUptime = now
        windowStartUptime = now
        windowBytes = 0
        task = store.startTask(request, for: self)
        startStallTimerOnStoreQueue()
    }

    private func maybeStartLookaheadOnStoreQueue(generation: UInt64) {
        guard !closedOnQueue, !yielded, !suspended,
              generation == activeSeekGeneration,
              lookahead == nil, renewalID == nil, retryWork == nil,
              let total = knownTotalOnQueue, total > 0,
              let chunkEnd = currentChunkActualEnd, chunkEnd < total - 1,
              !store.isLookaheadSuppressed(forKey: streamKey),
              store.chunkSize > 0, store.lookaheadTriggerRatio > 0, store.lookaheadTriggerRatio < 1 else {
            return
        }
        condition.lock()
        let buffered = streamBuffer.count
        condition.unlock()
        guard buffered < Self.resumeBytes else { return }

        let chunkLen = max(Int64(1), chunkEnd - expectedChunkStart + 1)
        let consumed = nextFetchOffset - expectedChunkStart
        guard Double(consumed) >= Double(chunkLen) * store.lookaheadTriggerRatio else { return }

        let nextStart = chunkEnd + 1
        let nextEnd = min(total - 1, nextStart + store.chunkSize - 1)
        guard nextEnd >= nextStart else { return }

        let stream = store.currentStream(forKey: streamKey, fallback: activeStream)
        var request = URLRequest(url: stream.url)
        request.httpMethod = "GET"
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(nextStart)-\(nextEnd)", forHTTPHeaderField: "Range")

        let maxBuffer = Int(min(Int64(24 * 1_048_576), max(store.chunkSize + 65_536, 4 * 1_048_576)))
        let transfer = Direct115LookaheadTransfer(
            streamKey: streamKey,
            url: stream.url,
            rangeStart: nextStart,
            rangeEnd: nextEnd,
            expectedTotal: knownTotalOnQueue,
            expectedValidator: validator,
            maxBufferBytes: maxBuffer,
            store: store
        )
        lookahead = transfer
        transfer.start(request: request)
    }

    private func advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: Int64, generation: UInt64) {
        guard !closedOnQueue, !yielded, generation == activeSeekGeneration else { return }
        if let total = knownTotalOnQueue, chunkEnd >= total - 1 {
            markEOFOnStoreQueue(generation: generation)
            return
        }
        let nextOffset = chunkEnd + 1

        if let la = lookahead {
            lookahead = nil
            if la.rangeStart == nextOffset && !la.failed {
                if la.responseReceived {
                    redirectedURL = la.url
                    expectedChunkStart = nextOffset
                    currentChunkActualEnd = la.actualEnd
                    if !la.bufferedData.isEmpty {
                        appendReceivedBytesOnStoreQueue(la.bufferedData, offset: nextOffset, generation: generation)
                    }
                    if let total = knownTotalOnQueue, nextFetchOffset >= total {
                        la.cancel()
                        markEOFOnStoreQueue(generation: generation)
                        return
                    }
                    if la.completed {
                        advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: la.actualEnd, generation: generation)
                        return
                    }
                    if let runningTask = la.detachTaskForAdoption() {
                        let now = ProcessInfo.processInfo.systemUptime
                        lastProgressUptime = now
                        windowStartUptime = now
                        windowBytes = 0
                        task = runningTask
                        store.reassignTask(runningTask, to: self)
                        applyBackpressureIfNeededOnStoreQueue()
                        startStallTimerOnStoreQueue()
                        maybeStartLookaheadOnStoreQueue(generation: generation)
                        return
                    }
                } else if let runningTask = la.detachTaskForAdoption() {
                    expectedChunkStart = nextOffset
                    nextFetchOffset = nextOffset
                    currentChunkActualEnd = nil
                    adoptedFromLookahead = true
                    let now = ProcessInfo.processInfo.systemUptime
                    lastProgressUptime = now
                    windowStartUptime = now
                    windowBytes = 0
                    task = runningTask
                    store.reassignTask(runningTask, to: self)
                    startStallTimerOnStoreQueue()
                    return
                }
            }
            la.cancel()
        }

        condition.lock()
        let buffered = streamBuffer.count
        condition.unlock()
        if buffered >= Self.pauseBytes {
            // 已有充足内存缓冲时先暂缓发起下一分段，待 mpv 消费回落再拉
            suspended = true
            return
        }
        launchChunkOnStoreQueue(from: nextOffset, generation: generation)
    }

    private func resumeIfSuspendedOnStoreQueue(generation: UInt64) {
        guard !closedOnQueue, !yielded, generation == activeSeekGeneration else { return }
        if suspended {
            suspended = false
            let now = ProcessInfo.processInfo.systemUptime
            lastProgressUptime = now
            windowStartUptime = now
            windowBytes = 0
            if let running = task {
                running.resume()
                maybeStartLookaheadOnStoreQueue(generation: generation)
            } else if retryWork == nil, renewalID == nil {
                launchChunkOnStoreQueue(from: nextFetchOffset, generation: generation)
            }
        } else {
            maybeStartLookaheadOnStoreQueue(generation: generation)
        }
    }

    private func applyBackpressureIfNeededOnStoreQueue() {
        condition.lock()
        let buffered = streamBuffer.count
        condition.unlock()
        if !suspended, buffered > Self.pauseBytes, let running = task {
            suspended = true
            running.suspend()
        }
    }

    private func appendReceivedBytesOnStoreQueue(_ data: Data, offset: Int64, generation: UInt64) {
        guard !data.isEmpty else { return }
        if let total = knownTotalOnQueue, total > 0 {
            let meta = StreamBlockCache.Metadata(
                totalSize: total,
                supportsRanges: cachedSupportsRanges,
                contentType: cachedContentType,
                etag: validator,
                lastModified: cachedLastModified,
                acceptRanges: cachedAcceptRanges
            )
            store.blockCache.record(key: streamKey, meta: meta, offset: offset, data: data, onlyPinRegion: true)
        }
        nextFetchOffset = offset + Int64(data.count)
        deliveredSinceOpen += Int64(data.count)
        if renewCount > 0, deliveredSinceOpen - renewProgressMark >= 65_536 {
            renewCount = 0
            refusalWaits = 0
        }

        condition.lock()
        if !cancelled && !closed && generation == seekGeneration {
            let dataEnd = offset + Int64(data.count)
            if dataEnd > cursor {
                let trimLeading = max(0, Int(cursor - offset))
                let effectiveStart = offset + Int64(trimLeading)
                let slice = trimLeading > 0 ? data.subdata(in: trimLeading..<data.count) : data
                if streamBuffer.isEmpty {
                    bufferStart = effectiveStart
                    streamBuffer.append(slice)
                } else if effectiveStart == bufferStart + Int64(streamBuffer.count) {
                    streamBuffer.append(slice)
                } else if effectiveStart == cursor {
                    bufferStart = effectiveStart
                    streamBuffer = Data(slice)
                }
                condition.broadcast()
            }
        }
        condition.unlock()
    }

    // MARK: Direct115TaskHandler（store.queue）

    fileprivate func didRedirect(to url: URL) {
        redirectedURL = url
    }

    fileprivate func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        guard !closedOnQueue, task === dataTask else { return false }
        guard let http = response as? HTTPURLResponse else {
            failTerminalOnStoreQueue("上游响应无效", generation: activeSeekGeneration)
            return false
        }
        lastProgressUptime = ProcessInfo.processInfo.systemUptime
        let gen = activeSeekGeneration
        let wasLookahead = adoptedFromLookahead
        adoptedFromLookahead = false

        if Direct115HTTPHelper.isRefused(status: http.statusCode), wasLookahead {
            store.suppressLookahead(forKey: streamKey, duration: 60)
            store.note("进程内直连接管的预取分段收到 HTTP \(http.statusCode)，降级为单连接并重拉 \(nextFetchOffset) 字节")
            store.detach(dataTask)
            task = nil
            stopStallTimerOnStoreQueue()
            launchChunkOnStoreQueue(from: nextFetchOffset, generation: gen)
            return false
        }

        if Direct115HTTPHelper.isRefused(status: http.statusCode),
           renewUpstreamOnStoreQueue("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）",
                                     cancelling: dataTask, resumeAt: nextFetchOffset, generation: gen) {
            return false
        }
        if Direct115HTTPHelper.isTransient(status: http.statusCode),
           scheduleRetryOnStoreQueue("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）",
                                     cancelling: dataTask, resumeAt: nextFetchOffset, generation: gen) {
            return false
        }

        if http.statusCode == 206, let range = Direct115HTTPHelper.contentRange(of: http),
           range.start == expectedChunkStart {
            let newTotal = Direct115HTTPHelper.totalLength(of: http)
            let newValidator = http.value(forHTTPHeaderField: "ETag")
            let sameSize = knownTotalOnQueue != nil && newTotal == knownTotalOnQueue
            let sameFile = validator == nil || newValidator == nil || validator == newValidator || sameSize
            guard sameFile else {
                store.blockCache.invalidate(key: streamKey)
                failTerminalOnStoreQueue("上游文件已变化（HTTP 206）", generation: gen)
                return false
            }
            if let newTotal, newTotal > 0 { knownTotalOnQueue = newTotal }
            if let newValidator { validator = newValidator }
            cachedContentType = http.value(forHTTPHeaderField: "Content-Type")
            cachedAcceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes"
            cachedLastModified = http.value(forHTTPHeaderField: "Last-Modified")
            cachedSupportsRanges = true
            currentChunkActualEnd = range.end

            condition.lock()
            if !cancelled && !closed && gen == seekGeneration {
                if let total = knownTotalOnQueue { totalSize = total }
                responseHeaderArrived = true
                condition.broadcast()
            }
            condition.unlock()
            return true
        }

        if http.statusCode == 200, expectedChunkStart == 0 {
            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            if let length, length > 0 {
                knownTotalOnQueue = length
                currentChunkActualEnd = length - 1
            }
            validator = http.value(forHTTPHeaderField: "ETag")
            cachedContentType = http.value(forHTTPHeaderField: "Content-Type")
            cachedAcceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")
            cachedLastModified = http.value(forHTTPHeaderField: "Last-Modified")
            cachedSupportsRanges = (cachedAcceptRanges ?? "").lowercased().contains("bytes")

            condition.lock()
            if !cancelled && !closed && gen == seekGeneration {
                if let total = knownTotalOnQueue { totalSize = total }
                responseHeaderArrived = true
                condition.broadcast()
            }
            condition.unlock()
            return true
        }

        store.note("进程内直连收到 HTTP \(http.statusCode)（\(http.url?.host ?? "")）")
        failTerminalOnStoreQueue("HTTP \(http.statusCode)", generation: gen)
        return false
    }

    fileprivate func didReceive(_ data: Data) {
        guard !closedOnQueue, task != nil, !data.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastProgressUptime = now
        lastReceivedBytesUptime = now
        windowBytes += Int64(data.count)
        if recentSampleStartUptime == 0 || now - recentSampleStartUptime >= 4.0 {
            recentSampleStartUptime = now
            recentSampleBytes = Int64(data.count)
        } else {
            recentSampleBytes += Int64(data.count)
        }

        let gen = activeSeekGeneration
        let offset = nextFetchOffset
        appendReceivedBytesOnStoreQueue(data, offset: offset, generation: gen)
        applyBackpressureIfNeededOnStoreQueue()
        maybeStartLookaheadOnStoreQueue(generation: gen)
    }

    fileprivate func didComplete(_ error: Error?) {
        task = nil
        stopStallTimerOnStoreQueue()
        guard !closedOnQueue else { return }
        let gen = activeSeekGeneration

        if let error {
            if let total = knownTotalOnQueue, nextFetchOffset >= total {
                markEOFOnStoreQueue(generation: gen)
                return
            }
            let detail = "进程内直连上游失败：\(LocalStreamProxy.summary(of: error))（\(redirectedURL.host ?? "")），已收 \(deliveredSinceOpen) 字节"
            if Direct115HTTPHelper.isTransient(error),
               scheduleRetryOnStoreQueue(detail, cancelling: nil, resumeAt: nextFetchOffset, generation: gen) {
                return
            }
            failTerminalOnStoreQueue(detail, generation: gen)
            return
        }

        if let total = knownTotalOnQueue, nextFetchOffset >= total {
            markEOFOnStoreQueue(generation: gen)
            return
        }
        if let chunkEnd = currentChunkActualEnd, nextFetchOffset == chunkEnd + 1 {
            retryCount = 0
            refusalWaits = 0
            retryProgressMark = deliveredSinceOpen
            advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: chunkEnd, generation: gen)
            return
        }
        if knownTotalOnQueue == nil {
            markEOFOnStoreQueue(generation: gen)
            return
        }
        if scheduleRetryOnStoreQueue("进程内直连上游提前结束（停在 \(nextFetchOffset) 字节）", cancelling: nil, resumeAt: nextFetchOffset, generation: gen) {
            return
        }
        failTerminalOnStoreQueue("上游提前结束传输", generation: gen)
    }

    // MARK: 停滞、重试、换链（store.queue）

    private func startStallTimerOnStoreQueue() {
        stopStallTimerOnStoreQueue()
        let timeout = store.stallTimeout
        guard timeout > 0 else { return }
        let interval = max(0.05, min(1.0, timeout / 2.0))
        let timer = DispatchSource.makeTimerSource(queue: store.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkStallOnStoreQueue() }
        stallTimer = timer
        timer.resume()
    }

    private func stopStallTimerOnStoreQueue() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkStallOnStoreQueue() {
        guard !closedOnQueue, !yielded, !suspended, let running = task else { return }
        let now = ProcessInfo.processInfo.systemUptime
        condition.lock()
        let buffered = streamBuffer.count
        condition.unlock()
        if buffered >= Self.resumeBytes {
            lastProgressUptime = now
            windowStartUptime = now
            windowBytes = 0
            return
        }
        let silentFor = now - lastProgressUptime
        var stalledReason: String?
        if silentFor >= store.stallTimeout {
            stalledReason = "进程内直连上游 \(String(format: "%.1f", silentFor)) 秒无响应（\(redirectedURL.host ?? "")）"
        } else if store.minHealthySpeed > 0, windowBytes > 0 {
            let elapsed = now - windowStartUptime
            let slowWindow = max(store.stallTimeout + 4.0, 16.0)
            if elapsed >= slowWindow {
                let speed = Double(windowBytes) / elapsed
                if speed < store.minHealthySpeed {
                    stalledReason = "进程内直连上游过慢（\(Int(speed / 1024)) KB/s）"
                } else {
                    windowStartUptime = now
                    windowBytes = 0
                }
            }
        }
        guard let reason = stalledReason else { return }
        stopStallTimerOnStoreQueue()
        store.detach(running)
        running.cancel()
        task = nil
        let gen = activeSeekGeneration

        if retryCount >= 2, store.canRenew(forKey: streamKey),
           store.needsNewAddress(forKey: streamKey, failed: activeStream.url, ignoreCooldown: true),
           renewUpstreamOnStoreQueue(reason, cancelling: nil, resumeAt: nextFetchOffset, generation: gen, ignoreCooldown: true) {
            return
        }
        if scheduleRetryOnStoreQueue(reason, cancelling: nil, resumeAt: nextFetchOffset, generation: gen) { return }
        failTerminalOnStoreQueue(reason, generation: gen)
    }

    private func beginRecoveryOnStoreQueue() {
        if let recoveryWindow, deliveredSinceOpen - recoveryWindow.bytes < 65_536 { return }
        recoveryWindow = (ProcessInfo.processInfo.systemUptime + Direct115StreamStore.recoveryGrace, deliveredSinceOpen)
    }

    private func scheduleRetryOnStoreQueue(_ detail: String, cancelling running: URLSessionDataTask?, resumeAt: Int64, generation: UInt64) -> Bool {
        if deliveredSinceOpen > retryProgressMark {
            retryCount = 0
            retryProgressMark = deliveredSinceOpen
        }
        let delays = store.retryDelays
        guard retryCount < delays.count else {
            store.note("\(detail)；重试 \(delays.count) 次均未成功")
            return false
        }
        let delay = delays[retryCount]
        retryCount += 1
        beginRecoveryOnStoreQueue()
        cancelLookaheadOnStoreQueue()
        store.note("\(detail)；\(delay) 秒后第 \(retryCount) 次重试，从 \(resumeAt) 字节接着下")
        if let running { store.detach(running) }
        task = nil
        stopStallTimerOnStoreQueue()
        let work = DispatchWorkItem { [weak self] in
            self?.launchChunkOnStoreQueue(from: resumeAt, generation: generation)
        }
        retryWork = work
        store.queue.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    private func renewUpstreamOnStoreQueue(
        _ detail: String,
        cancelling running: URLSessionDataTask?,
        resumeAt: Int64,
        generation: UInt64,
        ignoreCooldown: Bool = false
    ) -> Bool {
        guard store.canRenew(forKey: streamKey) else { return false }
        let shouldRenew = renewCount < 2 && store.needsNewAddress(forKey: streamKey, failed: activeStream.url, ignoreCooldown: ignoreCooldown)
        let waits = store.refusalDelays
        guard shouldRenew || refusalWaits < waits.count else {
            store.note("\(detail)；换地址、等待重试均未成功")
            return false
        }
        beginRecoveryOnStoreQueue()
        cancelLookaheadOnStoreQueue()
        if let running { store.detach(running) }
        task = nil
        stopStallTimerOnStoreQueue()
        store.claimUpstream(for: self)

        if shouldRenew {
            renewCount += 1
            renewProgressMark = deliveredSinceOpen
            store.note("\(detail)，换新地址后从 \(resumeAt) 字节接着下")
            requestRenewalOnStoreQueue(at: resumeAt, generation: generation, allowSameURL: false)
        } else {
            let delay = waits[refusalWaits]
            refusalWaits += 1
            store.note("\(detail)；新地址仍被拒，\(delay) 秒后从 \(resumeAt) 字节重试")
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.closedOnQueue else { return }
                self.launchChunkOnStoreQueue(from: resumeAt, generation: generation)
            }
            retryWork = work
            store.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        return true
    }

    private func requestRenewalOnStoreQueue(at offset: Int64, generation: UInt64, allowSameURL: Bool) {
        let id = UUID()
        renewalID = id
        store.renew(forKey: streamKey, failed: activeStream.url) { [weak self] fresh in
            guard let self, !self.closedOnQueue, self.renewalID == id, generation == self.activeSeekGeneration else { return }
            self.renewalID = nil
            if let fresh {
                self.activeStream = fresh
                self.redirectedURL = fresh.url
            } else if !allowSameURL {
                self.failTerminalOnStoreQueue("115 换链失败", generation: generation)
                return
            }
            self.launchChunkOnStoreQueue(from: offset, generation: generation)
        }
    }

    private func markEOFOnStoreQueue(generation: UInt64) {
        condition.lock()
        if generation == seekGeneration {
            eofReached = true
            responseHeaderArrived = true
            condition.broadcast()
        }
        condition.unlock()
    }

    private func failTerminalOnStoreQueue(_ reason: String, generation: UInt64) {
        store.note(reason)
        condition.lock()
        if generation == seekGeneration {
            terminalError = true
            condition.broadcast()
        }
        condition.unlock()
    }

    private func cancelLookaheadOnStoreQueue() {
        adoptedFromLookahead = false
        lookahead?.cancel()
        lookahead = nil
    }

    private func cancelNetworkOnStoreQueue() {
        renewalID = nil
        retryWork?.cancel()
        retryWork = nil
        suspended = false
        stopStallTimerOnStoreQueue()
        cancelLookaheadOnStoreQueue()
        if let running = task {
            store.detach(running)
            running.cancel()
            task = nil
        }
    }

    private func teardownOnStoreQueue() {
        guard !closedOnQueue else { return }
        closedOnQueue = true
        yielded = false
        cancelNetworkOnStoreQueue()
        store.handleClosed(self)
    }
}

/// 剧集详情页与自动连播提前预解析 / 预热 115 原画直链的统一入口。
enum Direct115Prewarmer {
    /// 提前解析 115 原画直链（进入 15 分钟会话缓存）；`prefetchBytes` 为 true 时同时后台预热片头与尾部索引。
    static func prewarm(
        client: Direct115Client,
        pickCode: String,
        resume: Bool,
        prefetchBytes: Bool
    ) async {
        guard !pickCode.isEmpty else { return }
        do {
            let stream = try await client.originalStream(pickCode: pickCode, useCache: true)
            guard !Task.isCancelled, prefetchBytes else { return }
            Direct115StreamStore.shared.prewarm(
                stream: stream,
                streamID: "p115:\(pickCode)",
                resume: resume,
                renew: { try await client.originalStream(pickCode: pickCode, useCache: false) }
            )
        } catch {
            // 预热静默失败，不影响真正点击播放时的正常解析与报错
        }
    }
}
