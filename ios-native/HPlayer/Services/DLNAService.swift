import Darwin
import Foundation

/// 局域网 DLNA 媒体渲染设备（MediaRenderer）。
struct CastDevice: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var manufacturer: String
    var modelName: String
    var host: String
    var locationURL: URL
    var avTransportControlURL: URL
    var renderingControlURL: URL?
    var avTransportServiceType: String
    var renderingControlServiceType: String?
    var isManual: Bool
    var lastUsedAt: Date?

    var subtitleText: String {
        let details = [manufacturer, modelName].filter { !$0.isEmpty }.joined(separator: " · ")
        if details.isEmpty { return host }
        return "\(host) · \(details)"
    }
}

enum DLNAError: LocalizedError {
    case invalidInput(String)
    case deviceNotFound(String)
    case networkFailure(String)
    case soapFault(code: String?, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return msg
        case .deviceNotFound(let msg): return msg
        case .networkFailure(let msg): return msg
        case .soapFault(let code, let message):
            if let code, !code.isEmpty { return "电视返回错误（\(code)）：\(message)" }
            return "电视返回错误：\(message)"
        case .invalidResponse: return "电视返回了无法识别的响应"
        }
    }
}

enum DLNATransportState: String, Equatable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case transitioning = "TRANSITIONING"
    case stopped = "STOPPED"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown

    init(rawState: String) {
        let normalized = rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let matched = DLNATransportState(rawValue: normalized) {
            self = matched
        } else if normalized.contains("PLAY") {
            self = .playing
        } else if normalized.contains("PAUSE") {
            self = .paused
        } else if normalized.contains("TRANSITION") || normalized.contains("BUFFER") {
            self = .transitioning
        } else if normalized.contains("STOP") {
            self = .stopped
        } else if normalized.contains("NO_MEDIA") {
            self = .noMedia
        } else {
            self = .unknown
        }
    }
}

struct DLNAPositionInfo: Equatable {
    let relTime: Double
    let duration: Double
    let trackURI: String
}

// MARK: - SSDP 与 UPnP XML 解析

