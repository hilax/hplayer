import Foundation

/// 把一个地址下载到本地文件，支持断点续传：文件里已有的部分不会重新下载。
/// 只负责一次连接；换新地址、重试、排队由 DownloadManager 决定。
///
/// 为什么不用后台下载（background URLSession）：115 的原文件地址要带登录 Cookie 和固定的 User-Agent，
/// 而且地址会过期，系统在后台接管下载后没法替我们换地址；所以只在 App 打开时下载，断了就从已有的位置接着来。
final class RangeDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        /// 401 / 403 / 410：下载地址过期或登录失效，需要换新地址
        case expired
        case http(Int)
        /// 返回的是网页而不是文件
        case notAFile
        /// 服务器不认可已有的续传位置，需要从头开始
        case rangeRejected
        case incomplete(received: Int64, expected: Int64)
        case diskFull
        case writeFailed(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .expired: return "下载地址已失效，请重新登录后再试"
            case .http(let code): return "115 下载服务器返回了错误（\(code)）"
            case .notAFile: return "115 返回的不是文件内容，下载地址可能已失效"
            case .rangeRejected: return "服务器不支持从中断的位置继续下载"
            case .incomplete: return "网络中断，下载没有完成"
            case .diskFull: return "手机存储空间不足"
            case .writeFailed(let message): return "写入文件失败：\(message)"
            case .network(let message): return message
            }
        }

        /// 原地重试有机会成功（网络波动、服务器暂时繁忙）
        var isRetryable: Bool {
            switch self {
            case .network, .incomplete: return true
            case .http(let code): return code == 429 || (500...599).contains(code)
            default: return false
            }
        }
    }

    struct ContentRange: Equatable {
        var start: Int64?
        var end: Int64?
        var total: Int64?
    }

    private let request: URLRequest
    private let partURL: URL
    private let protocolClasses: [AnyClass]?
    private let reportInterval: TimeInterval
    private let onProgress: @Sendable (Int64, Int64?) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var cancelled = false
    private var finished = false
    private var failure: Failure?
    private var startOffset: Int64 = 0
    private var received: Int64 = 0
    private var total: Int64?
    private var lastReport: TimeInterval = 0

    /// - Parameters:
    ///   - request: 带好请求头的下载请求；续传用的 Range 由下载器根据 partURL 里已有的字节数自己加
    ///   - partURL: 下载到一半的文件。文件已经存在时从它的末尾接着下
    ///   - onProgress: 已收到的字节数（含之前下载的）和总字节数；最多每 `reportInterval` 秒回调一次
    init(request: URLRequest, partURL: URL, protocolClasses: [AnyClass]? = nil, reportInterval: TimeInterval = 0.25,
         onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.request = request
        self.partURL = partURL
        self.protocolClasses = protocolClasses
        self.reportInterval = reportInterval
        self.onProgress = onProgress
    }

    /// 下载到结束，返回文件的最终字节数。任务被取消时抛出 CancellationError，已下载的部分保留在 partURL。
    func run() async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                self.begin(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: 启动与收尾

    private func begin(_ continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        do {
            let manager = FileManager.default
            try manager.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: partURL.path) {
                guard manager.createFile(atPath: partURL.path, contents: nil) else {
                    throw Failure.writeFailed("无法创建下载文件")
                }
            }
            let handle = try FileHandle(forWritingTo: partURL)
            let endOfFile = try handle.seekToEnd()
            let offset = Int64(clamping: endOfFile)

            var request = self.request
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            // 已经压缩过的视频不需要再压缩；而且压缩后 Content-Length 对不上收到的字节数
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60 * 24
            configuration.waitsForConnectivity = false
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = "app.hplayer.range-downloader"
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)

            lock.lock()
            self.handle = handle
            self.startOffset = offset
            self.received = offset
            self.session = session
            self.task = task
            let alreadyCancelled = cancelled
            lock.unlock()

            task.resume()
            if alreadyCancelled { task.cancel() }
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Int64, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let handle = self.handle
        let session = self.session
        self.continuation = nil
        self.handle = nil
        self.session = nil
        self.task = nil
        lock.unlock()

        try? handle?.close()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func fail(_ failure: Failure) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        lock.unlock()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(.network("115 响应无效"))
            completionHandler(.cancel)
            return
        }
        do {
            let outcome = try accept(http)
            if case .alreadyComplete(let size) = outcome {
                // 本地已经是完整的文件，不用再下载
                completionHandler(.cancel)
                finish(.success(size))
                return
            }
            completionHandler(.allow)
        } catch let error as Failure {
            fail(error)
            completionHandler(.cancel)
        } catch {
            fail(.writeFailed(error.localizedDescription))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        lock.unlock()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(Self.writeFailure(error))
            dataTask.cancel()
            return
        }
        lock.lock()
        received += Int64(data.count)
        let snapshot = (received: received, total: total)
        let now = ProcessInfo.processInfo.systemUptime
        let report = now - lastReport >= reportInterval
        if report { lastReport = now }
        lock.unlock()
        if report { onProgress(snapshot.received, snapshot.total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let recorded = failure
        let received = self.received
        let total = self.total
        let userCancelled = cancelled
        lock.unlock()

        if let recorded {
            finish(.failure(recorded))
            return
        }
        if let error {
            let nsError = error as NSError
            if userCancelled || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(Failure.network(Self.describe(nsError))))
            }
            return
        }
        if let total, received != total {
            finish(.failure(Failure.incomplete(received: received, expected: total)))
            return
        }
        onProgress(received, total)
        finish(.success(received))
    }

    /// 把重定向交给系统处理，但不把请求头里的 Cookie 带到非 115 的域名上
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        var next = request
        if host != "115.com", !host.hasSuffix(".115.com"), host != "115cdn.net", !host.hasSuffix(".115cdn.net"),
           host != "115cdn.com", !host.hasSuffix(".115cdn.com") {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }

    // MARK: 响应检查

    private enum Outcome {
        case proceed
        case alreadyComplete(Int64)
    }

    private func accept(_ http: HTTPURLResponse) throws -> Outcome {
        lock.lock()
        let offset = startOffset
        let handle = self.handle
        lock.unlock()

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        switch http.statusCode {
        case 200:
            guard !contentType.hasPrefix("text/html") else { throw Failure.notAFile }
            if offset > 0 {
                // 服务器忽略了 Range，把整个文件重新发了一遍：丢掉旧的部分，从头写
                guard let handle else { throw Failure.writeFailed("文件已关闭") }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            }
            lock.lock()
            received = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            lock.unlock()
            return .proceed
        case 206:
            let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))
            guard let start = range?.start, start == offset else { throw Failure.rangeRejected }
            var size = range?.total
            if size == nil, http.expectedContentLength > 0 { size = offset + http.expectedContentLength }
            lock.lock()
            total = size
            lock.unlock()
            return .proceed
        case 416:
            // 已有的字节数就是文件大小：下载其实已经完成；否则说明本地数据对不上
            if let size = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range"))?.total, size == offset, offset > 0 {
                return .alreadyComplete(size)
            }
            throw Failure.rangeRejected
        case 401, 403, 410:
            throw Failure.expired
        default:
            throw Failure.http(http.statusCode)
        }
    }

    // MARK: 工具

    /// 解析 `Content-Range`：「bytes 100-999/1000」「bytes 100-999/*」「bytes */1000」
    static func parseContentRange(_ header: String?) -> ContentRange? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let value = trimmed.dropFirst("bytes".count).trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var result = ContentRange(start: nil, end: nil, total: Int64(parts[1].trimmingCharacters(in: .whitespaces)))
        let span = parts[0].trimmingCharacters(in: .whitespaces)
        if span != "*" {
            let ends = span.split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count == 2, let start = Int64(ends[0]), let end = Int64(ends[1]), start >= 0, end >= start else { return nil }
            result.start = start
            result.end = end
        }
        return result
    }

    static func writeFailure(_ error: Error) -> Failure {
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return .diskFull
        }
        return .writeFailed(nsError.localizedDescription)
    }

    static func describe(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorTimedOut: return "连接超时"
        case NSURLErrorNotConnectedToInternet: return "网络未连接"
        case NSURLErrorNetworkConnectionLost: return "网络连接中断"
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "无法连接到下载服务器"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "安全连接失败"
        default: return error.localizedDescription
        }
    }
}
