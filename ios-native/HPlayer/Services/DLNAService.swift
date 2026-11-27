import Darwin
import Foundation
import Network

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
    private static let trimCharacterSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    static func parseSSDPHeaders(_ raw: String) -> URL? {
        for line in raw.components(separatedBy: CharacterSet.newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: trimCharacterSet).lowercased()
            guard key == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: trimCharacterSet)
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    static func parseDeviceDescription(_ data: Data, locationURL: URL, isManual: Bool = false) -> CastDevice? {
        let cleaned = sanitizeXMLData(data)
        guard !cleaned.isEmpty else { return nil }

        let delegate = DescriptionXMLDelegate()
        let parser = XMLParser(data: cleaned)
        parser.delegate = delegate
        _ = parser.parse()

        guard let avService = delegate.services.first(where: {
            $0.serviceType.range(of: "AVTransport", options: .caseInsensitive) != nil && !$0.controlURL.isEmpty
        }) else {
            return nil
        }

        let baseURL: URL
        if let rawBase = delegate.urlBase, !rawBase.isEmpty,
           let parsedBase = URL(string: rawBase),
           let scheme = parsedBase.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let baseHost = parsedBase.host, !baseHost.isEmpty,
           shouldUseURLBase(baseHost: baseHost, locationHost: locationURL.host) {
            baseURL = parsedBase
        } else {
            baseURL = locationURL
        }

        guard let avControl = resolveControlURL(avService.controlURL, baseURL: baseURL) else { return nil }
        let rcService = delegate.services.first(where: {
            $0.serviceType.range(of: "RenderingControl", options: .caseInsensitive) != nil && !$0.controlURL.isEmpty
        })
        let rcControl = rcService.flatMap { resolveControlURL($0.controlURL, baseURL: baseURL) }

        let host = locationURL.host ?? avControl.host ?? ""
        let trimmedName = delegate.friendlyName.trimmingCharacters(in: trimCharacterSet)
        let name = trimmedName.isEmpty ? (host.isEmpty ? "DLNA 设备" : host) : trimmedName
        let rawUDN = delegate.udn.trimmingCharacters(in: trimCharacterSet)
        let id = rawUDN.isEmpty ? "dlna:\(host):\(locationURL.port ?? 80):\(avControl.path)" : rawUDN

        return CastDevice(
            id: id,
            name: name,
            manufacturer: delegate.manufacturer.trimmingCharacters(in: trimCharacterSet),
            modelName: delegate.modelName.trimmingCharacters(in: trimCharacterSet),
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

    private static func shouldUseURLBase(baseHost: String, locationHost: String?) -> Bool {
        let lowerBase = baseHost.lowercased()
        if lowerBase == "0.0.0.0" { return false }
        let lowerLocation = locationHost?.lowercased() ?? ""
        if loopbackHosts.contains(lowerBase) && !loopbackHosts.contains(lowerLocation) {
            return false
        }
        return true
    }

    private static func sanitizeXMLData(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        while let first = bytes.first, first == 0x00 || first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes.removeFirst()
        }
        while let last = bytes.last, last == 0x00 || last == 0x20 || last == 0x09 || last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { return Data() }

        let stripped = Data(bytes)
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        var text: String?
        var decodedNonUTF8 = false
        if let utf8 = String(data: stripped, encoding: .utf8) {
            text = utf8
        } else if let gb = String(data: stripped, encoding: gbEncoding) {
            text = gb
            decodedNonUTF8 = true
        } else if let latin1 = String(data: stripped, encoding: .isoLatin1) {
            text = latin1
            decodedNonUTF8 = true
        }
        guard let text else { return stripped }

        return cleanXMLScalarsAndHeader(
            originalText: text,
            decodedNonUTF8: decodedNonUTF8
        )
    }

    private static func cleanXMLScalarsAndHeader(originalText: String, decodedNonUTF8: Bool) -> Data {
        var xmlText = originalText
        if decodedNonUTF8 {
            if let regex = try? NSRegularExpression(pattern: #"(?i)(<\?xml[^>]*encoding\s*=\s*["'])[^"']+(["'][^>]*\?>)"#) {
                let range = NSRange(xmlText.startIndex..., in: xmlText)
                xmlText = regex.stringByReplacingMatches(in: xmlText, range: range, withTemplate: "$1utf-8$2")
            }
        } else if let regex = try? NSRegularExpression(pattern: #"(?i)(<\?xml[^>]*encoding\s*=\s*["'])(?:gbk|gb2312|gb18030)(["'][^>]*\?>)"#) {
            let range = NSRange(xmlText.startIndex..., in: xmlText)
            xmlText = regex.stringByReplacingMatches(in: xmlText, range: range, withTemplate: "$1utf-8$2")
        }

        var filtered = String.UnicodeScalarView()
        filtered.reserveCapacity(xmlText.unicodeScalars.count)
        for scalar in xmlText.unicodeScalars {
            if scalar.value >= 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                filtered.append(scalar)
            }
        }
        return Data(String(filtered).utf8)
    }

    private static func resolveControlURL(_ path: String, baseURL: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: trimCharacterSet)
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
        private var textBuffer = ""
        private var serviceTypeBuffer = ""
        private var controlURLBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = Self.localName(elementName).lowercased()
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
            let local = Self.localName(elementName).lowercased()
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

            if inService {
                switch local {
                case "servicetype": serviceTypeBuffer = value
                case "controlurl": controlURLBuffer = value
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
                case "urlbase":
                    if urlBase == nil, !value.isEmpty { urlBase = value }
                case "friendlyname":
                    if deviceDepth == 1 || friendlyName.isEmpty { friendlyName = value }
                case "manufacturer":
                    if deviceDepth == 1 || manufacturer.isEmpty { manufacturer = value }
                case "modelname":
                    if deviceDepth == 1 || modelName.isEmpty { modelName = value }
                case "udn":
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
            config.connectionProxyDictionary = [:]
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
            throw DLNAError.networkFailure("无法连接到电视：\(error.userMessage)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DLNAError.invalidResponse
        }

        let parsed = SOAPResponseParser.parse(data)
        if !(200..<300).contains(http.statusCode) || parsed["Fault"] != nil || parsed["faultstring"] != nil || parsed["errorCode"] != nil {
            let code = parsed["errorCode"]
            let rawMessage = parsed["errorDescription"] ?? parsed["faultstring"] ?? "HTTP \(http.statusCode)"
            let message = NetworkErrorFormatter.translateDLNAFault(rawMessage)
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
    enum ScanDiagnosis: Equatable {
        case none
        case noWiFi
        case localNetworkDenied
        case multicastRestrictedNoDevices
    }

    struct ManualTarget: Equatable, Sendable {
        let host: String
        let explicitPort: Int?
        let directURL: URL?
        let scheme: String
    }

    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var multicastRestricted = false
    @Published private(set) var scanDiagnosis: ScanDiagnosis = .none
    @Published private(set) var localWiFiIP: String? = nil
    @Published private(set) var lastScanError = ""

    private let defaults: UserDefaults
    private let storageKey = "hplayer.cast.savedDevices.v1"
    private let session: URLSession
    private let usesCustomSession: Bool
    private let ssdpPort: UInt16
    private var scanTask: Task<Void, Never>?
    private var savedDevices: [CastDevice] = []
    private let browserHolder = LocalNetworkBrowserHolder()

    static let commonPorts: [Int] = [
        49152, 49153, 49154, 49155, 49156,
        38520, 25826, 56789, 59152, 49192,
        8200, 1567, 1667, 1517, 1025,
        9999, 9197, 9080, 55000, 7676,
        60606, 38400, 36895, 52235, 52323,
        4004, 5200, 52525, 55555, 1901,
        8080, 8008, 8060, 8192, 8888,
        2869, 10243, 12345, 9957, 9958
    ]
    static let commonPaths: [String] = [
        "/description.xml",
        "/dmr/description.xml",
        "/dlna/description.xml",
        "/dlna/dmr.xml",
        "/dlna/renderonly",
        "/DeviceDescription.xml",
        "/rootDesc.xml",
        "/desc.xml",
        "/device.xml",
        "/dmr.xml",
        "/MediaRenderer/desc.xml",
        "/MediaRenderer1.xml",
        "/upnp/desc.xml",
        "/upnp/description.xml",
        "/upnp/desc/aios_device/aios_device.xml",
        "/xml/description.xml",
        "/"
    ]

    init(defaults: UserDefaults = .standard, session: URLSession? = nil, ssdpPort: UInt16 = 1900) {
        self.defaults = defaults
        self.usesCustomSession = (session != nil)
        self.ssdpPort = ssdpPort
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2.5
            config.timeoutIntervalForResource = 12.0
            config.httpMaximumConnectionsPerHost = 24
            config.connectionProxyDictionary = [:]
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        loadSavedDevices()
    }

    deinit {
        browserHolder.stop()
    }

    func startScan() {
        scanTask?.cancel()
        isScanning = true
        lastScanError = ""
        multicastRestricted = false
        scanDiagnosis = .none
        mergeSavedIntoVisible()

        let wifiInfo = CastMediaServer.wifiNetworkInfo()
        localWiFiIP = wifiInfo?.ip
        startLocalNetworkProbe()

        let savedSnapshot = savedDevices
        let urlSession = session
        let configuredSSDPPort = ssdpPort
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isScanning = false }

            // 1. 先单播刷新已保存设备；若原随机端口失效，按设备 host 自动单播 SSDP 寻回最新端口
            await withTaskGroup(of: CastDevice?.self) { group in
                for saved in savedSnapshot {
                    group.addTask {
                        if let refreshed = await Self.fetchDevice(
                            at: saved.locationURL,
                            isManual: saved.isManual,
                            session: urlSession,
                            timeout: 1.5
                        ) {
                            return refreshed
                        }
                        guard !saved.host.isEmpty else { return nil }
                        let rediscovered = await Self.performUnicastSSDPForHost(
                            host: saved.host,
                            ssdpPort: configuredSSDPPort,
                            wifiInfo: wifiInfo,
                            duration: 0.9
                        )
                        for url in rediscovered.locations {
                            if let updated = await Self.fetchDevice(
                                at: url,
                                isManual: saved.isManual,
                                session: urlSession,
                                timeout: 1.5
                            ) {
                                return updated
                            }
                        }
                        return nil
                    }
                }
                for await refreshed in group {
                    if let refreshed {
                        self.saveDevice(refreshed)
                        self.upsertDevice(refreshed)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            guard let wifiInfo else {
                self.scanDiagnosis = .noWiFi
                return
            }

            // 2. 混合发现（组播容错 + 定向广播 + 同网段 /24 单播 SSDP 流式探测）
            var capturedContinuation: AsyncStream<URL>.Continuation?
            let locationStream = AsyncStream<URL> { capturedContinuation = $0 }
            let locationContinuation = capturedContinuation!

            async let ssdpSearch: SSDPSearchResult = {
                defer { locationContinuation.finish() }
                return await Self.performHybridSSDPSearch(
                    wifiInfo: wifiInfo,
                    ssdpPort: configuredSSDPPort,
                    duration: 3.2
                ) { url in
                    locationContinuation.yield(url)
                }
            }()

            await withTaskGroup(of: Void.self) { group in
                for await location in locationStream {
                    if Task.isCancelled { break }
                    group.addTask { [weak self] in
                        if let found = await Self.fetchDevice(
                            at: location,
                            isManual: false,
                            session: urlSession,
                            timeout: 2.5
                        ) {
                            await MainActor.run {
                                self?.upsertDevice(found)
                            }
                        }
                    }
                }
            }

            let ssdpResult = await ssdpSearch
            guard !Task.isCancelled else { return }

            if self.devices.isEmpty {
                if ssdpResult.blockedByLocalNetwork {
                    self.scanDiagnosis = .localNetworkDenied
                    self.multicastRestricted = true
                } else if ssdpResult.multicastBlocked {
                    self.scanDiagnosis = .multicastRestrictedNoDevices
                    self.multicastRestricted = true
                }
            } else {
                self.scanDiagnosis = .none
                self.multicastRestricted = false
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        browserHolder.stop()
    }

    func addManualDevice(input: String) async throws -> CastDevice {
        let normalized = Self.normalizeManualInput(input)
        guard !normalized.isEmpty else {
            throw DLNAError.invalidInput("请输入电视或机顶盒的 IP 地址（如 192.168.1.20）或设备描述链接")
        }

        guard let target = Self.parseManualTarget(normalized) else {
            throw DLNAError.invalidInput("地址格式无效，请填写如 192.168.1.20 或 http://192.168.1.20:49152/description.xml")
        }

        let wifiInfo = CastMediaServer.wifiNetworkInfo()
        self.localWiFiIP = wifiInfo?.ip
        let urlSession = session
        let configuredSSDPPort = ssdpPort
        var found: CastDevice?
        var ssdpBlocked = false
        var tcpBlocked = false

        // 情形 A：用户填写了带非根路径的完整描述 URL
        if let directURL = target.directURL {
            found = await Self.fetchDevice(at: directURL, isManual: true, session: urlSession, timeout: 3.5)
        }

        // 情形 B：填写了明确端口但未指定 XML 路径（如 192.168.1.20:9999）— 并行跑 HTTP 路径与单播 SSDP
        if found == nil, let port = target.explicitPort {
            let portURLs = Self.commonPaths.compactMap { URL(string: "\(target.scheme)://\(target.host):\(port)\($0)") }
            let result = await withTaskGroup(of: (CastDevice?, Bool).self) { group -> (CastDevice?, Bool) in
                group.addTask {
                    let device = await Self.probeURLsBounded(portURLs, maxConcurrent: 12, session: urlSession, timeout: 2.2)
                    return (device, false)
                }
                group.addTask {
                    await Self.findDeviceViaUnicastSSDP(
                        host: target.host,
                        ssdpPort: configuredSSDPPort,
                        wifiInfo: wifiInfo,
                        session: urlSession,
                        duration: 1.4
                    )
                }
                var sawBlocked = false
                for await (device, blocked) in group {
                    if blocked { sawBlocked = true }
                    if let device {
                        group.cancelAll()
                        return (device, sawBlocked)
                    }
                }
                return (nil, sawBlocked)
            }
            found = result.0
            if result.1 { ssdpBlocked = true }
        }

        // 情形 C：纯 IP 或无端口 URL（先向 <host>:1900 发单播 SSDP，解决随机高端口 + UUID 路径问题；再做 TCP 端口预筛 + 限流 HTTP 探测）
        if found == nil && target.explicitPort == nil {
            let ssdpHit = await Self.findDeviceViaUnicastSSDP(
                host: target.host,
                ssdpPort: configuredSSDPPort,
                wifiInfo: wifiInfo,
                session: urlSession,
                duration: 1.4
            )
            found = ssdpHit.0
            ssdpBlocked = ssdpHit.1

            if found == nil {
                if !usesCustomSession && Self.isIPv4Address(target.host) {
                    let tcpProbe = await Self.probeOpenTCPPorts(
                        host: target.host,
                        ports: Self.commonPorts,
                        wifiInfo: wifiInfo
                    )
                    tcpBlocked = tcpProbe.blockedByLocalNetwork
                    if !tcpProbe.openPorts.isEmpty {
                        var targetedURLs: [URL] = []
                        targetedURLs.reserveCapacity(tcpProbe.openPorts.count * Self.commonPaths.count)
                        for port in tcpProbe.openPorts {
                            for path in Self.commonPaths {
                                if let url = URL(string: "\(target.scheme)://\(target.host):\(port)\(path)") {
                                    targetedURLs.append(url)
                                }
                            }
                        }
                        found = await Self.probeURLsBounded(targetedURLs, maxConcurrent: 16, session: urlSession, timeout: 2.2)
                    }
                } else {
                    let candidates = Self.candidateDescriptionURLs(for: normalized)
                    found = await Self.probeURLsBounded(candidates, maxConcurrent: 16, session: urlSession, timeout: 2.0)
                }
            }
        }

        guard var device = found else {
            if ssdpBlocked && (tcpBlocked || wifiInfo != nil) {
                throw DLNAError.networkFailure("无法访问局域网设备，请前往系统「设置 → 隐私与安全性 → 本地网络」确认已允许 HPlayer，并关闭可能拦截局域网的 VPN/代理")
            }
            if let currentIP = CastMediaServer.wifiIPv4Address() {
                throw DLNAError.deviceNotFound(
                    "未在 \(target.host) 找到支持 DLNA 投屏的设备（本机 Wi-Fi：\(currentIP)）。请确认机顶盒与手机在同一局域网、已开启投屏/乐播等接收应用，且未开启拦截局域网的 VPN/代理。"
                )
            }
            throw DLNAError.deviceNotFound("当前手机未连接 Wi-Fi，请连接与机顶盒相同的 Wi-Fi 后重试")
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

    // MARK: - 候选地址构造与输入标准化（便于单测）

    static func normalizeManualInput(_ rawInput: String) -> String {
        rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "／", with: "/")
    }

    static func parseManualTarget(_ rawInput: String) -> ManualTarget? {
        let normalized = normalizeManualInput(rawInput)
        guard !normalized.isEmpty else { return nil }

        if let direct = URL(string: normalized),
           let scheme = direct.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = direct.host, !host.isEmpty {
            let isRootPath = direct.path.isEmpty || direct.path == "/"
            return ManualTarget(
                host: host,
                explicitPort: direct.port,
                directURL: isRootPath ? nil : direct,
                scheme: scheme
            )
        }

        if let parsed = URL(string: "http://\(normalized)"),
           let host = parsed.host, !host.isEmpty {
            let isRootPath = parsed.path.isEmpty || parsed.path == "/"
            return ManualTarget(
                host: host,
                explicitPort: parsed.port,
                directURL: isRootPath ? nil : parsed,
                scheme: "http"
            )
        }
        return nil
    }

    static func candidateDescriptionURLs(for rawInput: String) -> [URL] {
        guard let target = parseManualTarget(rawInput) else { return [] }
        if let direct = target.directURL {
            return [direct]
        }
        if let port = target.explicitPort {
            return commonPaths.compactMap { URL(string: "\(target.scheme)://\(target.host):\(port)\($0)") }
        }
        var urls: [URL] = []
        urls.reserveCapacity(commonPorts.count * commonPaths.count)
        for port in commonPorts {
            for path in commonPaths {
                if let url = URL(string: "\(target.scheme)://\(target.host):\(port)\(path)") {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    // MARK: - 本地网络权限监听

    private func startLocalNetworkProbe() {
        browserHolder.start(
            onWaiting: { [weak self] isPolicyDenied in
                guard isPolicyDenied else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.devices.isEmpty {
                        self.scanDiagnosis = .localNetworkDenied
                        self.multicastRestricted = true
                    }
                }
            },
            onBecameReadyAfterWait: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.devices.isEmpty {
                        self.startScan()
                    }
                }
            }
        )
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

    private nonisolated static func probeURLsBounded(
        _ urls: [URL],
        maxConcurrent: Int,
        session: URLSession,
        timeout: TimeInterval
    ) async -> CastDevice? {
        guard !urls.isEmpty else { return nil }
        let limit = max(1, maxConcurrent)
        return await withTaskGroup(of: CastDevice?.self) { group in
            var index = 0
            while index < min(limit, urls.count) {
                let url = urls[index]
                index += 1
                group.addTask {
                    await fetchDevice(at: url, isManual: true, session: session, timeout: timeout)
                }
            }
            while let result = await group.next() {
                if let device = result {
                    group.cancelAll()
                    return device
                }
                if index < urls.count && !Task.isCancelled {
                    let nextURL = urls[index]
                    index += 1
                    group.addTask {
                        await fetchDevice(at: nextURL, isManual: true, session: session, timeout: timeout)
                    }
                }
            }
            return nil
        }
    }

    private nonisolated static func findDeviceViaUnicastSSDP(
        host: String,
        ssdpPort: UInt16,
        wifiInfo: WiFiNetworkInfo?,
        session: URLSession,
        duration: TimeInterval
    ) async -> (CastDevice?, Bool) {
        enum ProbeOutcome: Sendable {
            case device(CastDevice)
            case noDevice
            case fetchesDrained
            case ssdpFinished(SSDPSearchResult)
        }

        let ssdpCancel = CancellationFlag()
        var urlContBox: AsyncStream<URL>.Continuation?
        let urlStream = AsyncStream<URL> { urlContBox = $0 }
        let urlCont = urlContBox!

        var devContBox: AsyncStream<CastDevice>.Continuation?
        let devStream = AsyncStream<CastDevice> { devContBox = $0 }
        let devCont = devContBox!

        return await withTaskGroup(of: ProbeOutcome.self) { group in
            group.addTask {
                defer { urlCont.finish() }
                let result = await performUnicastSSDPForHost(
                    host: host,
                    ssdpPort: ssdpPort,
                    wifiInfo: wifiInfo,
                    duration: duration,
                    externalCancel: ssdpCancel
                ) { url in
                    urlCont.yield(url)
                }
                return .ssdpFinished(result)
            }

            group.addTask {
                defer { devCont.finish() }
                await withTaskGroup(of: Void.self) { fetchGroup in
                    for await location in urlStream {
                        if Task.isCancelled { break }
                        fetchGroup.addTask {
                            if let dev = await fetchDevice(
                                at: location,
                                isManual: true,
                                session: session,
                                timeout: 2.5
                            ) {
                                devCont.yield(dev)
                            }
                        }
                    }
                    await fetchGroup.waitForAll()
                }
                return .fetchesDrained
            }

            group.addTask {
                for await dev in devStream {
                    return .device(dev)
                }
                return .noDevice
            }

            var ssdpBlocked = false
            for await outcome in group {
                switch outcome {
                case .device(let dev):
                    ssdpCancel.cancel()
                    group.cancelAll()
                    return (dev, ssdpBlocked)
                case .ssdpFinished(let res):
                    if res.blockedByLocalNetwork { ssdpBlocked = true }
                case .fetchesDrained, .noDevice:
                    break
                }
            }
            return (nil, ssdpBlocked)
        }
    }

    private struct SSDPSearchResult: Sendable {
        let locations: [URL]
        let blockedByLocalNetwork: Bool
        let multicastBlocked: Bool
    }

    private struct TCPProbeResult: Sendable {
        let openPorts: [Int]
        let blockedByLocalNetwork: Bool
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private final class LocalNetworkBrowserHolder: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "app.hplayer.dlna-local-network-probe")
        private var browser: NWBrowser?
        private var wasWaiting = false

        func start(
            onWaiting: @escaping @Sendable (Bool) -> Void,
            onBecameReadyAfterWait: @escaping @Sendable () -> Void
        ) {
            let next = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: .tcp)
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self, let next else { return }
                switch state {
                case .waiting(let error):
                    self.lock.lock()
                    let isCurrent = (self.browser === next)
                    if isCurrent { self.wasWaiting = true }
                    self.lock.unlock()
                    guard isCurrent else { return }
                    var isPolicyDenied = false
                    if case .dns(let dnsCode) = error, dnsCode == -65570 {
                        isPolicyDenied = true
                    }
                    onWaiting(isPolicyDenied)
                case .ready:
                    self.lock.lock()
                    let isCurrent = (self.browser === next)
                    let shouldNotifyReady = isCurrent && self.wasWaiting
                    if isCurrent {
                        self.wasWaiting = false
                        self.browser = nil
                    }
                    self.lock.unlock()
                    if isCurrent {
                        next.cancel()
                        if shouldNotifyReady {
                            onBecameReadyAfterWait()
                        }
                    }
                case .failed, .cancelled:
                    self.lock.lock()
                    if self.browser === next {
                        self.browser = nil
                    }
                    self.lock.unlock()
                default:
                    break
                }
            }

            lock.lock()
            let previous = browser
            browser = next
            wasWaiting = false
            lock.unlock()
            previous?.cancel()
            next.start(queue: queue)
        }

        func stop() {
            lock.lock()
            let current = browser
            browser = nil
            wasWaiting = false
            lock.unlock()
            current?.cancel()
        }
    }

    private nonisolated static func performHybridSSDPSearch(
        wifiInfo: WiFiNetworkInfo?,
        ssdpPort: UInt16,
        duration: TimeInterval,
        onLocation: (@Sendable (URL) -> Void)? = nil
    ) async -> SSDPSearchResult {
        let cancelFlag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let (fd, _) = makeUDPSocket(wifiInfo: wifiInfo, targetIsLoopback: false)
                    guard fd >= 0 else {
                        continuation.resume(
                            returning: SSDPSearchResult(
                                locations: [],
                                blockedByLocalNetwork: errno == EPERM || errno == EACCES,
                                multicastBlocked: true
                            )
                        )
                        return
                    }
                    defer { close(fd) }

                    var seen = Set<URL>()
                    var locations: [URL] = []
                    var respondedHosts = Set<String>()
                    var multicastBlocked = false
                    var localNetworkBlocked = false
                    let deadline = Date().addingTimeInterval(duration)

                    // 阶段 A：组播 SSDP（若无 multicast entitlement 或被拦截，记录状态但不中止后续扫描）
                    let multicastTargets = [
                        "ssdp:all",
                        "urn:schemas-upnp-org:service:AVTransport:1",
                        "urn:schemas-upnp-org:device:MediaRenderer:1",
                        "upnp:rootdevice"
                    ]
                    for st in multicastTargets {
                        if cancelFlag.isCancelled { break }
                        let payload = buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: st, mx: 1)
                        let err = sendUDPPacket(fd: fd, ip: "239.255.255.250", port: ssdpPort, payload: payload)
                        if err != 0 && isLocalNetworkOrMulticastBlockErrno(err) {
                            multicastBlocked = true
                        }
                    }

                    // 阶段 B：定向子网广播（best-effort）
                    if !cancelFlag.isCancelled, let broadcast = wifiInfo?.broadcastAddress {
                        let payload = buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: "ssdp:all", mx: 1)
                        _ = sendUDPPacket(fd: fd, ip: broadcast, port: ssdpPort, payload: payload)
                    }

                    // 阶段 C：同网段 /24 单播 SSDP 扫描（无需 multicast entitlement，解决绝大多数自签/无权限场景与动态随机端口机顶盒）
                    if !cancelFlag.isCancelled, let sweepTargets = wifiInfo?.unicastSweepTargets(), !sweepTargets.isEmpty {
                        var unicastSentCount = 0
                        var unicastBlockedCount = 0
                        let chunkSize = 24
                        let st1 = buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: "ssdp:all", mx: 1)

                        var idx = 0
                        while idx < sweepTargets.count && !cancelFlag.isCancelled && Date() < deadline {
                            let end = min(idx + chunkSize, sweepTargets.count)
                            for targetIP in sweepTargets[idx..<end] {
                                let err = sendUDPPacket(fd: fd, ip: targetIP, port: ssdpPort, payload: st1)
                                if err == 0 {
                                    unicastSentCount += 1
                                } else if isLocalNetworkBlockErrno(err) {
                                    unicastBlockedCount += 1
                                }
                            }
                            idx = end
                            drainUDPResponses(
                                fd: fd,
                                pollTimeoutMs: 8,
                                seen: &seen,
                                locations: &locations,
                                respondedHosts: &respondedHosts,
                                onLocation: onLocation
                            )
                            if unicastSentCount == 0 && unicastBlockedCount >= min(chunkSize, sweepTargets.count) {
                                localNetworkBlocked = true
                                break
                            }
                        }

                        // 第 2 轮（间隔 ~160ms）：跳过已响应主机，发送 AVTransport:1
                        if !localNetworkBlocked && !cancelFlag.isCancelled && Date() < deadline {
                            waitAndDrain(
                                fd: fd,
                                until: min(deadline, Date().addingTimeInterval(0.16)),
                                cancelFlag: cancelFlag,
                                seen: &seen,
                                locations: &locations,
                                respondedHosts: &respondedHosts,
                                onLocation: onLocation
                            )
                            let st2 = buildMSearchPayload(
                                hostHeader: "239.255.255.250:\(ssdpPort)",
                                st: "urn:schemas-upnp-org:service:AVTransport:1",
                                mx: 1
                            )
                            var r2Idx = 0
                            let remainingTargets = sweepTargets.filter { !respondedHosts.contains($0) }
                            while r2Idx < remainingTargets.count && !cancelFlag.isCancelled && Date() < deadline {
                                let end = min(r2Idx + chunkSize, remainingTargets.count)
                                for targetIP in remainingTargets[r2Idx..<end] {
                                    _ = sendUDPPacket(fd: fd, ip: targetIP, port: ssdpPort, payload: st2)
                                }
                                r2Idx = end
                                drainUDPResponses(
                                    fd: fd,
                                    pollTimeoutMs: 8,
                                    seen: &seen,
                                    locations: &locations,
                                    respondedHosts: &respondedHosts,
                                    onLocation: onLocation
                                )
                            }
                        }

                        // 第 3 轮（仅当仍未发现任何设备时）：使用 HOST: <targetIP>:port 覆盖严格校验单播 HOST 头的设备
                        if locations.isEmpty && !localNetworkBlocked && !cancelFlag.isCancelled && Date() < deadline {
                            waitAndDrain(
                                fd: fd,
                                until: min(deadline, Date().addingTimeInterval(0.16)),
                                cancelFlag: cancelFlag,
                                seen: &seen,
                                locations: &locations,
                                respondedHosts: &respondedHosts,
                                onLocation: onLocation
                            )
                            let remainingTargets = sweepTargets.filter { !respondedHosts.contains($0) }
                            var r3Idx = 0
                            while r3Idx < remainingTargets.count && !cancelFlag.isCancelled && Date() < deadline {
                                let end = min(r3Idx + chunkSize, remainingTargets.count)
                                for targetIP in remainingTargets[r3Idx..<end] {
                                    let payload = buildMSearchPayload(
                                        hostHeader: "\(targetIP):\(ssdpPort)",
                                        st: "urn:schemas-upnp-org:device:MediaRenderer:1",
                                        mx: 1
                                    )
                                    _ = sendUDPPacket(fd: fd, ip: targetIP, port: ssdpPort, payload: payload)
                                }
                                r3Idx = end
                                drainUDPResponses(
                                    fd: fd,
                                    pollTimeoutMs: 8,
                                    seen: &seen,
                                    locations: &locations,
                                    respondedHosts: &respondedHosts,
                                    onLocation: onLocation
                                )
                            }
                        }
                    }

                    if !localNetworkBlocked && !cancelFlag.isCancelled {
                        waitAndDrain(
                            fd: fd,
                            until: deadline,
                            cancelFlag: cancelFlag,
                            seen: &seen,
                            locations: &locations,
                            respondedHosts: &respondedHosts,
                            onLocation: onLocation
                        )
                    }

                    continuation.resume(
                        returning: SSDPSearchResult(
                            locations: locations,
                            blockedByLocalNetwork: localNetworkBlocked,
                            multicastBlocked: multicastBlocked
                        )
                    )
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private nonisolated static func performUnicastSSDPForHost(
        host: String,
        ssdpPort: UInt16,
        wifiInfo: WiFiNetworkInfo?,
        duration: TimeInterval,
        externalCancel: CancellationFlag? = nil,
        onLocation: (@Sendable (URL) -> Void)? = nil
    ) async -> SSDPSearchResult {
        guard isIPv4Address(host) else {
            return SSDPSearchResult(locations: [], blockedByLocalNetwork: false, multicastBlocked: false)
        }
        let localCancel = CancellationFlag()
        let isLoopback = isLoopbackHost(host)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let (fd, createErr) = makeUDPSocket(wifiInfo: wifiInfo, targetIsLoopback: isLoopback)
                    guard fd >= 0 else {
                        continuation.resume(
                            returning: SSDPSearchResult(
                                locations: [],
                                blockedByLocalNetwork: isLocalNetworkBlockErrno(createErr),
                                multicastBlocked: false
                            )
                        )
                        return
                    }
                    defer { close(fd) }

                    let probes: [[UInt8]] = [
                        buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: "ssdp:all", mx: 1),
                        buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: "urn:schemas-upnp-org:service:AVTransport:1", mx: 1),
                        buildMSearchPayload(hostHeader: "239.255.255.250:\(ssdpPort)", st: "urn:schemas-upnp-org:device:MediaRenderer:1", mx: 1),
                        buildMSearchPayload(hostHeader: "\(host):\(ssdpPort)", st: "urn:schemas-upnp-org:service:AVTransport:1", mx: 1),
                        buildMSearchPayload(hostHeader: "\(host):\(ssdpPort)", st: "upnp:rootdevice", mx: 1)
                    ]

                    func sendProbeBatch() -> (sent: Int, blocked: Int) {
                        var sent = 0
                        var blocked = 0
                        for payload in probes {
                            if localCancel.isCancelled || (externalCancel?.isCancelled ?? false) { break }
                            let err = sendUDPPacket(fd: fd, ip: host, port: ssdpPort, payload: payload)
                            if err == 0 {
                                sent += 1
                            } else if isLocalNetworkBlockErrno(err) {
                                blocked += 1
                            }
                        }
                        return (sent, blocked)
                    }

                    var seen = Set<URL>()
                    var locations: [URL] = []
                    var respondedHosts = Set<String>()
                    let deadline = Date().addingTimeInterval(duration)

                    let batch1 = sendProbeBatch()
                    if batch1.sent == 0 && batch1.blocked >= probes.count {
                        continuation.resume(
                            returning: SSDPSearchResult(
                                locations: [],
                                blockedByLocalNetwork: true,
                                multicastBlocked: false
                            )
                        )
                        return
                    }

                    // 阶段等待 250ms 边收包；如未取消且尚未收到任何 LOCATION，再补发一轮提高 UDP 到达率
                    let round2At = min(deadline, Date().addingTimeInterval(0.25))
                    waitAndDrain(
                        fd: fd,
                        until: round2At,
                        cancelFlag: localCancel,
                        secondaryCancelFlag: externalCancel,
                        seen: &seen,
                        locations: &locations,
                        respondedHosts: &respondedHosts,
                        onLocation: onLocation
                    )

                    if locations.isEmpty && !localCancel.isCancelled && !(externalCancel?.isCancelled ?? false) && Date() < deadline {
                        _ = sendProbeBatch()
                    }

                    waitAndDrain(
                        fd: fd,
                        until: deadline,
                        cancelFlag: localCancel,
                        secondaryCancelFlag: externalCancel,
                        seen: &seen,
                        locations: &locations,
                        respondedHosts: &respondedHosts,
                        onLocation: onLocation
                    )

                    continuation.resume(
                        returning: SSDPSearchResult(
                            locations: locations,
                            blockedByLocalNetwork: false,
                            multicastBlocked: false
                        )
                    )
                }
            }
        } onCancel: {
            localCancel.cancel()
        }
    }

    private nonisolated static func probeOpenTCPPorts(
        host: String,
        ports: [Int],
        wifiInfo: WiFiNetworkInfo?,
        perChunkTimeout: TimeInterval = 0.45
    ) async -> TCPProbeResult {
        guard isIPv4Address(host), !ports.isEmpty else {
            return TCPProbeResult(openPorts: [], blockedByLocalNetwork: false)
        }
        let cancelFlag = CancellationFlag()
        let isLoopback = isLoopbackHost(host)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var targetInAddr = in_addr()
                    guard inet_pton(AF_INET, host, &targetInAddr) == 1 else {
                        continuation.resume(returning: TCPProbeResult(openPorts: [], blockedByLocalNetwork: false))
                        return
                    }

                    var openPorts: [Int] = []
                    var blockedCount = 0
                    let chunkSize = 22
                    var idx = 0

                    while idx < ports.count && !cancelFlag.isCancelled {
                        let end = min(idx + chunkSize, ports.count)
                        let slice = ports[idx..<end]
                        idx = end

                        var pending: [(fd: Int32, port: Int)] = []
                        defer {
                            for entry in pending {
                                close(entry.fd)
                            }
                        }

                        for port in slice {
                            guard let validPort = UInt16(exactly: port), validPort > 0 else { continue }
                            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                            guard fd >= 0 else { continue }

                            var noSigPipe: Int32 = 1
                            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                            let flags = fcntl(fd, F_GETFL, 0)
                            if flags >= 0 {
                                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                            }
                            if !isLoopback, let ifIndex = wifiInfo?.interfaceIndex, ifIndex != 0 {
                                var boundIf = ifIndex
                                setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &boundIf, socklen_t(MemoryLayout<UInt32>.size))
                            }

                            var dest = sockaddr_in()
                            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                            dest.sin_family = sa_family_t(AF_INET)
                            dest.sin_port = validPort.bigEndian
                            dest.sin_addr = targetInAddr

                            let res = withUnsafePointer(to: &dest) { ptr in
                                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                            if res == 0 {
                                openPorts.append(port)
                                close(fd)
                            } else {
                                let err = errno
                                if err == EINPROGRESS {
                                    pending.append((fd, port))
                                } else {
                                    if isLocalNetworkBlockErrno(err) {
                                        blockedCount += 1
                                    }
                                    close(fd)
                                }
                            }
                        }

                        let chunkDeadline = Date().addingTimeInterval(perChunkTimeout)
                        while !pending.isEmpty && Date() < chunkDeadline && !cancelFlag.isCancelled {
                            var pfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                            let remainingMs = max(5, Int32(chunkDeadline.timeIntervalSinceNow * 1000))
                            let pollMs = min(Int32(60), remainingMs)
                            let ready = pfds.withUnsafeMutableBufferPointer { buf -> Int32 in
                                guard let base = buf.baseAddress else { return 0 }
                                return Darwin.poll(base, nfds_t(buf.count), pollMs)
                            }
                            if ready < 0 {
                                if errno == EINTR { continue }
                                break
                            }
                            if ready == 0 { continue }

                            var nextPending: [(fd: Int32, port: Int)] = []
                            nextPending.reserveCapacity(pending.count)
                            for (index, entry) in pending.enumerated() {
                                let revents = pfds[index].revents
                                if revents == 0 {
                                    nextPending.append(entry)
                                    continue
                                }
                                var soError: Int32 = 0
                                var len = socklen_t(MemoryLayout<Int32>.size)
                                let gso = getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                                if gso == 0 && soError == 0 && (revents & Int16(POLLERR | POLLNVAL)) == 0 {
                                    openPorts.append(entry.port)
                                } else if isLocalNetworkBlockErrno(soError) {
                                    blockedCount += 1
                                }
                                close(entry.fd)
                            }
                            pending = nextPending
                        }
                    }

                    let blocked = openPorts.isEmpty && blockedCount >= min(ports.count, 10)
                    continuation.resume(returning: TCPProbeResult(openPorts: openPorts, blockedByLocalNetwork: blocked))
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    // MARK: - BSD Socket Helpers

    private nonisolated static func makeUDPSocket(
        wifiInfo: WiFiNetworkInfo?,
        targetIsLoopback: Bool
    ) -> (fd: Int32, err: Int32) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return (-1, errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var broadcastEnable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        var rcvBuf: Int32 = 262_144
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        if !targetIsLoopback, let wifiInfo {
            if wifiInfo.interfaceIndex != 0 {
                var ifIndex = wifiInfo.interfaceIndex
                setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIndex, socklen_t(MemoryLayout<UInt32>.size))
            }
            var mcastAddr = in_addr()
            if inet_pton(AF_INET, wifiInfo.ip, &mcastAddr) == 1 {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &mcastAddr, socklen_t(MemoryLayout<in_addr>.size))
            }
            var ttl: UInt8 = 4
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        }

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        if targetIsLoopback {
            inet_pton(AF_INET, "127.0.0.1", &bindAddr.sin_addr)
        } else if let wifiInfo, inet_pton(AF_INET, wifiInfo.ip, &bindAddr.sin_addr) == 1 {
            // bind to active Wi-Fi IPv4 address
        } else {
            bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        }

        var bindResult = bindUDPSocket(fd: fd, addr: &bindAddr)
        if bindResult != 0 && !targetIsLoopback {
            bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
            bindResult = bindUDPSocket(fd: fd, addr: &bindAddr)
        }
        if bindResult != 0 {
            let err = errno
            close(fd)
            return (-1, err)
        }

        return (fd, 0)
    }

    private nonisolated static func bindUDPSocket(fd: Int32, addr: inout sockaddr_in) -> Int32 {
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private nonisolated static func buildMSearchPayload(hostHeader: String, st: String, mx: Int) -> [UInt8] {
        let message =
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(hostHeader)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: \(mx)\r\n" +
            "ST: \(st)\r\n\r\n"
        return Array(message.utf8)
    }

    private nonisolated static func sendUDPPacket(fd: Int32, ip: String, port: UInt16, payload: [UInt8]) -> Int32 {
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &destAddr.sin_addr) == 1 else { return EINVAL }

        let sent = payload.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &destAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent >= 0 ? 0 : errno
    }

    private nonisolated static func waitAndDrain(
        fd: Int32,
        until deadline: Date,
        cancelFlag: CancellationFlag,
        secondaryCancelFlag: CancellationFlag? = nil,
        seen: inout Set<URL>,
        locations: inout [URL],
        respondedHosts: inout Set<String>,
        onLocation: ((URL) -> Void)?
    ) {
        while Date() < deadline && !cancelFlag.isCancelled && !(secondaryCancelFlag?.isCancelled ?? false) {
            let remainingMs = max(5, Int32(deadline.timeIntervalSinceNow * 1000))
            let timeoutMs = min(Int32(60), remainingMs)
            drainUDPResponses(
                fd: fd,
                pollTimeoutMs: timeoutMs,
                seen: &seen,
                locations: &locations,
                respondedHosts: &respondedHosts,
                onLocation: onLocation
            )
        }
    }

    private nonisolated static func drainUDPResponses(
        fd: Int32,
        pollTimeoutMs: Int32,
        seen: inout Set<URL>,
        locations: inout [URL],
        respondedHosts: inout Set<String>,
        onLocation: ((URL) -> Void)?
    ) {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollRes = Darwin.poll(&pfd, 1, pollTimeoutMs)
        guard pollRes > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sa, &senderLen)
                    }
                }
            }
            if received > 0 {
                var senderIP: String?
                if senderLen >= MemoryLayout<sockaddr_in>.size, senderAddr.sin_family == sa_family_t(AF_INET) {
                    var ipAddr = senderAddr.sin_addr
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &ipAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let parsed = String(cString: ipBuffer)
                        if !parsed.isEmpty {
                            senderIP = parsed
                            respondedHosts.insert(parsed)
                        }
                    }
                }

                let text = String(decoding: buffer[..<received], as: UTF8.self)
                if var url = DLNADeviceParser.parseSSDPHeaders(text) {
                    if let senderIP, !isLoopbackHost(senderIP),
                       let urlHost = url.host?.lowercased(),
                       urlHost == "0.0.0.0" || isLoopbackHost(urlHost),
                       var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        components.host = senderIP
                        if let repaired = components.url {
                            url = repaired
                        }
                    }
                    if let host = url.host, !host.isEmpty {
                        respondedHosts.insert(host)
                    }
                    if seen.insert(url).inserted {
                        locations.append(url)
                        onLocation?(url)
                    }
                }
            } else {
                let err = errno
                if err == EINTR { continue }
                break
            }
        }
    }

    private nonisolated static func isIPv4Address(_ host: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, host, &addr) == 1
    }

    private nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1"
    }

    private nonisolated static func isLocalNetworkBlockErrno(_ err: Int32) -> Bool {
        err == EPERM || err == EACCES || err == ENETUNREACH || err == EHOSTUNREACH
    }

    private nonisolated static func isLocalNetworkOrMulticastBlockErrno(_ err: Int32) -> Bool {
        err == EPERM || err == EACCES || err == ENETUNREACH || err == EHOSTUNREACH || err == EADDRNOTAVAIL
    }
}
