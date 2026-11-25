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
    /// 预热第一步拉的片头：足够判断 MP4 moov / MKV Cues 在哪。整段收完再走下一步，不中途取消，连接能复用
    static let headProbeBytes: Int64 = 256 * 1024
    /// 非续播时预热的片头总量：起播的第一批画面直接从内存出
    static let headWarmBytes: Int64 = 2 * 1_048_576
    /// 读位置落在预热传输已收到位置之后这么近时，直接等它下过来（或接管它），不另起请求
    static let prewarmFollowGapBytes: Int64 = 2 * 1_048_576
    /// 播放连接在等某段预热数据时，预热这么久没有任何进展就不等了，改由播放连接自己拉
    static let prewarmStallSeconds: TimeInterval = 6.0

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

    /// 拿到 115 原画直链后立即在后台预热，分三步依次进行（每步都是完整收完的小范围请求，连接可复用）：
    /// 1. 片头探测段（256 KiB）；2. 尾部索引（MP4 `moov` / MKV `Cues`，在片尾时才拉）；3. 片头续段到 2 MiB（仅非续播）。
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
                self.prewarms.removeValue(forKey: otherKey)
                other.cancel()
            }
            let hasActive = self.handles.values.contains { $0.streamKey == key && $0.isActiveOnStoreQueue }
            guard !hasActive, self.prewarms[key] == nil else { return }
            self.startNextPrewarmStep(
                key: key,
                stream: self.currentStream(forKey: key, fallback: stream),
                resume: resume,
                indexOnly: false
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

    func activePrewarmRangeForTesting(streamKey: String) -> (start: Int64, end: Int64)? {
        queue.sync { prewarms[streamKey].map { ($0.rangeStart, $0.rangeEnd) } }
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

    /// 播放连接开始自己拉数据：停掉同一条流的片头类预热（会抢带宽），
    /// 尾部索引预热保留——mpv 打开时马上就要读它。
    fileprivate func claimUpstream(for handle: Direct115StreamHandle) {
        let key = handle.streamKey
        if let transfer = prewarms[key], transfer.kind != .tailIndex {
            prewarms.removeValue(forKey: key)
            transfer.cancel()
        }
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

    /// 正在拉、并且很快就能拉到 `offset` 的预热传输
    fileprivate func prewarmCovering(forKey key: String, offset: Int64) -> Direct115PrewarmTransfer? {
        guard let transfer = prewarms[key], transfer.covers(offset) else { return nil }
        return transfer
    }

    fileprivate func takeAdoptablePrewarm(forKey key: String, offset: Int64) -> Direct115PrewarmTransfer? {
        guard let transfer = prewarmCovering(forKey: key, offset: offset) else { return nil }
        prewarms.removeValue(forKey: key)
        return transfer
    }

    fileprivate func cancelPrewarm(_ transfer: Direct115PrewarmTransfer) {
        if prewarms[transfer.key] === transfer {
            prewarms.removeValue(forKey: transfer.key)
        }
        transfer.cancel()
    }

    fileprivate func prewarmDidFinish(_ transfer: Direct115PrewarmTransfer, completed: Bool) {
        guard prewarms[transfer.key] === transfer else { return }
        prewarms.removeValue(forKey: transfer.key)
        guard completed else { return }
        // 播放连接已经在拉数据时只补尾部索引，片头由它自己读
        let hasActive = handles.values.contains { $0.streamKey == transfer.key && $0.isActiveOnStoreQueue }
        startNextPrewarmStep(
            key: transfer.key,
            stream: currentStream(forKey: transfer.key, fallback: transfer.stream),
            resume: transfer.resume,
            indexOnly: hasActive
        )
    }

    /// 播放连接收到片头后调用：索引在片尾时，并行把尾部索引拉进块缓存（mpv 读完头部马上就要跳过去）。
    /// 返回 false 表示片头数据还不够判断，之后再试。
    fileprivate func ensureIndexPrefetch(forKey key: String, fallback: Direct115ResolvedStream) -> Bool {
        guard let head = blockCache.lookup(
            key: key,
            start: 0,
            requestedEnd: Self.headProbeBytes - 1,
            maxReturnBytes: Int(Self.headProbeBytes)
        ) else { return false }
        guard head.data.count >= 65_536 || Int64(head.data.count) >= head.meta.totalSize else { return false }
        guard prewarms[key] == nil else { return true }
        startNextPrewarmStep(key: key, stream: currentStream(forKey: key, fallback: fallback), resume: true, indexOnly: true)
        return true
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

    /// 按「片头探测段 → 尾部索引 → 片头续段」的顺序找出下一段还没缓存的数据并开始预热。
    /// `indexOnly`：播放连接正在拉数据，只允许补尾部索引（另一条连接），不和它抢片头。
    private func startNextPrewarmStep(key: String, stream: Direct115ResolvedStream, resume: Bool, indexOnly: Bool) {
        guard prewarms[key] == nil else { return }
        let headEnd = Self.headProbeBytes - 1
        if !indexOnly, let missing = missingCacheRange(forKey: key, start: 0, end: headEnd) {
            startPrewarmTransfer(key: key, stream: stream, kind: .head, start: missing.start, end: missing.end, resume: resume)
            return
        }
        if indexOnly && isLookaheadSuppressed(forKey: key) { return }
        if let tail = tailIndexRange(forKey: key),
           let missing = missingCacheRange(forKey: key, start: tail.start, end: tail.end) {
            startPrewarmTransfer(key: key, stream: stream, kind: .tailIndex, start: missing.start, end: missing.end, resume: resume)
            return
        }
        guard !indexOnly, !resume, let meta = blockCache.metadata(forKey: key), meta.totalSize > 0 else { return }
        let warmEnd = min(meta.totalSize - 1, Self.headWarmBytes - 1)
        if warmEnd > headEnd, let missing = missingCacheRange(forKey: key, start: headEnd + 1, end: warmEnd) {
            startPrewarmTransfer(key: key, stream: stream, kind: .headWarm, start: missing.start, end: missing.end, resume: resume)
        }
    }

    /// 用已缓存的片头判断容器索引是否在片尾，返回要预取的尾部区间
    private func tailIndexRange(forKey key: String) -> (start: Int64, end: Int64)? {
        guard let head = blockCache.lookup(
            key: key,
            start: 0,
            requestedEnd: Self.headProbeBytes - 1,
            maxReturnBytes: Int(Self.headProbeBytes)
        ) else { return nil }
        if case .indexAtTail(let start, let end, _) = ContainerIndexProbe.inspect(prefix: head.data, totalSize: head.meta.totalSize) {
            return (start, end)
        }
        return nil
    }

    private func startPrewarmTransfer(
        key: String,
        stream: Direct115ResolvedStream,
        kind: Direct115PrewarmTransfer.Kind,
        start: Int64,
        end: Int64,
        resume: Bool
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
            kind: kind,
            rangeStart: start,
            rangeEnd: end,
            resume: resume,
            store: self
        )
        prewarms[key] = transfer
        transfer.start(request: request)
    }

    private func missingCacheRange(forKey key: String, start: Int64, end: Int64) -> (start: Int64, end: Int64)? {
        guard end >= start else { return nil }
        guard let hit = blockCache.lookup(key: key, start: start, requestedEnd: end, maxReturnBytes: Int(end - start + 1)) else {
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

// MARK: - 分块字节窗口

/// 进程内直连的分块字节窗口：保存 `[start, end)` 这段连续字节（含少量已读回看区）。
/// 追加时不拷贝，已读数据按整块释放，内存只和窗口里的字节数有关。
/// 不能用 `Data.removeFirst` 做 FIFO：它只是切片，被"移除"的前缀仍占着底层存储，
/// 之后的追加还会接着往同一块存储后面长，一条流读多久就攒多久。
struct DirectStreamBuffer {
    private var chunks: [Data] = []
    private var head = 0
    private var headSkip = 0
    private(set) var start: Int64 = 0
    private(set) var count = 0

    var end: Int64 { start + Int64(count) }
    var isEmpty: Bool { count == 0 }
    /// 仍被窗口持有的数据块个数（测试用：确认已读数据确实释放了）
    var retainedChunkCount: Int { chunks.count - head }

    func contains(_ offset: Int64) -> Bool {
        offset >= start && offset < end
    }

    mutating func reset(at offset: Int64) {
        chunks.removeAll(keepingCapacity: true)
        head = 0
        headSkip = 0
        count = 0
        start = offset
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        count += data.count
    }

    /// 从绝对偏移 `offset` 起最多拷贝 `maxBytes` 字节，可跨多个数据块；不改变窗口
    func copy(from offset: Int64, into destination: UnsafeMutableRawPointer, maxBytes: Int) -> Int {
        guard maxBytes > 0, contains(offset) else { return 0 }
        var skip = headSkip + Int(offset - start)
        var written = 0
        var index = head
        while index < chunks.count, written < maxBytes {
            let chunk = chunks[index]
            index += 1
            if skip >= chunk.count {
                skip -= chunk.count
                continue
            }
            let take = min(chunk.count - skip, maxBytes - written)
            let from = skip
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(destination.advanced(by: written), base.advanced(by: from), take)
            }
            written += take
            skip = 0
        }
        return written
    }

    /// 丢掉 `offset` 之前的数据（不会越过窗口末尾，保证后续追加仍然连续）
    mutating func trimFront(to offset: Int64) {
        let target = min(offset, end)
        guard target > start else { return }
        if target == end {
            reset(at: end)
            return
        }
        var drop = Int(target - start)
        start = target
        count -= drop
        while drop > 0 {
            let available = chunks[head].count - headSkip
            if drop >= available {
                drop -= available
                chunks[head] = Data()
                head += 1
                headSkip = 0
            } else {
                headSkip += drop
                drop = 0
            }
        }
        if head >= 64, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
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

private struct WeakStreamHandle {
    weak var handle: Direct115StreamHandle?
}

/// 进程内直连预热传输：拉一段固定范围写入共享块缓存。
/// 播放连接需要的位置正好在这段里时，可以直接接管它的连接，或者等它把数据下进缓存。
private final class Direct115PrewarmTransfer: Direct115TaskHandler {
    enum Kind {
        /// 片头探测段
        case head
        /// 尾部索引（MP4 moov / MKV Cues）
        case tailIndex
        /// 片头续段（非续播起播用）
        case headWarm
    }

    let key: String
    let stream: Direct115ResolvedStream
    let kind: Kind
    var url: URL
    let rangeStart: Int64
    let rangeEnd: Int64
    let resume: Bool
    private weak var store: Direct115StreamStore?

    private(set) var task: URLSessionDataTask?
    private(set) var responseReceived = false
    private(set) var meta: StreamBlockCache.Metadata?
    private(set) var actualStart: Int64 = 0
    private(set) var actualEnd: Int64 = 0
    private(set) var bufferedData = Data()
    private(set) var lastActivityUptime = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var waiters: [ObjectIdentifier: WeakStreamHandle] = [:]

    init(
        key: String,
        stream: Direct115ResolvedStream,
        kind: Kind,
        rangeStart: Int64,
        rangeEnd: Int64,
        resume: Bool,
        store: Direct115StreamStore
    ) {
        self.key = key
        self.stream = stream
        self.kind = kind
        self.url = stream.url
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.resume = resume
        self.store = store
    }

    /// 已经连续收到哪里（还没收到响应时就是起点）
    var receivedEnd: Int64 {
        responseReceived ? actualStart + Int64(bufferedData.count) : rangeStart
    }

    /// `offset` 在这段范围内，并且离已收到的位置不远：等它或接管它都比另起请求快
    func covers(_ offset: Int64) -> Bool {
        guard !finished, task != nil, offset >= rangeStart, offset <= rangeEnd else { return false }
        if responseReceived && (meta == nil || actualStart != rangeStart) { return false }
        return offset <= receivedEnd + Direct115StreamStore.prewarmFollowGapBytes
    }

    func start(request: URLRequest) {
        guard let store, !finished else { return }
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        task = store.startTask(request, for: self)
    }

    func addWaiter(_ handle: Direct115StreamHandle) {
        waiters[ObjectIdentifier(handle)] = WeakStreamHandle(handle: handle)
    }

    func removeWaiter(_ handle: Direct115StreamHandle) {
        waiters.removeValue(forKey: ObjectIdentifier(handle))
    }

    func detachTaskForAdoption() -> URLSessionDataTask? {
        finished = true
        let running = task
        task = nil
        endWaiters()
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
        endWaiters()
    }

    func didRedirect(to url: URL) {
        self.url = url
    }

    func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        guard !finished, let http = response as? HTTPURLResponse else {
            finish(completed: false)
            return false
        }
        if Direct115HTTPHelper.isRefused(status: http.statusCode) {
            // 115 不让多开连接时，播放期间不再另开连接补索引
            store?.suppressLookahead(forKey: key, duration: 60)
        }
        guard http.statusCode == 206,
              let range = Direct115HTTPHelper.contentRange(of: http),
              range.start == rangeStart,
              let total = Direct115HTTPHelper.totalLength(of: http), total > 0 else {
            finish(completed: false)
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
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        store.blockCache.record(key: key, meta: meta, offset: offset, data: data)
        for waiter in waiters.values {
            waiter.handle?.prewarmDataArrivedOnStoreQueue()
        }
    }

    func didComplete(_ error: Error?) {
        task = nil
        guard !finished else { return }
        finish(completed: error == nil)
    }

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        if let task {
            store?.detach(task)
            task.cancel()
            self.task = nil
        }
        endWaiters()
        store?.prewarmDidFinish(self, completed: completed)
    }

    private func endWaiters() {
        let list = waiters.values.compactMap(\.handle)
        waiters.removeAll()
        list.forEach { $0.prewarmWaitEndedOnStoreQueue(self) }
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
/// - 网络任务与重试/换链/预取全部运行在 `store.queue` 上，严格遵循单向锁顺序（队列 → condition）杜绝死锁。
///
/// 跳转是"懒"的：`seek` 只移动读位置，不立刻取消正在下载的上游。mpv 打开文件时常在片头和片尾索引之间
/// 来回跳（MP4 moov / MKV Tags、Cues），片尾多半已经在块缓存里；等它跳回片头时，原来那条连接还在、
/// 窗口里的数据也还在，直接接着读，不用重新建连。只有读线程真的需要网络数据、而当前这条流又够不着时，
/// 队列才在新位置重新起流。
final class Direct115StreamHandle: Direct115TaskHandler, @unchecked Sendable {
    private static let pauseBytes = 8 * 1_048_576
    private static let resumeBytes = 2 * 1_048_576
    /// 已读过的数据保留这么多，mpv 小幅回跳直接从内存出
    static let backWindowBytes: Int64 = 1_048_576
    /// 读位置在当前流下载位置前方这么近时，直接等这条流下过来，不另起请求
    static let followGapBytes: Int64 = 1_048_576
    /// 收到这么多片头字节后检查容器索引位置，必要时另开连接预取尾部索引
    private static let indexProbeTriggerBytes: Int64 = 65_536

    let token: String
    let streamKey: String
    let hasExplicitStreamID: Bool
    let generation: Int
    let serial: Int
    private unowned let store: Direct115StreamStore

    // MARK: 跨线程共享状态（由 `condition` 保护，只做微秒级内存操作）
    private let condition = NSCondition()
    private var cursor: Int64 = 0
    private var buffer = DirectStreamBuffer()
    private var totalSize: Int64?
    private var responseHeaderArrived = false
    /// 当前上游流在 `buffer.end` 处已到文件尾
    private var streamEOF = false
    /// 当前上游流在读线程跟着它读的时候彻底失败了
    private var streamFailed = false
    /// 当前上游流还会继续往 `buffer.end` 后面送数据（下载中、暂停待续、重试或换链中）
    private var upstreamActive = false
    /// 上游停下、出错、到尾或等待的预热结束时递增；读线程据此重新向队列请求数据
    private var upstreamEpoch: UInt64 = 0
    private var lastNeedOffset: Int64 = -1
    private var lastNeedEpoch: UInt64 = .max
    private var cancelled = false
    private var closed = false

    // MARK: 网络状态（仅在 `store.queue` 上读写）
    private var activeStream: Direct115ResolvedStream
    private var redirectedURL: URL
    /// 每次在新位置重新起流时递增，过期的重试、换链回调据此丢弃
    private var streamSerial: UInt64 = 0
    private var task: URLSessionDataTask?
    private var lookahead: Direct115LookaheadTransfer?
    private var adoptedFromLookahead = false
    private var suspended = false
    private var yielded = false
    private var closedOnQueue = false
    private var waitingPrewarm: Direct115PrewarmTransfer?
    private var indexPrefetchChecked = false
    private var indexProbeTriedOnNeed = false
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
    private var speedWindowStartUptime: TimeInterval = 0
    private var speedWindowBytes: Int64 = 0

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
        let target = UnsafeMutableRawPointer(destination)
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

            // 路径 1：命中内存窗口
            if buffer.contains(cursor) {
                let copied = buffer.copy(from: cursor, into: target, maxBytes: maxBytes)
                cursor += Int64(copied)
                buffer.trimFront(to: cursor - Self.backWindowBytes)
                let lowWater = aheadBytesLocked < Self.resumeBytes
                condition.unlock()
                if lowWater { nudgeUpstream() }
                return Int64(copied)
            }

            // 路径 2：直接命中共享头尾/热点块缓存（MP4 moov / MKV Cues / 刚预热的片头毫秒返回）
            let queryOffset = cursor
            let cacheLimit = min(maxBytes, 1_048_576)
            condition.unlock()
            let hit = store.blockCache.lookup(
                key: streamKey,
                start: queryOffset,
                requestedEnd: queryOffset + Int64(cacheLimit) - 1,
                maxReturnBytes: cacheLimit
            )
            condition.lock()
            if cancelled || closed {
                condition.unlock()
                return -1
            }
            // 查缓存期间读位置被改了：重新来
            guard cursor == queryOffset else { continue }
            if let hit, !hit.data.isEmpty {
                if totalSize == nil, hit.meta.totalSize > 0 {
                    totalSize = hit.meta.totalSize
                }
                let copyCount = min(maxBytes, hit.data.count)
                hit.data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    memcpy(target, base, copyCount)
                }
                cursor += Int64(copyCount)
                condition.unlock()
                return Int64(copyCount)
            }
            if buffer.contains(cursor) { continue }
            if let total = totalSize, cursor >= total {
                condition.unlock()
                return 0
            }

            // 路径 3：读位置就在当前流前方时等它下过来；否则请队列在这个位置拉取
            if !upstreamActive && isAtStreamEdgeLocked {
                if streamEOF {
                    condition.unlock()
                    return 0
                }
                if streamFailed {
                    condition.unlock()
                    return -1
                }
            }
            requestUpstreamIfNeededLocked()
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
        cursor = offset
        var lowWater = false
        if offset >= buffer.start && offset <= buffer.end {
            // 窗口内（含回看区）：直接移动读位置，零网络中断
            buffer.trimFront(to: offset - Self.backWindowBytes)
            lowWater = aheadBytesLocked < Self.resumeBytes
        }
        // 窗口外：先不动上游，真正需要网络数据时再由队列决定接着用还是换位置
        condition.unlock()
        if lowWater { nudgeUpstream() }
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
            if cancelled || closed || responseHeaderArrived || (streamFailed && !upstreamActive) {
                condition.unlock()
                return Int64(MPV_ERROR_UNSUPPORTED.rawValue)
            }
            requestUpstreamIfNeededLocked()
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
        buffer = DirectStreamBuffer()
        condition.broadcast()
        condition.unlock()
        store.queue.async { [weak self] in
            self?.teardownOnStoreQueue()
        }
    }

    // MARK: 读线程辅助（需持有 condition）

    /// 读位置前方已经缓冲好的字节；读位置在窗口后面时为 0（不能暂停，流得追上来）
    private var aheadBytesLocked: Int {
        if cursor >= buffer.start && cursor <= buffer.end { return Int(buffer.end - cursor) }
        if cursor > buffer.end { return 0 }
        return buffer.count
    }

    /// 读线程正跟着当前这条流读（在窗口里，或就在它前方不远）
    private var readerFollowsLocked: Bool {
        cursor >= buffer.start && cursor <= buffer.end + Self.followGapBytes
    }

    /// 读位置就在流的下载位置上或前方不远：等这条流下过来即可
    private var isAtStreamEdgeLocked: Bool {
        cursor >= buffer.end && cursor <= buffer.end + Self.followGapBytes
    }

    private func requestUpstreamIfNeededLocked() {
        guard lastNeedOffset != cursor || lastNeedEpoch != upstreamEpoch else { return }
        lastNeedOffset = cursor
        lastNeedEpoch = upstreamEpoch
        let offset = cursor
        store.queue.async { [weak self] in
            self?.serveNeedOnStoreQueue(offset: offset)
        }
    }

    private func nudgeUpstream() {
        store.queue.async { [weak self] in
            self?.resumeIfNeededOnStoreQueue()
        }
    }

    /// 把一段上游数据接到窗口末尾；与窗口不连续的部分直接丢弃
    @discardableResult
    private func enqueueLocked(_ data: Data, at offset: Int64) -> Bool {
        let dataEnd = offset + Int64(data.count)
        guard offset <= buffer.end, dataEnd > buffer.end else { return false }
        let skip = Int(buffer.end - offset)
        buffer.append(skip == 0 ? data : data[(data.startIndex + skip)...])
        return true
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
        if suspended || retryWork != nil || waitingPrewarm != nil { return true }
        condition.lock()
        let buffered = aheadBytesLocked
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
        let serial = streamSerial

        if store.canRenew(forKey: streamKey),
           store.needsNewAddress(forKey: streamKey, failed: activeStream.url, ignoreCooldown: true) {
            store.note("进程内直连主动切换 115 下载线路（从 \(resumeAt) 字节续传）")
            requestRenewalOnStoreQueue(at: resumeAt, serial: serial, allowSameURL: true)
            return true
        }
        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url
        store.note("进程内直连重连上游节点（从 \(resumeAt) 字节续传）")
        launchChunkOnStoreQueue(from: resumeAt, serial: serial)
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
        // 读线程按自己当前的读位置重新请求：多半就在原窗口末尾接着拉
        goIdleOnStoreQueue()
    }

    fileprivate func preemptClosedOnStoreQueue() {
        condition.lock()
        cancelled = true
        streamFailed = true
        condition.broadcast()
        condition.unlock()
        cancelNetworkOnStoreQueue()
    }

    /// 等待中的预热传输收到了新数据（已写进块缓存）：叫醒读线程去缓存里取
    fileprivate func prewarmDataArrivedOnStoreQueue() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// 等待中的预热传输结束（收完、失败或被取消）：读线程按当前位置重新请求
    fileprivate func prewarmWaitEndedOnStoreQueue(_ transfer: Direct115PrewarmTransfer) {
        guard waitingPrewarm === transfer else { return }
        waitingPrewarm = nil
        bumpEpochOnStoreQueue()
    }

    // MARK: 网络调度（store.queue）

    /// 读线程在 `offset` 处既没有窗口数据也没有缓存，要网络数据
    private func serveNeedOnStoreQueue(offset requested: Int64) {
        guard !closedOnQueue else { return }
        condition.lock()
        let stale = cancelled || closed || cursor != requested
        let inWindow = buffer.contains(requested)
        let atEdge = isAtStreamEdgeLocked
        let windowEnd = buffer.end
        let windowHasData = !buffer.isEmpty
        let streamDone = streamEOF || streamFailed
        condition.unlock()
        // 读位置已经换了：读线程会按新位置重新请求
        guard !stale else { return }
        if inWindow || store.blockCache.lookup(key: streamKey, start: requested, requestedEnd: requested, maxReturnBytes: 1) != nil {
            wakeReaderOnStoreQueue()
            return
        }
        // 让出上游期间不抢；恢复时会叫醒读线程重新请求
        guard !yielded else { return }
        if !indexPrefetchChecked && !indexProbeTriedOnNeed {
            // 片头已在缓存里（比如详情页预热过）时这里就能判断；否则等这条流收到片头再判断
            indexProbeTriedOnNeed = true
            indexPrefetchChecked = store.ensureIndexPrefetch(forKey: streamKey, fallback: activeStream)
        }

        // 1. 读位置就在当前流前方：接着用这条流
        if atEdge && !streamDone {
            if task != nil || retryWork != nil || renewalID != nil {
                if suspended { resumeIfNeededOnStoreQueue() }
                return
            }
            if streamSerial > 0, nextFetchOffset == windowEnd {
                // 分段收完后停在这里（读线程曾离开）：在窗口末尾接着拉，已缓冲的数据都保留。
                // 刚打开、还没起过流时不走这里，让下面优先接管预热
                suspended = false
                launchChunkOnStoreQueue(from: windowEnd, serial: streamSerial)
                return
            }
        }

        // 2. 预热传输正在拉这一段：手里有数据或连接就留着，等预热把数据下进缓存
        if let prewarm = store.prewarmCovering(forKey: streamKey, offset: requested),
           windowHasData || task != nil || retryWork != nil || renewalID != nil {
            beginPrewarmWaitOnStoreQueue(prewarm)
            return
        }

        // 3. 其他位置：在这里重新起流（能接管预热就接管）
        restartOnStoreQueue(at: requested)
    }

    private func beginPrewarmWaitOnStoreQueue(_ prewarm: Direct115PrewarmTransfer) {
        if waitingPrewarm !== prewarm {
            waitingPrewarm?.removeWaiter(self)
            waitingPrewarm = prewarm
            prewarm.addWaiter(self)
            schedulePrewarmWaitCheckOnStoreQueue(prewarm)
        }
        // 把带宽让给正在拉的这一段；读线程回到这条流时再续上
        cancelLookaheadOnStoreQueue()
        if let running = task, !suspended {
            suspended = true
            running.suspend()
        }
    }

    private func schedulePrewarmWaitCheckOnStoreQueue(_ prewarm: Direct115PrewarmTransfer) {
        store.queue.asyncAfter(deadline: .now() + 1.0) { [weak self, weak prewarm] in
            guard let self, let prewarm, self.waitingPrewarm === prewarm, !self.closedOnQueue else { return }
            let idle = ProcessInfo.processInfo.systemUptime - prewarm.lastActivityUptime
            if idle >= Direct115StreamStore.prewarmStallSeconds {
                self.store.note("预热传输 \(Int(idle)) 秒没有进展，改由播放连接直接拉取")
                // 取消会结束等待，读线程重新请求时就不再被这段预热覆盖
                self.store.cancelPrewarm(prewarm)
            } else {
                self.schedulePrewarmWaitCheckOnStoreQueue(prewarm)
            }
        }
    }

    /// 放弃当前流，在 `offset` 处重新起流
    private func restartOnStoreQueue(at offset: Int64) {
        cancelNetworkOnStoreQueue()
        streamSerial &+= 1
        yielded = false
        retryCount = 0
        refusalWaits = 0
        retryProgressMark = deliveredSinceOpen
        nextFetchOffset = offset
        expectedChunkStart = offset
        currentChunkActualEnd = nil
        activeStream = store.currentStream(forKey: streamKey, fallback: activeStream)
        redirectedURL = activeStream.url

        condition.lock()
        buffer.reset(at: offset)
        streamEOF = false
        streamFailed = false
        upstreamActive = true
        condition.unlock()

        // 优先接管正在拉这一段的预热任务，零重复建连
        if let prewarm = store.takeAdoptablePrewarm(forKey: streamKey, offset: offset),
           let runningTask = prewarm.detachTaskForAdoption() {
            adoptPrewarmOnStoreQueue(prewarm, task: runningTask)
            return
        }
        launchChunkOnStoreQueue(from: offset, serial: streamSerial)
    }

    private func adoptPrewarmOnStoreQueue(_ prewarm: Direct115PrewarmTransfer, task runningTask: URLSessionDataTask) {
        store.claimUpstream(for: self)
        redirectedURL = prewarm.url
        expectedChunkStart = prewarm.rangeStart
        nextFetchOffset = prewarm.rangeStart
        currentChunkActualEnd = nil
        let serial = streamSerial
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
            if !cancelled && !closed {
                totalSize = meta.totalSize
                responseHeaderArrived = true
                if !prewarm.bufferedData.isEmpty {
                    enqueueLocked(prewarm.bufferedData, at: prewarm.actualStart)
                }
                condition.broadcast()
            }
            condition.unlock()

            if nextFetchOffset > prewarm.actualEnd {
                store.detach(runningTask)
                runningTask.cancel()
                advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: prewarm.actualEnd, serial: serial)
                return
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastProgressUptime = now
        speedWindowStartUptime = now
        speedWindowBytes = 0
        task = runningTask
        store.reassignTask(runningTask, to: self)
        startStallTimerOnStoreQueue()
        setUpstreamActiveOnStoreQueue()
    }

    private func launchChunkOnStoreQueue(from start: Int64, serial: UInt64) {
        guard !closedOnQueue, !yielded, serial == streamSerial else { return }
        condition.lock()
        let stale = cancelled || closed
        condition.unlock()
        guard !stale else { return }

        if let total = knownTotalOnQueue, start >= total {
            markEOFOnStoreQueue()
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
        speedWindowStartUptime = now
        speedWindowBytes = 0
        task = store.startTask(request, for: self)
        startStallTimerOnStoreQueue()
        setUpstreamActiveOnStoreQueue()
    }

    private func maybeStartLookaheadOnStoreQueue() {
        guard !closedOnQueue, !yielded, !suspended,
              lookahead == nil, renewalID == nil, retryWork == nil,
              let total = knownTotalOnQueue, total > 0,
              let chunkEnd = currentChunkActualEnd, chunkEnd < total - 1,
              !store.isLookaheadSuppressed(forKey: streamKey),
              store.chunkSize > 0, store.lookaheadTriggerRatio > 0, store.lookaheadTriggerRatio < 1 else {
            return
        }
        condition.lock()
        let follows = readerFollowsLocked
        let buffered = aheadBytesLocked
        condition.unlock()
        guard follows, buffered < Self.resumeBytes else { return }

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

    private func advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: Int64, serial: UInt64) {
        guard !closedOnQueue, !yielded, serial == streamSerial else { return }
        if let total = knownTotalOnQueue, chunkEnd >= total - 1 {
            markEOFOnStoreQueue()
            return
        }
        let nextOffset = chunkEnd + 1

        condition.lock()
        let follows = readerFollowsLocked
        condition.unlock()
        guard follows else {
            // 读线程去了别处（比如片尾索引）：这条流先停在分段边界，窗口里的数据留着等它回来
            cancelLookaheadOnStoreQueue()
            goIdleOnStoreQueue()
            return
        }

        if let la = lookahead {
            lookahead = nil
            if la.rangeStart == nextOffset && !la.failed {
                if la.responseReceived {
                    redirectedURL = la.url
                    expectedChunkStart = nextOffset
                    currentChunkActualEnd = la.actualEnd
                    if !la.bufferedData.isEmpty {
                        appendReceivedBytesOnStoreQueue(la.bufferedData, offset: nextOffset)
                    }
                    if let total = knownTotalOnQueue, nextFetchOffset >= total {
                        la.cancel()
                        markEOFOnStoreQueue()
                        return
                    }
                    if la.completed {
                        advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: la.actualEnd, serial: serial)
                        return
                    }
                    if let runningTask = la.detachTaskForAdoption() {
                        let now = ProcessInfo.processInfo.systemUptime
                        lastProgressUptime = now
                        speedWindowStartUptime = now
                        speedWindowBytes = 0
                        task = runningTask
                        store.reassignTask(runningTask, to: self)
                        applyBackpressureIfNeededOnStoreQueue()
                        startStallTimerOnStoreQueue()
                        maybeStartLookaheadOnStoreQueue()
                        return
                    }
                } else if let runningTask = la.detachTaskForAdoption() {
                    expectedChunkStart = nextOffset
                    nextFetchOffset = nextOffset
                    currentChunkActualEnd = nil
                    adoptedFromLookahead = true
                    let now = ProcessInfo.processInfo.systemUptime
                    lastProgressUptime = now
                    speedWindowStartUptime = now
                    speedWindowBytes = 0
                    task = runningTask
                    store.reassignTask(runningTask, to: self)
                    startStallTimerOnStoreQueue()
                    return
                }
            }
            la.cancel()
        }

        condition.lock()
        let buffered = aheadBytesLocked
        condition.unlock()
        if buffered >= Self.pauseBytes {
            // 已有充足内存缓冲时先暂缓发起下一分段，待 mpv 消费回落再拉
            suspended = true
            return
        }
        launchChunkOnStoreQueue(from: nextOffset, serial: serial)
    }

    private func resumeIfNeededOnStoreQueue() {
        guard !closedOnQueue, !yielded else { return }
        condition.lock()
        let follows = readerFollowsLocked
        let buffered = aheadBytesLocked
        condition.unlock()
        // 读线程不在这条流上（比如在读片尾索引）：暂停着的流先别续
        guard follows else { return }
        if let prewarm = waitingPrewarm {
            // 读线程已经回到这条流，不用再等那段预热
            waitingPrewarm = nil
            prewarm.removeWaiter(self)
        }
        if suspended {
            guard buffered < Self.resumeBytes else { return }
            suspended = false
            let now = ProcessInfo.processInfo.systemUptime
            lastProgressUptime = now
            speedWindowStartUptime = now
            speedWindowBytes = 0
            if let running = task {
                running.resume()
                maybeStartLookaheadOnStoreQueue()
            } else if retryWork == nil, renewalID == nil {
                launchChunkOnStoreQueue(from: nextFetchOffset, serial: streamSerial)
            }
        } else {
            maybeStartLookaheadOnStoreQueue()
        }
    }

    private func applyBackpressureIfNeededOnStoreQueue() {
        condition.lock()
        let buffered = aheadBytesLocked
        condition.unlock()
        if !suspended, buffered > Self.pauseBytes, let running = task {
            suspended = true
            running.suspend()
        }
    }

    private func appendReceivedBytesOnStoreQueue(_ data: Data, offset: Int64) {
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
        if !cancelled && !closed, enqueueLocked(data, at: offset) {
            condition.broadcast()
        }
        condition.unlock()

        // 片头够判断容器索引位置了：索引在片尾时另开连接把它预取进缓存
        if !indexPrefetchChecked, offset < Direct115StreamStore.headProbeBytes,
           nextFetchOffset >= min(Self.indexProbeTriggerBytes, knownTotalOnQueue ?? Self.indexProbeTriggerBytes) {
            indexPrefetchChecked = store.ensureIndexPrefetch(forKey: streamKey, fallback: activeStream)
        }
    }

    private func wakeReaderOnStoreQueue() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private func bumpEpochOnStoreQueue() {
        condition.lock()
        upstreamEpoch &+= 1
        condition.broadcast()
        condition.unlock()
    }

    private func setUpstreamActiveOnStoreQueue() {
        condition.lock()
        upstreamActive = true
        condition.unlock()
    }

    /// 这条流不会再自己往后送数据了（读线程回来时会重新请求）
    private func goIdleOnStoreQueue() {
        condition.lock()
        upstreamActive = false
        upstreamEpoch &+= 1
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Direct115TaskHandler（store.queue）

    fileprivate func didRedirect(to url: URL) {
        redirectedURL = url
    }

    fileprivate func didReceive(_ response: URLResponse, from dataTask: URLSessionDataTask) -> Bool {
        guard !closedOnQueue, task === dataTask else { return false }
        guard let http = response as? HTTPURLResponse else {
            failTerminalOnStoreQueue("上游响应无效")
            return false
        }
        lastProgressUptime = ProcessInfo.processInfo.systemUptime
        let serial = streamSerial
        let wasLookahead = adoptedFromLookahead
        adoptedFromLookahead = false

        if Direct115HTTPHelper.isRefused(status: http.statusCode), wasLookahead {
            store.suppressLookahead(forKey: streamKey, duration: 60)
            store.note("进程内直连接管的预取分段收到 HTTP \(http.statusCode)，降级为单连接并重拉 \(nextFetchOffset) 字节")
            store.detach(dataTask)
            task = nil
            stopStallTimerOnStoreQueue()
            launchChunkOnStoreQueue(from: nextFetchOffset, serial: serial)
            return false
        }

        if Direct115HTTPHelper.isRefused(status: http.statusCode),
           renewUpstreamOnStoreQueue("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）",
                                     cancelling: dataTask, resumeAt: nextFetchOffset, serial: serial) {
            return false
        }
        if Direct115HTTPHelper.isTransient(status: http.statusCode),
           scheduleRetryOnStoreQueue("上游返回 HTTP \(http.statusCode)（\(http.url?.host ?? "")）",
                                     cancelling: dataTask, resumeAt: nextFetchOffset, serial: serial) {
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
                failTerminalOnStoreQueue("上游文件已变化（HTTP 206）")
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
            if !cancelled && !closed {
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
            if !cancelled && !closed {
                if let total = knownTotalOnQueue { totalSize = total }
                responseHeaderArrived = true
                condition.broadcast()
            }
            condition.unlock()
            return true
        }

        store.note("进程内直连收到 HTTP \(http.statusCode)（\(http.url?.host ?? "")）")
        failTerminalOnStoreQueue("HTTP \(http.statusCode)")
        return false
    }

    fileprivate func didReceive(_ data: Data) {
        guard !closedOnQueue, task != nil, !data.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastProgressUptime = now
        lastReceivedBytesUptime = now
        speedWindowBytes += Int64(data.count)
        if recentSampleStartUptime == 0 || now - recentSampleStartUptime >= 4.0 {
            recentSampleStartUptime = now
            recentSampleBytes = Int64(data.count)
        } else {
            recentSampleBytes += Int64(data.count)
        }

        appendReceivedBytesOnStoreQueue(data, offset: nextFetchOffset)
        applyBackpressureIfNeededOnStoreQueue()
        maybeStartLookaheadOnStoreQueue()
    }

    fileprivate func didComplete(_ error: Error?) {
        task = nil
        stopStallTimerOnStoreQueue()
        guard !closedOnQueue else { return }
        let serial = streamSerial

        if let error {
            if let total = knownTotalOnQueue, nextFetchOffset >= total {
                markEOFOnStoreQueue()
                return
            }
            let detail = "进程内直连上游失败：\(LocalStreamProxy.summary(of: error))（\(redirectedURL.host ?? "")），已收 \(deliveredSinceOpen) 字节"
            if Direct115HTTPHelper.isTransient(error),
               scheduleRetryOnStoreQueue(detail, cancelling: nil, resumeAt: nextFetchOffset, serial: serial) {
                return
            }
            failTerminalOnStoreQueue(detail)
            return
        }

        if let total = knownTotalOnQueue, nextFetchOffset >= total {
            markEOFOnStoreQueue()
            return
        }
        if let chunkEnd = currentChunkActualEnd, nextFetchOffset == chunkEnd + 1 {
            retryCount = 0
            refusalWaits = 0
            retryProgressMark = deliveredSinceOpen
            advanceOrFinishAfterChunkOnStoreQueue(chunkEnd: chunkEnd, serial: serial)
            return
        }
        if knownTotalOnQueue == nil {
            markEOFOnStoreQueue()
            return
        }
        if scheduleRetryOnStoreQueue("进程内直连上游提前结束（停在 \(nextFetchOffset) 字节）", cancelling: nil, resumeAt: nextFetchOffset, serial: serial) {
            return
        }
        failTerminalOnStoreQueue("上游提前结束传输")
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
        let follows = readerFollowsLocked
        let buffered = aheadBytesLocked
        condition.unlock()
        // 读线程不在这条流上，或者缓冲充足：慢一点没关系
        if !follows || buffered >= Self.resumeBytes {
            lastProgressUptime = now
            speedWindowStartUptime = now
            speedWindowBytes = 0
            return
        }
        let silentFor = now - lastProgressUptime
        var stalledReason: String?
        if silentFor >= store.stallTimeout {
            stalledReason = "进程内直连上游 \(String(format: "%.1f", silentFor)) 秒无响应（\(redirectedURL.host ?? "")）"
        } else if store.minHealthySpeed > 0, speedWindowBytes > 0 {
            let elapsed = now - speedWindowStartUptime
            let slowWindow = max(store.stallTimeout + 4.0, 16.0)
            if elapsed >= slowWindow {
                let speed = Double(speedWindowBytes) / elapsed
                if speed < store.minHealthySpeed {
                    stalledReason = "进程内直连上游过慢（\(Int(speed / 1024)) KB/s）"
                } else {
                    speedWindowStartUptime = now
                    speedWindowBytes = 0
                }
            }
        }
        guard let reason = stalledReason else { return }
        stopStallTimerOnStoreQueue()
        store.detach(running)
        running.cancel()
        task = nil
        let serial = streamSerial

        if retryCount >= 2, store.canRenew(forKey: streamKey),
           store.needsNewAddress(forKey: streamKey, failed: activeStream.url, ignoreCooldown: true),
           renewUpstreamOnStoreQueue(reason, cancelling: nil, resumeAt: nextFetchOffset, serial: serial, ignoreCooldown: true) {
            return
        }
        if scheduleRetryOnStoreQueue(reason, cancelling: nil, resumeAt: nextFetchOffset, serial: serial) { return }
        failTerminalOnStoreQueue(reason)
    }

    private func beginRecoveryOnStoreQueue() {
        if let recoveryWindow, deliveredSinceOpen - recoveryWindow.bytes < 65_536 { return }
        recoveryWindow = (ProcessInfo.processInfo.systemUptime + Direct115StreamStore.recoveryGrace, deliveredSinceOpen)
    }

    private func scheduleRetryOnStoreQueue(_ detail: String, cancelling running: URLSessionDataTask?, resumeAt: Int64, serial: UInt64) -> Bool {
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
            self?.launchChunkOnStoreQueue(from: resumeAt, serial: serial)
        }
        retryWork = work
        store.queue.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    private func renewUpstreamOnStoreQueue(
        _ detail: String,
        cancelling running: URLSessionDataTask?,
        resumeAt: Int64,
        serial: UInt64,
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
            requestRenewalOnStoreQueue(at: resumeAt, serial: serial, allowSameURL: false)
        } else {
            let delay = waits[refusalWaits]
            refusalWaits += 1
            store.note("\(detail)；新地址仍被拒，\(delay) 秒后从 \(resumeAt) 字节重试")
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.closedOnQueue else { return }
                self.launchChunkOnStoreQueue(from: resumeAt, serial: serial)
            }
            retryWork = work
            store.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        return true
    }

    private func requestRenewalOnStoreQueue(at offset: Int64, serial: UInt64, allowSameURL: Bool) {
        let id = UUID()
        renewalID = id
        store.renew(forKey: streamKey, failed: activeStream.url) { [weak self] fresh in
            guard let self, !self.closedOnQueue, self.renewalID == id, serial == self.streamSerial else { return }
            self.renewalID = nil
            if let fresh {
                self.activeStream = fresh
                self.redirectedURL = fresh.url
            } else if !allowSameURL {
                self.failTerminalOnStoreQueue("115 换链失败")
                return
            }
            self.launchChunkOnStoreQueue(from: offset, serial: serial)
        }
    }

    private func markEOFOnStoreQueue() {
        condition.lock()
        streamEOF = true
        responseHeaderArrived = true
        upstreamActive = false
        upstreamEpoch &+= 1
        condition.broadcast()
        condition.unlock()
    }

    private func failTerminalOnStoreQueue(_ reason: String) {
        store.note(reason)
        condition.lock()
        // 读线程跟着这条流时才算读失败；它在别处时只是这条（停放着的）流没了，回来时重新拉
        if readerFollowsLocked { streamFailed = true }
        upstreamActive = false
        upstreamEpoch &+= 1
        condition.broadcast()
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
        if let prewarm = waitingPrewarm {
            waitingPrewarm = nil
            prewarm.removeWaiter(self)
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

/// 剧集详情页、点开播放与自动连播提前预解析 / 预热 115 原画直链的统一入口。
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

    /// 点开 115 视频的那一刻（播放窗口还在弹出、转屏）就开始解析直链并预热，
    /// 播放页自己的解析会合并到这次进行中的请求上，不会重复打 115 接口。
    @MainActor
    static func kick(for source: PlaybackSource, appState: AppState) {
        guard case .p115(_, let pickCode) = source, !pickCode.isEmpty,
              let client = appState.directClient() else { return }
        let resume = RecentStore.shared.position(for: source) != nil
        Task.detached(priority: .userInitiated) {
            await prewarm(client: client, pickCode: pickCode, resume: resume, prefetchBytes: true)
        }
    }
}