enum DLNADeviceParser {
    static func parseSSDPHeaders(_ raw: String) -> URL? {
        for line in raw.components(separatedBy: CharacterSet.newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    static func parseDeviceDescription(_ data: Data, locationURL: URL, isManual: Bool = false) -> CastDevice? {
        let delegate = DescriptionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        guard let avService = delegate.services.first(where: { $0.serviceType.contains("AVTransport") }),
              !avService.controlURL.isEmpty else {
            return nil
        }

        let baseURL: URL
        if let rawBase = delegate.urlBase, !rawBase.isEmpty, let parsedBase = URL(string: rawBase) {
            baseURL = parsedBase
        } else {
            baseURL = locationURL
        }

        guard let avControl = resolveControlURL(avService.controlURL, baseURL: baseURL) else { return nil }
        let rcService = delegate.services.first(where: { $0.serviceType.contains("RenderingControl") && !$0.controlURL.isEmpty })
        let rcControl = rcService.flatMap { resolveControlURL($0.controlURL, baseURL: baseURL) }

        let host = locationURL.host ?? avControl.host ?? ""
        let trimmedName = delegate.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? (host.isEmpty ? "DLNA 设备" : host) : trimmedName
        let rawUDN = delegate.udn.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = rawUDN.isEmpty ? "dlna:\(host):\(locationURL.port ?? 80):\(avControl.path)" : rawUDN

        return CastDevice(
            id: id,
            name: name,
            manufacturer: delegate.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: delegate.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host,
            locationURL: locationURL,
            avTransportControlURL: avControl,
            renderingControlURL: rcControl,
            avTransportServiceType: avService.serviceType,
            renderingControlServiceType: rcService?.serviceType,
            isManual: isManual,
            lastUsedAt: nil
        )
    }

    private static func resolveControlURL(_ path: String, baseURL: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private final class DescriptionXMLDelegate: NSObject, XMLParserDelegate {
        struct ParsedService {
            let serviceType: String
            let controlURL: String
        }

        var urlBase: String?
        var friendlyName = ""
        var manufacturer = ""
        var modelName = ""
        var udn = ""
        var services: [ParsedService] = []

        private var deviceDepth = 0
        private var inService = false
        private var currentElement = ""
        private var textBuffer = ""
        private var serviceTypeBuffer = ""
        private var controlURLBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = Self.localName(elementName)
            currentElement = local
            textBuffer = ""
            if local == "device" {
                deviceDepth += 1
            } else if local == "service" {
                inService = true
                serviceTypeBuffer = ""
                controlURLBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = Self.localName(elementName)
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

            if inService {
                switch local {
                case "serviceType": serviceTypeBuffer = value
                case "controlURL": controlURLBuffer = value
                case "service":
                    if !serviceTypeBuffer.isEmpty && !controlURLBuffer.isEmpty {
                        services.append(ParsedService(serviceType: serviceTypeBuffer, controlURL: controlURLBuffer))
                    }
                    inService = false
                default:
                    break
                }
            } else {
                switch local {
                case "URLBase":
                    if urlBase == nil, !value.isEmpty { urlBase = value }
                case "friendlyName":
                    if deviceDepth == 1 || friendlyName.isEmpty { friendlyName = value }
                case "manufacturer":
                    if deviceDepth == 1 || manufacturer.isEmpty { manufacturer = value }
                case "modelName":
                    if deviceDepth == 1 || modelName.isEmpty { modelName = value }
                case "UDN":
                    if deviceDepth == 1 || udn.isEmpty { udn = value }
                case "device":
                    deviceDepth = max(0, deviceDepth - 1)
                default:
                    break
                }
            }
            textBuffer = ""
        }

        private static func localName(_ name: String) -> String {
            if let colon = name.lastIndex(of: ":") {
                return String(name[name.index(after: colon)...])
            }
            return name
        }
    }
}

// MARK: - UPnP SOAP 控制客户端

final class DLNASoapClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 10
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func setAVTransportURI(device: CastDevice, uri: URL, title: String, mimeType: String, subtitleURL: URL? = nil) async throws {
        let didl = Self.buildDIDLLite(uri: uri, title: title, mimeType: mimeType, subtitleURL: subtitleURL)
        let body = """
        <u:SetAVTransportURI xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
          <CurrentURI>\(Self.xmlEscaped(uri.absoluteString))</CurrentURI>
          <CurrentURIMetaData>\(Self.xmlEscaped(didl))</CurrentURIMetaData>
        </u:SetAVTransportURI>
        """
        _ = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "SetAVTransportURI", bodyXML: body)
    }

    func play(device: CastDevice) async throws {
        let body = """
        <u:Play xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
          <Speed>1</Speed>
        </u:Play>
        """
        _ = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "Play", bodyXML: body)
    }

