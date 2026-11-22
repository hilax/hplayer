import Darwin
import Foundation
import Network

/// 投屏媒体描述：包含当前正在播放或待播的视频地址、请求头、续播位置和外挂字幕。
struct CastMediaDescriptor {
    let url: URL
    let localProxyURL: URL?
    let title: String
    let headers: [String: String]
    let position: Double
    let duration: Double
    let subtitleFileURL: URL?
    let isTorrentStream: Bool

    /// 对远程流优先走 LocalStreamProxy 已建立的地址（保留 115 Cookie、续链与 m3u8 刷新能力）。
    var effectiveUpstreamURL: URL {
        localProxyURL ?? url
    }

    var effectiveHeaders: [String: String] {
        localProxyURL == nil ? headers : [:]
    }
}

/// 本机当前活跃局域网网卡信息（IPv4 地址、子网掩码与网卡索引）。
struct WiFiNetworkInfo: Equatable, Sendable {
    let ip: String
    let netmask: String
    let interfaceName: String
    let interfaceIndex: UInt32

    /// 所在子网的定向广播地址（如 192.168.1.255）。
    var broadcastAddress: String? {
        guard let ipHost = Self.ipv4HostOrder(ip) else { return nil }
        let rawMask = Self.ipv4HostOrder(netmask) ?? 0xFFFF_FF00
        let maskHost = (rawMask == 0 || rawMask == 0xFFFF_FFFF) ? UInt32(0xFFFF_FF00) : rawMask
        let broadcast = (ipHost & maskHost) | ~maskHost
        return Self.ipv4String(fromHostOrder: broadcast)
    }

    func unicastSweepTargets(maxHosts: Int = 254) -> [String] {
        Self.unicastSweepTargets(ip: ip, netmask: netmask, maxHosts: maxHosts)
    }

    /// 计算同网段可单播探测的主机 IPv4 列表（自动排除本机 IP，大网段收敛到所在 /24）。
    static func unicastSweepTargets(ip: String, netmask: String, maxHosts: Int = 254) -> [String] {
        guard let ipHost = ipv4HostOrder(ip) else { return [] }
        let rawMask = ipv4HostOrder(netmask) ?? 0xFFFF_FF00
        let maskHost = (rawMask == 0 || rawMask == 0xFFFF_FFFF) ? UInt32(0xFFFF_FF00) : rawMask

        let network = ipHost & maskHost
        let broadcast = network | ~maskHost
        guard broadcast > network + 1 else { return [] }

        let hostCount = UInt64(broadcast) - UInt64(network) - 1
        let startHost: UInt32
        let endHost: UInt32
        if hostCount <= UInt64(max(1, maxHosts)) {
            startHost = network + 1
            endHost = broadcast - 1
        } else {
            let sub24 = ipHost & 0xFFFF_FF00
            startHost = sub24 + 1
            endHost = sub24 + 254
        }

        var targets: [String] = []
        targets.reserveCapacity(Int(endHost - startHost + 1))
        var candidate = startHost
        while candidate <= endHost {
            if candidate != ipHost, let text = ipv4String(fromHostOrder: candidate) {
                targets.append(text)
            }
            if candidate == UInt32.max { break }
            candidate += 1
        }
        return targets
    }

