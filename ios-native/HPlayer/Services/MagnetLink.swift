import Foundation

/// 一个 BT 资源的磁力链接。
///
/// 用户粘贴进来的文字五花八门：前后夹着说明文字、`dn` 里是没编码的中文、
/// `MAGNET:?XT=URN:BTIH:` 全大写、只有 40 位哈希或 32 位 Base32 哈希、迅雷 thunder:// 链接……
/// 这里统一识别，再整理成 libtorrent 一定能解析的标准形式。
/// 只依赖 Foundation，云构建里的引擎冒烟测试也会直接编译这个文件。
struct MagnetLink: Equatable, Sendable {
    struct Parameter: Equatable, Sendable {
        let name: String
        let value: String
    }

    /// 小写十六进制信息哈希：BT v1 为 40 位，只有 v2 哈希时为 64 位
    let infoHash: String
    /// 只有 BT v2（urn:btmh）哈希
    let isV2Only: Bool
    let displayName: String?
    let trackers: [String]
    /// 原链接里的其他参数（x.pe、ws、so 等），按原样保留
    let extras: [Parameter]

    /// 整理后的磁力链接，不含额外补充的公共 Tracker，用于保存记录和复制
    var uri: String { build(extraTrackers: [], dhtNodes: []) }

    /// 交给引擎的链接：补上公共 Tracker 和 DHT 引导节点，帮助更快找到节点
    func engineURI(publicTrackers: [String]) -> String {
        build(extraTrackers: publicTrackers, dhtNodes: Self.dhtBootstrapNodes)
    }

    /// 用于界面显示的短哈希
    var shortHash: String {
        guard infoHash.count > 12 else { return infoHash.uppercased() }
        return "\(infoHash.prefix(6))…\(infoHash.suffix(6))".uppercased()
    }

    /// DHT 引导节点。引擎默认只有 dht.libtorrent.org 一个，第一次使用时找节点会很慢。
    static let dhtBootstrapNodes = [
        "router.bittorrent.com:6881",
        "router.utorrent.com:6881",
        "dht.transmissionbt.com:6881",
        "dht.libtorrent.org:25401",
        "dht.aelitis.com:6881",
    ]

    // MARK: 识别

    /// 从任意文字里识别出第一个 BT 资源；识别不到返回 nil。
    static func parse(_ text: String) -> MagnetLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 * 1024 else { return nil }
        if let magnet = firstMagnet(in: trimmed), let link = parseMagnet(magnet) {
            return link
        }
        if let thunder = decodeThunder(in: trimmed),
           let magnet = firstMagnet(in: thunder),
           let link = parseMagnet(magnet) {
            return link
        }
        if let hash = bareHash(in: trimmed) {
            return MagnetLink(infoHash: hash.value, isV2Only: hash.isV2, displayName: nil, trackers: [], extras: [])
        }
        return nil
    }

    /// 只接受 libtorrent 支持的 Tracker 协议
    static func isValidTracker(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.hasPrefix("udp://") || lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard value.count > 10, value.count <= 512 else { return false }
        return !value.contains { $0.isWhitespace }
    }

    /// 遇到这些字符就认为磁力链接结束了：空白、引号、尖括号和常见的中文标点
    private static let terminators: Set<Character> = [
        "\"", "'", "<", ">", "`", "】", "」", "』", "）", "》", "，", "。", "；", "、", "“", "”", "‘", "’",
    ]

    private static func firstMagnet(in text: String) -> String? {
        guard let start = text.range(of: "magnet:?", options: .caseInsensitive) else { return nil }
        var end = start.upperBound
        while end < text.endIndex {
            let character = text[end]
            if character.isWhitespace || terminators.contains(character) { break }
            end = text.index(after: end)
        }
        return String(text[start.lowerBound..<end])
    }

    private static func parseMagnet(_ magnet: String) -> MagnetLink? {
        let query = magnet.dropFirst("magnet:?".count)
        var v1: String?
        var v2: String?
        var name: String?
        var trackers: [String] = []
        var extras: [Parameter] = []

        for piece in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(pair[0])
            let rawValue = pair.count > 1 ? String(pair[1]) : ""
            guard !rawName.isEmpty else { continue }

            // 和 libtorrent 一样，参数名后面的「.数字」没有含义，例如 tr.1、xt.2
            var key = rawName.lowercased()
            if let dot = key.firstIndex(of: ".") {
                let suffix = key[key.index(after: dot)...]
                if suffix.allSatisfy({ $0.isASCII && $0.isNumber }) { key = String(key[..<dot]) }
            }

            switch key {
            case "xt":
                let value = decode(rawValue).trimmingCharacters(in: .whitespaces)
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    if v1 == nil { v1 = normalizeV1(String(value.dropFirst(9))) }
                } else if lower.hasPrefix("urn:btmh:") {
                    let rest = lower.dropFirst(9)
                    if rest.hasPrefix("1220"), rest.count == 68, rest.dropFirst(4).allSatisfy({ $0.isHexDigit }) {
                        if v2 == nil { v2 = String(rest.dropFirst(4)) }
                    }
                }
            case "dn":
                let value = decode(rawValue.replacingOccurrences(of: "+", with: " "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if name == nil, !value.isEmpty { name = value }
            case "tr":
                let value = decode(rawValue).trimmingCharacters(in: .whitespaces)
                if isValidTracker(value) { trackers.append(value) }
            default:
                extras.append(Parameter(name: rawName, value: looseEncode(rawValue)))
            }
        }

        if let v1 {
            if let v2 {
                extras.insert(Parameter(name: "xt", value: "urn:btmh:1220\(v2)"), at: 0)
            }
            return MagnetLink(infoHash: v1, isV2Only: false, displayName: name, trackers: trackers, extras: extras)
        }
        if let v2 {
            return MagnetLink(infoHash: v2, isV2Only: true, displayName: name, trackers: trackers, extras: extras)
        }
        return nil
    }

    private static func normalizeV1(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count == 40, value.allSatisfy({ $0.isHexDigit }) { return value.lowercased() }
        if value.count == 32, let bytes = base32Decode(value), bytes.count == 20 { return hex(bytes) }
        return nil
    }

    /// 没有 magnet 前缀时，找一段单独的信息哈希
    private static func bareHash(in text: String) -> (value: String, isV2: Bool)? {
        // 整段文字就是一个哈希
        if text.count == 64, text.allSatisfy({ $0.isHexDigit }) { return (text.lowercased(), true) }
        if text.count == 32, let bytes = base32Decode(text), bytes.count == 20 { return (hex(bytes), false) }
        // 文字里夹着 40 位十六进制哈希，前后不能紧挨着字母数字
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9A-Fa-f]{40}(?![0-9A-Za-z])") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else { return nil }
        return (text[found].lowercased(), false)
    }

    /// 迅雷链接：thunder://Base64("AA" + 地址 + "ZZ")
    private static func decodeThunder(in text: String) -> String? {
        guard let start = text.range(of: "thunder://", options: .caseInsensitive) else { return nil }
        var payload = ""
        for character in text[start.upperBound...] {
            let isBase64 = (character.isASCII && (character.isLetter || character.isNumber)) || "+/=".contains(character)
            guard isBase64 else { break }
            payload.append(character)
        }
        guard !payload.isEmpty else { return nil }
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        guard var url = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        if url.hasPrefix("AA") { url.removeFirst(2) }
        if url.hasSuffix("ZZ") { url.removeLast(2) }
        return url
    }

    private static func base32Decode(_ text: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt32] = [:]
        for (offset, character) in alphabet.enumerated() { lookup[character] = UInt32(offset) }
        var buffer: UInt32 = 0
        var bits = 0
        var output: [UInt8] = []
        for character in text.uppercased() {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return output
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 生成

    private func build(extraTrackers: [String], dhtNodes: [String]) -> String {
        var parts = [isV2Only ? "xt=urn:btmh:1220\(infoHash)" : "xt=urn:btih:\(infoHash)"]
        if let displayName, !displayName.isEmpty {
            parts.append("dn=\(Self.strictEncode(displayName))")
        }
        var seen = Set<String>()
        for tracker in trackers + extraTrackers where seen.insert(tracker.lowercased()).inserted {
            parts.append("tr=\(Self.strictEncode(tracker))")
        }
        for extra in extras {
            parts.append(extra.value.isEmpty ? extra.name : "\(extra.name)=\(extra.value)")
        }
        for node in dhtNodes {
            parts.append("dht=\(node)")
        }
        return "magnet:?" + parts.joined(separator: "&")
    }

    private static let strictAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let looseAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$'()*+,;=%")

    /// dn、tr 会被 libtorrent 反转义，所以除字母数字外全部编码
    private static func strictEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? value
    }

    /// x.pe、dht、so 等参数 libtorrent 不会反转义，只编码空格、中文这类非法字符
    private static func looseEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: looseAllowed) ?? value
    }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