    func pause(device: CastDevice) async throws {
        let body = """
        <u:Pause xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
        </u:Pause>
        """
        _ = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "Pause", bodyXML: body)
    }

    func stop(device: CastDevice) async throws {
        let body = """
        <u:Stop xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
        </u:Stop>
        """
        _ = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "Stop", bodyXML: body)
    }

    func seek(device: CastDevice, to seconds: Double) async throws {
        let target = Self.formatDLNATime(seconds)
        let body = """
        <u:Seek xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
          <Unit>REL_TIME</Unit>
          <Target>\(target)</Target>
        </u:Seek>
        """
        _ = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "Seek", bodyXML: body)
    }

    func getPositionInfo(device: CastDevice) async throws -> DLNAPositionInfo {
        let body = """
        <u:GetPositionInfo xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
        </u:GetPositionInfo>
        """
        let values = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "GetPositionInfo", bodyXML: body)
        let relTime = Self.parseDLNATime(values["RelTime"] ?? "") ?? 0
        let duration = Self.parseDLNATime(values["TrackDuration"] ?? "") ?? 0
        let trackURI = values["TrackURI"] ?? ""
        return DLNAPositionInfo(relTime: relTime, duration: duration, trackURI: trackURI)
    }

    func getTransportInfo(device: CastDevice) async throws -> DLNATransportState {
        let body = """
        <u:GetTransportInfo xmlns:u="\(Self.xmlEscaped(device.avTransportServiceType))">
          <InstanceID>0</InstanceID>
        </u:GetTransportInfo>
        """
        let values = try await sendAction(url: device.avTransportControlURL, serviceType: device.avTransportServiceType, action: "GetTransportInfo", bodyXML: body)
        return DLNATransportState(rawState: values["CurrentTransportState"] ?? "")
    }

    func getVolume(device: CastDevice) async -> Int? {
        guard let controlURL = device.renderingControlURL,
              let serviceType = device.renderingControlServiceType else { return nil }
        let body = """
        <u:GetVolume xmlns:u="\(Self.xmlEscaped(serviceType))">
          <InstanceID>0</InstanceID>
          <Channel>Master</Channel>
        </u:GetVolume>
        """
        guard let values = try? await sendAction(url: controlURL, serviceType: serviceType, action: "GetVolume", bodyXML: body),
              let raw = values["CurrentVolume"], let volume = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return min(max(volume, 0), 100)
    }

    func setVolume(device: CastDevice, volume: Int) async throws {
        guard let controlURL = device.renderingControlURL,
              let serviceType = device.renderingControlServiceType else { return }
        let clamped = min(max(volume, 0), 100)
        let body = """
        <u:SetVolume xmlns:u="\(Self.xmlEscaped(serviceType))">
          <InstanceID>0</InstanceID>
          <Channel>Master</Channel>
          <DesiredVolume>\(clamped)</DesiredVolume>
        </u:SetVolume>
        """
        _ = try await sendAction(url: controlURL, serviceType: serviceType, action: "SetVolume", bodyXML: body)
    }

    // MARK: - SOAP 编码与响应解析

    private func sendAction(url: URL, serviceType: String, action: String, bodyXML: String) async throws -> [String: String] {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            \(bodyXML)
          </s:Body>
        </s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DLNAError.networkFailure("无法连接到电视：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DLNAError.invalidResponse
        }

        let parsed = SOAPResponseParser.parse(data)
        if !(200..<300).contains(http.statusCode) || parsed["Fault"] != nil || parsed["faultstring"] != nil || parsed["errorCode"] != nil {
            let code = parsed["errorCode"]
            let message = parsed["errorDescription"] ?? parsed["faultstring"] ?? "HTTP \(http.statusCode)"
            throw DLNAError.soapFault(code: code, message: message)
        }
        return parsed
    }

    static func buildDIDLLite(uri: URL, title: String, mimeType: String, subtitleURL: URL? = nil) -> String {
        let safeTitle = xmlEscaped(title.isEmpty ? "HPlayer 视频" : title)
        let safeURI = xmlEscaped(uri.absoluteString)
        let safeMime = xmlEscaped(mimeType)
        let protocolInfo = "http-get:*:\(safeMime):DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"

        var subtitleTag = ""
        if let subtitleURL {
            let ext = subtitleURL.pathExtension.lowercased()
            let subType = ext == "vtt" ? "vtt" : "srt"
            let subMime = ext == "vtt" ? "text/vtt" : "text/srt"
            let safeSub = xmlEscaped(subtitleURL.absoluteString)
            subtitleTag = """
            <res protocolInfo="http-get:*:\(subMime):*">\(safeSub)</res>
            <sec:CaptionInfoEx sec:type="\(subType)">\(safeSub)</sec:CaptionInfoEx>
            """
        }

        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:sec="http://www.sec.co.kr/">
          <item id="0" parentID="-1" restricted="1">
            <dc:title>\(safeTitle)</dc:title>
            <upnp:class>object.item.videoItem</upnp:class>
            <res protocolInfo="\(protocolInfo)">\(safeURI)</res>
            \(subtitleTag)
          </item>
        </DIDL-Lite>
        """
    }

    static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func formatDLNATime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func parseDLNATime(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper == "NOT_IMPLEMENTED" || upper == "NULL" || trimmed.contains("-") {
            return nil
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return max(0, h * 3600 + m * 60 + s)
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return max(0, m * 60 + s)
        }
    }

    private final class SOAPResponseParser: NSObject, XMLParserDelegate {
        private var values: [String: String] = [:]
        private var currentKey = ""
        private var buffer = ""

        static func parse(_ data: Data) -> [String: String] {
            let delegate = SOAPResponseParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            _ = parser.parse()
            return delegate.values
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if let colon = elementName.lastIndex(of: ":") {
                currentKey = String(elementName[elementName.index(after: colon)...])
            } else {
                currentKey = elementName
            }
            buffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local: String
            if let colon = elementName.lastIndex(of: ":") {
                local = String(elementName[elementName.index(after: colon)...])
            } else {
                local = elementName
            }
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                values[local] = text
            }
            buffer = ""
        }
    }
}

// MARK: - 局域网设备搜索与历史管理

@MainActor
final class DLNADiscovery: ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var multicastRestricted = false
    @Published private(set) var lastScanError = ""

    private let defaults: UserDefaults
    private let storageKey = "hplayer.cast.savedDevices.v1"
    private let session: URLSession
    private var scanTask: Task<Void, Never>?
    private var savedDevices: [CastDevice] = []

    static let commonPorts: [Int] = [49152, 49153, 49154, 8200, 1025, 1567, 1667, 9999, 55000, 7676, 60606, 38400, 8080, 8060]
    static let commonPaths: [String] = [
        "/description.xml",
        "/dmr/description.xml",
        "/DeviceDescription.xml",
        "/rootDesc.xml",
        "/dlna/description.xml",
        "/MediaRenderer/desc.xml",
        "/upnp/desc/aios_device/aios_device.xml"
    ]

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2.0
            config.timeoutIntervalForResource = 3.0
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        loadSavedDevices()
    }

    func startScan() {
        scanTask?.cancel()
        isScanning = true
        lastScanError = ""
        multicastRestricted = false
        mergeSavedIntoVisible()

        let savedSnapshot = savedDevices
        let urlSession = session
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isScanning = false }

            // 1. 先单播刷新已保存设备（不依赖 multicast 权限）
            await withTaskGroup(of: CastDevice?.self) { group in
                for saved in savedSnapshot {
                    group.addTask {
                        await Self.fetchDevice(at: saved.locationURL, isManual: saved.isManual, session: urlSession, timeout: 1.5)
                    }
                }
                for await refreshed in group {
                    if let refreshed { self.upsertDevice(refreshed) }
                }
            }

            guard !Task.isCancelled else { return }

            // 2. SSDP 局域网广播发现
            let ssdpResult = await Self.performSSDPSearch(duration: 2.2)
            guard !Task.isCancelled else { return }
            if ssdpResult.permissionDenied {
                self.multicastRestricted = true
            }

            if !ssdpResult.locations.isEmpty {
                await withTaskGroup(of: CastDevice?.self) { group in
                    for location in ssdpResult.locations {
                        group.addTask {
                            await Self.fetchDevice(at: location, isManual: false, session: urlSession, timeout: 2.5)
                        }
                    }
                    for await found in group {
                        if let found { self.upsertDevice(found) }
                    }
                }
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func addManualDevice(input: String) async throws -> CastDevice {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DLNAError.invalidInput("请输入电视的 IP 地址或设备描述链接")
        }

        let candidates = Self.candidateDescriptionURLs(for: trimmed)
        guard !candidates.isEmpty else {
            throw DLNAError.invalidInput("地址格式无效，请填写如 192.168.1.20 或 http://192.168.1.20:49152/description.xml")
        }

        let urlSession = session
        let found: CastDevice? = await withTaskGroup(of: CastDevice?.self) { group in
            for url in candidates {
                group.addTask {
                    await Self.fetchDevice(at: url, isManual: true, session: urlSession, timeout: 1.4)
                }
            }
            for await device in group {
                if let device {
                    group.cancelAll()
                    return device
                }
            }
            return nil
        }

        guard var device = found else {
            throw DLNAError.deviceNotFound("未在该地址找到支持 DLNA 投屏的电视，请确认电视已开机且在同一 Wi-Fi 下")
        }
        device.lastUsedAt = Date()
        saveDevice(device)
        upsertDevice(device)
        return device
    }

    func markUsed(_ device: CastDevice) {
        var updated = device
        updated.lastUsedAt = Date()
        saveDevice(updated)
        upsertDevice(updated)
    }

    func removeSavedDevice(id: String) {
        savedDevices.removeAll { $0.id == id }
        persistSavedDevices()
        devices.removeAll { $0.id == id }
    }

    func isSaved(id: String) -> Bool {
        savedDevices.contains { $0.id == id }
    }

    // MARK: - 候选地址构造（便于单测）

    static func candidateDescriptionURLs(for rawInput: String) -> [URL] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let direct = URL(string: trimmed),
           let scheme = direct.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = direct.host, !host.isEmpty {
            if direct.path.isEmpty || direct.path == "/" {
                let portPart = direct.port.map { ":\($0)" } ?? ""
                return commonPaths.compactMap { URL(string: "\(scheme)://\(host)\(portPart)\($0)") }
            }
            return [direct]
        }

        // 处理 IP:Port 或纯 IP
        if let parsed = URL(string: "http://\(trimmed)"), let host = parsed.host, !host.isEmpty {
            if let port = parsed.port {
                return commonPaths.compactMap { URL(string: "http://\(host):\(port)\($0)") }
            }
            var urls: [URL] = []
            for port in commonPorts {
                for path in commonPaths {
                    if let url = URL(string: "http://\(host):\(port)\(path)") {
                        urls.append(url)
                    }
                }
            }
            return urls
        }

        return []
    }

    // MARK: - 持久化与排序

    private func loadSavedDevices() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CastDevice].self, from: data) else {
            savedDevices = []
            return
        }
        savedDevices = decoded
        mergeSavedIntoVisible()
    }

    private func persistSavedDevices() {
        if let data = try? JSONEncoder().encode(savedDevices) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func saveDevice(_ device: CastDevice) {
        if let idx = savedDevices.firstIndex(where: { $0.id == device.id }) {
            savedDevices[idx] = device
        } else {
            savedDevices.append(device)
        }
        persistSavedDevices()
    }

    private func mergeSavedIntoVisible() {
        for saved in savedDevices {
            upsertDevice(saved)
        }
    }

    private func upsertDevice(_ device: CastDevice) {
        var merged = device
        if let saved = savedDevices.first(where: { $0.id == device.id }) {
            if merged.lastUsedAt == nil { merged.lastUsedAt = saved.lastUsedAt }
            if saved.isManual { merged.isManual = true }
        }
        if let idx = devices.firstIndex(where: { $0.id == merged.id }) {
            devices[idx] = merged
        } else {
            devices.append(merged)
        }
        devices.sort { lhs, rhs in
            let lDate = lhs.lastUsedAt ?? .distantPast
            let rDate = rhs.lastUsedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - SSDP & 描述拉取

    private nonisolated static func fetchDevice(at url: URL, isManual: Bool, session: URLSession, timeout: TimeInterval) async -> CastDevice? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return DLNADeviceParser.parseDeviceDescription(data, locationURL: url, isManual: isManual)
    }

    private struct SSDPSearchResult: Sendable {
        let locations: [URL]
        let permissionDenied: Bool
    }

    private nonisolated static func performSSDPSearch(duration: TimeInterval) async -> SSDPSearchResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else {
                    continuation.resume(returning: SSDPSearchResult(locations: [], permissionDenied: errno == EPERM || errno == EACCES))
                    return
                }
                defer { close(fd) }

                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

                var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                var bindAddr = sockaddr_in()
                bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                bindAddr.sin_family = sa_family_t(AF_INET)
                bindAddr.sin_port = 0
                bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
                let bindResult = withUnsafePointer(to: &bindAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0 else {
                    continuation.resume(returning: SSDPSearchResult(locations: [], permissionDenied: errno == EPERM || errno == EACCES))
                    return
                }

                var destAddr = sockaddr_in()
                destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                destAddr.sin_family = sa_family_t(AF_INET)
                destAddr.sin_port = UInt16(1900).bigEndian
                inet_pton(AF_INET, "239.255.255.250", &destAddr.sin_addr)

                let targets = [
                    "urn:schemas-upnp-org:service:AVTransport:1",
                    "urn:schemas-upnp-org:device:MediaRenderer:1",
                    "ssdp:all"
                ]

                var permissionDenied = false
                for st in targets {
                    let message =
                        "M-SEARCH * HTTP/1.1\r\n" +
                        "HOST: 239.255.255.250:1900\r\n" +
                        "MAN: \"ssdp:discover\"\r\n" +
                        "MX: 2\r\n" +
                        "ST: \(st)\r\n\r\n"
                    let payload = Array(message.utf8)
                    let sent = payload.withUnsafeBytes { rawBuffer in
                        withUnsafePointer(to: &destAddr) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if sent < 0 && (errno == EPERM || errno == EACCES) {
                        permissionDenied = true
                        break
                    }
                }

                if permissionDenied {
                    continuation.resume(returning: SSDPSearchResult(locations: [], permissionDenied: true))
                    return
                }

                var seen = Set<URL>()
                var locations: [URL] = []
                let deadline = Date().addingTimeInterval(duration)
                var buffer = [UInt8](repeating: 0, count: 4096)

                while Date() < deadline {
                    let received = buffer.withUnsafeMutableBytes { rawBuffer in
                        recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
                    }
                    if received > 0 {
                        let text = String(decoding: buffer[..<received], as: UTF8.self)
                        if let url = DLNADeviceParser.parseSSDPHeaders(text), seen.insert(url).inserted {
                            locations.append(url)
                        }
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        break
                    }
                }

                continuation.resume(returning: SSDPSearchResult(locations: locations, permissionDenied: false))
            }
        }
    }
}