    private static func ipv4HostOrder(_ string: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func ipv4String(fromHostOrder hostOrder: UInt32) -> String? {
        var addr = in_addr(s_addr: hostOrder.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}

/// 隔空播放遇不支持封装格式（如 115 原画 MKV）时的降级流解析结果。
struct CastResolvedStream {
    let url: URL
    let headers: [String: String]
    let qualityNotice: String
}

/// 按需启停的局域网 HTTP 媒体中转服务，仅供投屏会话期间使用。
/// - 本地文件支持 `HEAD` / `GET` / `Range` 分块流式传输；
/// - 远程流与磁力流转发给电视，并自动将 m3u8 播放列表改写为手机局域网地址；
/// - 所有地址均带随机会话令牌，停止投屏后立即失效并关闭监听。
final class CastMediaServer: NSObject, URLSessionDelegate, @unchecked Sendable {
    private enum Entry {
        case localFile(url: URL, mimeType: String, filename: String)
        case httpProxy(upstreamURL: URL, headers: [String: String], mimeType: String, filename: String)
    }

    private let queue = DispatchQueue(label: "app.hplayer.cast-media-server", qos: .userInitiated)
    private let bindHostOverride: String?
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var listenerWaiters: [(UInt16?) -> Void] = []
    private var entries: [String: Entry] = [:]
    private var connections: [ObjectIdentifier: CastHTTPConnection] = [:]
    private var session: URLSession!
    private var advertisedHost: String = "127.0.0.1"

    init(bindHostOverride: String? = nil) {
        self.bindHostOverride = bindHostOverride
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
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

    // MARK: - 网络地址发现

    /// 获取本机当前 Wi-Fi（优先 en0，回退 en* 与个人热点 bridge100）的网卡与子网信息。
    static func wifiNetworkInfo() -> WiFiNetworkInfo? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var preferredEn0: WiFiNetworkInfo?
        var fallbackEn: WiFiNetworkInfo?
        var fallbackBridge: WiFiNetworkInfo?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addrPointer = current.pointee.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            var addr = addrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buffer)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }

            var netmask = "255.255.255.0"
            if let maskPointer = current.pointee.ifa_netmask,
               maskPointer.pointee.sa_family == UInt8(AF_INET) {
                var maskAddr = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &maskAddr, &maskBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let parsedMask = String(cString: maskBuffer)
                    if !parsedMask.isEmpty {
                        netmask = parsedMask
                    }
                }
            }

            let ifIndex = if_nametoindex(current.pointee.ifa_name)
            let info = WiFiNetworkInfo(ip: ip, netmask: netmask, interfaceName: name, interfaceIndex: ifIndex)

            if name == "en0" {
                preferredEn0 = info
                break
            } else if name.hasPrefix("en"), fallbackEn == nil {
                fallbackEn = info
            } else if name == "bridge100", fallbackBridge == nil {
                fallbackBridge = info
            }
        }
        return preferredEn0 ?? fallbackEn ?? fallbackBridge
    }

    /// 获取本机当前 Wi-Fi（优先 en0，回退 en*）的 IPv4 地址。
    static func wifiIPv4Address() -> String? {
        wifiNetworkInfo()?.ip
    }

    var currentLANHost: String? {
        bindHostOverride ?? Self.wifiIPv4Address()
    }

    // MARK: - 会话注册与启停

    func registerMedia(_ media: CastMediaDescriptor) async -> (url: URL, mimeType: String)? {
        guard let host = currentLANHost else { return nil }
        guard let activePort = await ensureStarted() else { return nil }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let upstream = media.effectiveUpstreamURL
        let rawName = media.url.lastPathComponent
        let fallbackName = upstream.lastPathComponent
        let chosenName = (!rawName.isEmpty && rawName != "/") ? rawName : ((!fallbackName.isEmpty && fallbackName != "/") ? fallbackName : "stream.mp4")
        let mime = Self.mimeType(forPathExtension: URL(fileURLWithPath: chosenName).pathExtension)

        queue.sync {
            self.advertisedHost = host
            if upstream.isFileURL {
                self.entries[token] = .localFile(url: upstream, mimeType: mime, filename: chosenName)
            } else {
                self.entries[token] = .httpProxy(upstreamURL: upstream, headers: media.effectiveHeaders, mimeType: mime, filename: chosenName)
            }
        }

        let safeName = chosenName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "stream"
        guard let castURL = URL(string: "http://\(host):\(activePort)/media/\(token)/\(safeName)") else { return nil }
        return (castURL, mime)
    }

    func registerSubtitle(fileURL: URL) async -> URL? {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let host = currentLANHost else { return nil }
        guard let activePort = await ensureStarted() else { return nil }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let name = fileURL.lastPathComponent.isEmpty ? "subtitle.srt" : fileURL.lastPathComponent
        let mime = Self.mimeType(forPathExtension: fileURL.pathExtension)

        queue.sync {
            self.advertisedHost = host
            self.entries[token] = .localFile(url: fileURL, mimeType: mime, filename: name)
        }

        let safeName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "subtitle.srt"
        return URL(string: "http://\(host):\(activePort)/sub/\(token)/\(safeName)")
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            self.entries.removeAll()
            let waiters = self.listenerWaiters
            self.listenerWaiters.removeAll()
            for waiter in waiters { waiter(nil) }
            let active = Array(self.connections.values)
            self.connections.removeAll()
            for conn in active { conn.close() }
        }
    }

    // MARK: - 监听器管理

    private func ensureStarted() async -> UInt16? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                if let listener = self.listener, case .ready = listener.state, self.port != 0 {
                    continuation.resume(returning: self.port)
                    return
                }
                self.listenerWaiters.append { port in
                    continuation.resume(returning: port)
                }
                self.startListenerIfNeeded()
            }
        }
    }

    private func startListenerIfNeeded() {
        if let listener {
            switch listener.state {
            case .ready where port != 0:
                finishWaiters(port)
                return
            case .setup, .waiting:
                return
            default:
                listener.cancel()
                self.listener = nil
                self.port = 0
            }
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if bindHostOverride == "127.0.0.1" {
            parameters.requiredInterfaceType = .loopback
        }
        guard let created = try? NWListener(using: parameters, on: .any) else {
            finishWaiters(nil)
            return
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created, self.listener === created else { return }
            switch state {
            case .ready:
                let bound = created.port?.rawValue ?? 0
                self.port = bound
                if bound == 0 {
                    self.listener = nil
                    created.cancel()
                    self.finishWaiters(nil)
                } else {
                    self.finishWaiters(bound)
                }
            case .failed, .cancelled:
                self.listener = nil
                self.port = 0
                self.finishWaiters(nil)
            default:
                break
            }
        }
        listener = created
        created.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self, weak created] in
            guard let self, let created, self.listener === created, self.port == 0 else { return }
            self.listener = nil
            created.cancel()
            self.finishWaiters(nil)
        }
    }

    private func finishWaiters(_ port: UInt16?) {
        let waiters = listenerWaiters
        listenerWaiters.removeAll()
        for waiter in waiters { waiter(port) }
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = CastHTTPConnection(connection: connection, server: self, queue: queue)
        let id = ObjectIdentifier(wrapper)
        connections[id] = wrapper
        wrapper.onClose = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        wrapper.start()
    }

    // MARK: - 请求路由与解析

    private func resolve(path: String) -> (entry: Entry, token: String, hlsTargetURL: URL?)? {
        let cleanPath = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let parts = cleanPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        let kind = parts[0]
        let token = parts[1]
        guard let entry = entries[token] else { return nil }

        if kind == "media" || kind == "sub" {
            return (entry, token, nil)
        }
        if kind == "hls", parts.count >= 3,
           let decoded = Self.decodeBase64URL(parts[2]),
           let target = URL(string: decoded),
           let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return (entry, token, target)
        }
        return nil
    }

    fileprivate func startUpstreamTask(_ request: URLRequest, handler: CastHTTPConnection) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.delegate = handler
        task.resume()
        return task
    }

    /// 改写 m3u8 播放列表里的相对/绝对资源地址与 `URI="..."` 属性为局域网中转路径。
    func rewritePlaylist(_ text: String, base: URL, token: String, host: String? = nil, port: UInt16? = nil) -> String {
        let activeHost = host ?? advertisedHost
        let activePort = port ?? self.port
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let stripped = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return stripped }

            if trimmed.hasPrefix("#") {
                guard trimmed.contains("URI=\"") else { return stripped }
                var result = ""
                var rest = Substring(trimmed)
                while let start = rest.range(of: "URI=\"") {
                    result += rest[..<start.upperBound]
                    rest = rest[start.upperBound...]
                    guard let end = rest.firstIndex(of: "\"") else { break }
                    let ref = String(rest[..<end])
                    result += proxiedHLSURL(ref, base: base, token: token, host: activeHost, port: activePort)
                    rest = rest[end...]
                }
                return result + rest
            }

            return proxiedHLSURL(trimmed, base: base, token: token, host: activeHost, port: activePort)
        }
        return lines.joined(separator: "\n")
    }

    private func proxiedHLSURL(_ reference: String, base: URL, token: String, host: String, port: UInt16) -> String {
        guard let absolute = URL(string: reference, relativeTo: base)?.absoluteURL,
              let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return reference
        }
        let encoded = Self.encodeBase64URL(absolute.absoluteString)
        let rawName = absolute.lastPathComponent
        let cleanName = (rawName.isEmpty || rawName == "/" ? "segment" : rawName)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "segment"
        return "http://\(host):\(port)/hls/\(token)/\(encoded)/\(cleanName)"
    }

    static func encodeBase64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "mov": return "video/quicktime"
        case "m3u8", "m3u": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        case "srt": return "text/srt"
        case "vtt": return "text/vtt"
        case "ass", "ssa": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func parseByteRange(_ header: String, totalLength: Int64) -> ClosedRange<Int64>? {
        guard totalLength > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst(6)).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2 else { return nil }

        let startStr = bounds[0].trimmingCharacters(in: .whitespaces)
        let endStr = bounds[1].trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            guard let suffix = Int64(endStr), suffix > 0 else { return nil }
            let start = max(0, totalLength - suffix)
            return start...(totalLength - 1)
        }
        guard let start = Int64(startStr), start >= 0, start < totalLength else { return nil }
        if endStr.isEmpty {
            return start...(totalLength - 1)
        }
        guard let end = Int64(endStr), end >= start else { return nil }
        return start...min(end, totalLength - 1)
    }

    // MARK: - 连接处理

    fileprivate final class CastHTTPConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let connection: NWConnection
        private weak var server: CastMediaServer?
        private let queue: DispatchQueue
        var onClose: (() -> Void)?

        private var closed = false
        private var headerBuffer = Data()
        private var fileHandle: FileHandle?
        private var fileRemaining: Int64 = 0

        private var activeTask: URLSessionDataTask?
        private var isHeadRequest = false
        private var isProbeRangeHead = false
        private var proxyEntryToken = ""
        private var proxyEntryMime = "application/octet-stream"
        private var proxyTargetURL: URL?
        private var proxyEntryHeaders: [String: String] = [:]
        private var proxyClientRange: String?

        private var isBufferingPlaylist = false
        private var playlistBuffer = Data()
        private var playlistResponseURL: URL?
        private var pendingSendBytes = 0
        private var taskSuspended = false
        private var upstreamResponseHeadersSent = false

        private static let maxHeaderBytes = 65_536
        private static let fileChunkSize = 262_144
        private static let maxPlaylistBytes = 8 * 1024 * 1024
        private static let highWaterBytes = 1_048_576
        private static let lowWaterBytes = 524_288

        init(connection: NWConnection, server: CastMediaServer, queue: DispatchQueue) {
            self.connection = connection
            self.server = server
            self.queue = queue
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
            connection.start(queue: queue)
            readNextHeaderChunk()
        }

        func close() {
            guard !closed else { return }
            closed = true
            activeTask?.cancel()
            activeTask = nil
            try? fileHandle?.close()
            fileHandle = nil
            connection.cancel()
            onClose?()
            onClose = nil
        }

        private func readNextHeaderChunk() {
            guard !closed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.headerBuffer.append(data)
                    if let range = self.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = self.headerBuffer.subdata(in: 0..<range.lowerBound)
                        self.handleHTTPRequest(headerData)
                        return
                    }
                    if self.headerBuffer.count > Self.maxHeaderBytes {
                        self.sendSimpleResponse(status: "431 Request Header Fields Too Large", body: Data())
                        return
                    }
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.readNextHeaderChunk()
                }
            }
        }

        private func handleHTTPRequest(_ headerData: Data) {
            let text = String(decoding: headerData, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                sendSimpleResponse(status: "400 Bad Request", body: Data())
                return
            }
            let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 2 else {
                sendSimpleResponse(status: "400 Bad Request", body: Data())
                return
            }
            let method = String(components[0]).uppercased()
            let path = String(components[1])
            guard method == "GET" || method == "HEAD" else {
                sendSimpleResponse(status: "405 Method Not Allowed", body: Data())
                return
            }
            isHeadRequest = method == "HEAD"

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            guard let server, let resolved = server.resolve(path: path) else {
                sendSimpleResponse(status: "404 Not Found", body: Data("Not Found".utf8))
                return
            }

            switch resolved.entry {
            case .localFile(let fileURL, let mimeType, _):
                serveLocalFile(fileURL, mimeType: mimeType, rangeHeader: headers["range"])
            case .httpProxy(let upstreamURL, let entryHeaders, let mimeType, _):
                let target = resolved.hlsTargetURL ?? upstreamURL
                let effectiveMime = resolved.hlsTargetURL != nil
                    ? CastMediaServer.mimeType(forPathExtension: target.pathExtension)
                    : mimeType
                serveUpstreamHTTP(
                    url: target,
                    token: resolved.token,
                    entryHeaders: entryHeaders,
                    mimeType: effectiveMime,
                    clientRange: headers["range"]
                )
            }
        }

        // MARK: 本地文件流式服务

        private func serveLocalFile(_ url: URL, mimeType: String, rangeHeader: String?) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let sizeNumber = attrs[.size] as? NSNumber else {
                sendSimpleResponse(status: "404 Not Found", body: Data())
                return
            }
            let totalSize = sizeNumber.int64Value

            var status = "200 OK"
            var startOffset: Int64 = 0
            var length = totalSize
            var extraHeaders = ""

            if let rangeHeader {
                guard let parsed = CastMediaServer.parseByteRange(rangeHeader, totalLength: totalSize) else {
                    let response = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalSize)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
                    return
                }
                status = "206 Partial Content"
                startOffset = parsed.lowerBound
                length = parsed.upperBound - parsed.lowerBound + 1
                extraHeaders = "Content-Range: bytes \(parsed.lowerBound)-\(parsed.upperBound)/\(totalSize)\r\n"
            }

            let responseHeaders =
                "HTTP/1.1 \(status)\r\n" +
                "Content-Type: \(mimeType)\r\n" +
                "Content-Length: \(length)\r\n" +
                extraHeaders +
                Self.dlnaHeaders +
                "Connection: close\r\n\r\n"

            if isHeadRequest || length == 0 {
                connection.send(content: Data(responseHeaders.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                sendSimpleResponse(status: "500 Internal Server Error", body: Data())
                return
            }
            do {
                try handle.seek(toOffset: UInt64(startOffset))
            } catch {
                try? handle.close()
                sendSimpleResponse(status: "500 Internal Server Error", body: Data())
                return
            }
            self.fileHandle = handle
            self.fileRemaining = length

            connection.send(content: Data(responseHeaders.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil {
                    self.close()
                    return
                }
                self.sendNextFileChunk()
            })
        }

        private func sendNextFileChunk() {
            guard !closed, let fileHandle else { return }
            if fileRemaining <= 0 {
                close()
                return
            }
            let toRead = Int(min(Int64(Self.fileChunkSize), fileRemaining))
            let chunk: Data?
            do {
                chunk = try fileHandle.read(upToCount: toRead)
            } catch {
                close()
                return
            }
            guard let chunk, !chunk.isEmpty else {
                close()
                return
            }
            fileRemaining -= Int64(chunk.count)
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil {
                    self.close()
                    return
                }
                self.sendNextFileChunk()
            })
        }

        // MARK: 远程/本地代理流转发

        private func serveUpstreamHTTP(
            url: URL,
            token: String,
            entryHeaders: [String: String],
            mimeType: String,
            clientRange: String?
        ) {
            guard let server else { close(); return }
            proxyEntryToken = token
            proxyEntryMime = mimeType
            proxyTargetURL = url
            proxyEntryHeaders = entryHeaders
            proxyClientRange = clientRange

            var request = makeUpstreamRequest(url: url, method: isHeadRequest ? "HEAD" : "GET", range: clientRange)
            if !isHeadRequest, let clientRange {
                request.setValue(clientRange, forHTTPHeaderField: "Range")
            }
            activeTask = server.startUpstreamTask(request, handler: self)
        }

        private func makeUpstreamRequest(url: URL, method: String, range: String?) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            let host = url.host?.lowercased() ?? ""
            let isLocalLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
            if !isLocalLoopback {
                for (key, value) in proxyEntryHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            if let range {
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            return request
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard !closed, activeTask === dataTask else {
                completionHandler(.cancel)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                sendSimpleResponse(status: "502 Bad Gateway", body: Data())
                return
            }

            // 部分上游（如部分直链或简易服务）不支持 HEAD，回退为 1 字节 Range GET 探测总长度。
            if isHeadRequest, !isProbeRangeHead, http.statusCode == 405 || http.statusCode == 501, let server, let target = proxyTargetURL {
                isProbeRangeHead = true
                activeTask?.cancel()
                let probe = makeUpstreamRequest(url: target, method: "GET", range: "bytes=0-0")
                activeTask = server.startUpstreamTask(probe, handler: self)
                completionHandler(.cancel)
                return
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let ext = (http.url ?? proxyTargetURL)?.pathExtension.lowercased() ?? ""
            let isPlaylist = (200..<300).contains(http.statusCode)
                && (contentType.contains("mpegurl") || ext == "m3u8" || ext == "m3u")

            if isPlaylist, !isHeadRequest {
                isBufferingPlaylist = true
                playlistResponseURL = http.url ?? proxyTargetURL
                playlistBuffer.removeAll(keepingCapacity: true)
                completionHandler(.allow)
                return
            }

            let responseMime: String
            if isPlaylist {
                responseMime = "application/vnd.apple.mpegurl"
            } else if !contentType.isEmpty, contentType != "application/octet-stream" {
                responseMime = contentType
            } else {
                responseMime = proxyEntryMime
            }

            var headerLines = [String]()
            if isProbeRangeHead, http.statusCode == 206 {
                headerLines.append("HTTP/1.1 200 OK")
                if let total = Self.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                    headerLines.append("Content-Length: \(total)")
                }
            } else {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                headerLines.append("HTTP/1.1 \(http.statusCode) \(reason)")
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                    headerLines.append("Content-Range: \(contentRange)")
                }
                if let contentLength = http.value(forHTTPHeaderField: "Content-Length") {
                    headerLines.append("Content-Length: \(contentLength)")
                } else if http.expectedContentLength > 0 {
                    headerLines.append("Content-Length: \(http.expectedContentLength)")
                }
            }
            headerLines.append("Content-Type: \(responseMime)")
            headerLines.append("Accept-Ranges: bytes")
            headerLines.append("transferMode.dlna.org: Streaming")
            headerLines.append("contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000")
            headerLines.append("Connection: close")
            let rawHeader = headerLines.joined(separator: "\r\n") + "\r\n\r\n"

            upstreamResponseHeadersSent = true
            if isHeadRequest || isProbeRangeHead {
                connection.send(content: Data(rawHeader.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                completionHandler(.cancel)
            } else {
                connection.send(content: Data(rawHeader.utf8), completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil {
                        self.close()
                    }
                })
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !closed, activeTask === dataTask else { return }
            if isBufferingPlaylist {
                if playlistBuffer.count + data.count > Self.maxPlaylistBytes {
                    dataTask.cancel()
                    sendSimpleResponse(status: "502 Bad Gateway", body: Data())
                    return
                }
                playlistBuffer.append(data)
                return
            }
            guard !isHeadRequest, !isProbeRangeHead else { return }

            let chunkSize = data.count
            pendingSendBytes += chunkSize
            if pendingSendBytes >= Self.highWaterBytes, !taskSuspended {
                taskSuspended = true
                dataTask.suspend()
            }
            connection.send(content: data, completion: .contentProcessed { [weak self, weak dataTask] error in
                guard let self, !self.closed else { return }
                self.pendingSendBytes = max(0, self.pendingSendBytes - chunkSize)
                if error != nil {
                    self.close()
                    return
                }
                if self.taskSuspended, self.pendingSendBytes < Self.lowWaterBytes {
                    self.taskSuspended = false
                    dataTask?.resume()
                }
            })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !closed, activeTask === task else { return }
            activeTask = nil

            if isBufferingPlaylist {
                guard error == nil, let server else {
                    sendSimpleResponse(status: "502 Bad Gateway", body: Data())
                    return
                }
                let text = String(decoding: playlistBuffer, as: UTF8.self)
                let base = playlistResponseURL ?? proxyTargetURL ?? URL(string: "http://127.0.0.1/")!
                let rewritten = server.rewritePlaylist(text, base: base, token: proxyEntryToken)
                let body = Data(rewritten.utf8)
                let headers =
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/vnd.apple.mpegurl\r\n" +
                    "Content-Length: \(body.count)\r\n" +
                    Self.dlnaHeaders +
                    "Connection: close\r\n\r\n"
                var payload = Data(headers.utf8)
                payload.append(body)
                connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }

            if !upstreamResponseHeadersSent, error != nil {
                sendSimpleResponse(status: "502 Bad Gateway", body: Data())
                return
            }

            if isHeadRequest || isProbeRangeHead {
                // 响应头已在 didReceive response 中通过 .finalMessage 排队发送，由其 .contentProcessed 负责收尾关闭。
                return
            }

            connection.send(content: Data(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private func sendSimpleResponse(status: String, body: Data) {
            let headers =
                "HTTP/1.1 \(status)\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Connection: close\r\n\r\n"
            var payload = Data(headers.utf8)
            if !isHeadRequest { payload.append(body) }
            connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private static let dlnaHeaders =
            "Accept-Ranges: bytes\r\n" +
            "transferMode.dlna.org: Streaming\r\n" +
            "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n"

        private static func totalLength(fromContentRange header: String?) -> Int64? {
            guard let header, let slash = header.lastIndex(of: "/") else { return nil }
            let suffix = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            return Int64(suffix)
        }
    }
}
