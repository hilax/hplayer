import Foundation

// MARK: - 115 线路测速

/// 一条 115 下载线路（一个下载地址）的测速结果
struct LineSpeedResult: Identifiable, Equatable {
    let id: Int
    /// 「正在播放」或「新地址 1」
    let label: String
    /// 实际连到的主机（跟随跳转后的）
    var host: String
    /// 发出请求到收到第一块数据用了多久
    var firstByte: TimeInterval?
    /// 收到第一块数据之后的平均速度（字节 / 秒）
    var averageSpeed: Double = 0
    /// 任意连续 1 秒里的最高速度（字节 / 秒）
    var peakSpeed: Double = 0
    var bytes: Int64 = 0
    var error: String?

    /// 主机名太长，界面上只留第一段（例如 cdnfhnfile）
    var shortHost: String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    var summary: String {
        if let error { return error }
        let first = firstByte.map { String(format: "首字节 %.2f 秒", $0) } ?? "首字节 —"
        return "\(first) · 平均 \(Self.speed(averageSpeed)) · 峰值 \(Self.speed(peakSpeed))"
    }

    /// 复制出去的一行：带完整主机名和下载量
    var reportLine: String {
        let downloaded = String(format: "%.1f MB", Double(bytes) / 1_048_576)
        return "\(label)（\(host.isEmpty ? "未知主机" : host)）：\(summary)，共下载 \(downloaded)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}

enum LineSpeedState: Equatable {
    case idle
    case running(step: String, results: [LineSpeedResult])
    case finished(results: [LineSpeedResult])
}

/// 依次测几条 115 下载线路：正在播放的地址，再向 115 要几个新地址。每条单独一个连接，从文件中间某处
/// 下最多几秒，记下首字节时间、平均速度和 1 秒峰值。几条线路依次测，不同时抢带宽。
enum LineSpeedTester {
    /// 每条线路最多测多久（从收到第一块数据算）
    static let measureDuration: TimeInterval = 4
    /// 每条线路最多下多少
    static let maxBytes: Int64 = 64 << 20
    /// 等第一块数据最多等多久
    static let firstByteTimeout: TimeInterval = 8

    static func run(
        current: URL?,
        freshAddress: @escaping () async throws -> URL,
        headers: [String: String],
        newAddresses: Int,
        progress: @MainActor @escaping (String, [LineSpeedResult]) -> Void
    ) async -> [LineSpeedResult] {
        var results: [LineSpeedResult] = []
        await progress("正在读取文件大小…", results)
        // 文件大小用来把每条线路的测试位置错开到文件中间，避免测到 CDN 已经缓存好的开头
        var size: Int64?
        if let current { size = await fileSize(of: current, headers: headers) }

        var index = 0
        func offset(for index: Int) -> Int64 {
            guard let size, size > 32 << 20 else { return 0 }
            let fraction = min(0.2 + 0.15 * Double(index), 0.85)
            return Int64(Double(size) * fraction)
        }

        if let current {
            await progress("正在测正在播放的地址…", results)
            var result = await measure(url: current, headers: headers, offset: offset(for: index))
            result = LineSpeedResult(id: index, label: "正在播放", host: result.host, firstByte: result.firstByte,
                                     averageSpeed: result.averageSpeed, peakSpeed: result.peakSpeed,
                                     bytes: result.bytes, error: result.error)
            results.append(result)
            index += 1
        }

        for number in 1...max(newAddresses, 1) {
            guard !Task.isCancelled else { break }
            let label = "新地址 \(number)"
            await progress("正在向 115 要\(label)…", results)
            // 连续要地址之间稍微隔一下，别让 115 觉得请求太频繁
            if number > 1 { try? await Task.sleep(nanoseconds: 500_000_000) }
            let url: URL
            do {
                url = try await freshAddress()
            } catch {
                results.append(LineSpeedResult(id: index, label: label, host: "", error: "没要到地址：\(error.localizedDescription)"))
                index += 1
                continue
            }
            if size == nil { size = await fileSize(of: url, headers: headers) }
            await progress("正在测\(label)（\(url.host ?? "")）…", results)
            let measured = await measure(url: url, headers: headers, offset: offset(for: index))
            results.append(LineSpeedResult(id: index, label: label, host: measured.host.isEmpty ? (url.host ?? "") : measured.host,
                                           firstByte: measured.firstByte, averageSpeed: measured.averageSpeed,
                                           peakSpeed: measured.peakSpeed, bytes: measured.bytes, error: measured.error))
            index += 1
        }
        return results
    }

    /// 用 1 字节的分段请求读出文件总大小
    private static func fileSize(of url: URL, headers: [String: String]) async -> Int64? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: firstByteTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let reply = try? await session.data(for: request),
              let http = reply.1 as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else { return nil }
        return total
    }

    /// 测一条地址：单个连接，从 offset 开始下，最多 measureDuration 秒或 maxBytes 字节
    static func measure(url: URL, headers: [String: String], offset: Int64) async -> LineSpeedResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: firstByteTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(offset + maxBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let probe = SpeedProbe(duration: measureDuration, maxBytes: maxBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = firstByteTimeout
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.addOperation {
                    // 已经被取消（取消回调先到了）：不再发请求
                    guard !probe.isFinished else {
                        continuation.resume()
                        return
                    }
                    probe.onFinish = { continuation.resume() }
                    let task = session.dataTask(with: request)
                    probe.task = task
                    task.resume()
                }
                // 兜底：总时长到了还没结束就停掉
                DispatchQueue.global().asyncAfter(deadline: .now() + firstByteTimeout + measureDuration + 2) {
                    queue.addOperation { probe.stop(reason: "超时") }
                }
            }
        } onCancel: {
            queue.addOperation { probe.stop(reason: "已取消") }
        }
        return probe.result(label: "")
    }
}