/// 公共 Tracker 列表。很多磁力链接只有哈希没有 Tracker，只能靠 DHT 慢慢找节点；
/// 补上这些 Tracker 后通常几秒内就能拿到节点。列表每天最多在线更新一次，失败时使用内置列表。
enum PublicTrackers {
    static let builtIn = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://tracker.tiny-vps.com:6969/announce",
        "udp://tracker-udp.gbitt.info:80/announce",
        "udp://opentracker.io:6969/announce",
        "udp://tracker.0x7c0.com:6969/announce",
        "udp://tracker.srv00.com:6969/announce",
        "udp://retracker01-msk-virt.corbina.net:80/announce",
        "udp://bt.ktrackers.com:6666/announce",
        "udp://isk.richardsw.club:6969/announce",
        "udp://tracker.bittor.pw:1337/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "http://tracker.bt4g.com:2095/announce",
        "https://tracker.gbitt.info:443/announce",
        "http://tracker.renfei.net:8080/announce",
        "https://tracker.zhuqiy.top:443/announce",
        "http://bt.okmp3.ru:2710/announce",
        "http://open.acgnxtracker.com:80/announce",
    ]

    private static let cacheKey = "hplayer.magnet.trackers"
    private static let cacheDateKey = "hplayer.magnet.trackersDate"
    private static let limit = 40
    private static let sources = [
        "https://cf.trackerslist.com/best.txt",
        "https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt",
        "https://ngosang.github.io/trackerslist/trackers_best.txt",
    ]

    /// 当前使用的列表：在线更新到的排在前面，再补上内置列表
    static var current: [String] {
        let cached = UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for tracker in cached + builtIn where MagnetLink.isValidTracker(tracker) && seen.insert(tracker.lowercased()).inserted {
            result.append(tracker)
            if result.count >= limit { break }
        }
        return result
    }

    static func refreshIfNeeded() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: cacheDateKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let result = try? await URLSession.shared.data(for: request) else { continue }
            let (data, response) = result
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { continue }
            let trackers = text
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { MagnetLink.isValidTracker($0) }
            guard trackers.count >= 5 else { continue }
            defaults.set(Array(trackers.prefix(limit)), forKey: cacheKey)
            defaults.set(Date(), forKey: cacheDateKey)
            return
        }
    }
}