/// 收数据并按 50 毫秒分桶记下来，算平均和 1 秒峰值。所有回调都在同一个串行队列上。
private final class SpeedProbe: NSObject, URLSessionDataDelegate {
    private static let bucket: TimeInterval = 0.05

    let duration: TimeInterval
    let maxBytes: Int64
    var task: URLSessionDataTask?
    var onFinish: (() -> Void)?

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var firstDataAt: TimeInterval?
    private var lastDataAt: TimeInterval?
    private var buckets: [Int64] = []
    private var total: Int64 = 0
    private var host = ""
    private var failure: String?
    private var finished = false
    var isFinished: Bool { finished }

    init(duration: TimeInterval, maxBytes: Int64) {
        self.duration = duration
        self.maxBytes = maxBytes
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        host = response.url?.host ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = "115 返回 HTTP \(http.statusCode)"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstDataAt == nil { firstDataAt = now }
        lastDataAt = now
        let index = Int((now - (firstDataAt ?? now)) / Self.bucket)
        if buckets.count <= index { buckets.append(contentsOf: repeatElement(0, count: index - buckets.count + 1)) }
        buckets[index] += Int64(data.count)
        total += Int64(data.count)
        if now - (firstDataAt ?? now) >= duration || total >= maxBytes {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil, (error as NSError).code != NSURLErrorCancelled {
            failure = LocalStreamProxy.summary(of: error)
        }
        finish()
    }

    func stop(reason: String) {
        guard !finished else { return }
        if total == 0, failure == nil { failure = reason == "超时" ? "\(Int(LineSpeedTester.firstByteTimeout)) 秒内没有收到数据" : reason }
        task?.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish?()
        onFinish = nil
    }

    func result(label: String) -> LineSpeedResult {
        var result = LineSpeedResult(id: 0, label: label, host: host)
        result.bytes = total
        if let firstDataAt {
            result.firstByte = firstDataAt - startedAt
            let span = max((lastDataAt ?? firstDataAt) - firstDataAt, Self.bucket)
            result.averageSpeed = Double(total) / span
            // 1 秒滑动窗口里的最大值；测得不到 1 秒时就用平均值
            let window = Int(1 / Self.bucket)
            if buckets.count >= window {
                var sum = buckets.prefix(window).reduce(0, +)
                var best = sum
                for i in window..<buckets.count {
                    sum += buckets[i] - buckets[i - window]
                    best = max(best, sum)
                }
                result.peakSpeed = Double(best)
            } else {
                result.peakSpeed = result.averageSpeed
            }
        }
        if total == 0 { result.error = failure ?? "没有收到数据" }
        return result
    }
}
