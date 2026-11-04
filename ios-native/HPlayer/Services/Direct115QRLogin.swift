import Foundation

/// 115 扫码登录：本 App 显示二维码，用手机上的 115 App 扫一下并点确认，就拿到网盘的登录凭证（Cookie）。
///
/// 流程和 115 网页版扫码登录一样：先要一张二维码（uid / time / sign），再轮询扫码状态，
/// 确认后用 uid 换登录凭证。
///
/// 登录身份用「支付宝小程序」：115 每种登录身份同一时间只能在一处登录，
/// 用这个身份不会把手机 115 App、电脑浏览器里正在用的登录挤下线。
struct Direct115QRLogin {
    struct Ticket: Equatable {
        let uid: String
        let time: String
        let sign: String
        /// 二维码里的内容
        let content: String
    }

    enum Status: Equatable {
        case waiting
        case scanned
        case confirmed
        case expired
        case canceled
    }

    enum LoginError: LocalizedError {
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): return message
            }
        }
    }

    static let app = "alipaymini"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            // 查状态是「长轮询」：没人扫码时服务器会挂着请求等三十秒左右再回
            configuration.timeoutIntervalForRequest = 45
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 要一张新的二维码
    func start() async throws -> Ticket {
        let json = try await request("https://qrcodeapi.115.com/api/1.0/web/1.0/token/")
        let data = json["data"] as? [String: Any] ?? [:]
        let uid = Self.string(data["uid"]), time = Self.string(data["time"]), sign = Self.string(data["sign"])
        guard !uid.isEmpty, !time.isEmpty, !sign.isEmpty else { throw LoginError.server("115 没有返回二维码，请稍后重试") }
        let content = Self.string(data["qrcode"])
        return Ticket(uid: uid, time: time, sign: sign, content: content.isEmpty ? "https://115.com/scan/dg-\(uid)" : content)
    }

    /// 二维码现在的状态。没人扫码时服务器会挂着请求等一会儿再回，所以这个调用可能要几十秒。
    func status(of ticket: Ticket) async throws -> Status {
        var components = URLComponents(string: "https://qrcodeapi.115.com/get/status/")
        components?.queryItems = [
            URLQueryItem(name: "uid", value: ticket.uid),
            URLQueryItem(name: "time", value: ticket.time),
            URLQueryItem(name: "sign", value: ticket.sign),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        guard let url = components?.url else { throw LoginError.server("二维码参数无效") }
        let json = try await request(url.absoluteString, checkState: false)
        // 过期时 state 为 0（错误码 40199002）
        if Self.failedState(json) { return .expired }
        switch Self.integer((json["data"] as? [String: Any])?["status"]) {
        case 1: return .scanned
        case 2: return .confirmed
        case -1: return .expired
        case -2: return .canceled
        default: return .waiting
        }
    }

    /// 扫码确认以后，用二维码换登录凭证，返回可以直接放进请求头的 Cookie
    func cookie(for ticket: Ticket) async throws -> String {
        let json = try await request("https://passportapi.115.com/app/1.0/\(Self.app)/1.0/login/qrcode/",
                                     form: ["account": ticket.uid, "app": Self.app])
        let data = json["data"] as? [String: Any] ?? [:]
        guard let values = data["cookie"] as? [String: Any] else { throw LoginError.server("115 没有返回登录凭证，请重新扫码") }
        let header = Self.cookieHeader(values)
        guard header.contains("UID=") else { throw LoginError.server("115 返回的登录凭证不完整，请重新扫码") }
        return header
    }

    /// 常用的几项排在前面，其余按名称排；名称或值里有分号、换行的丢掉
    static func cookieHeader(_ values: [String: Any]) -> String {
        let preferred = ["UID", "CID", "SEID", "KID"]
        let names = values.keys.sorted { lhs, rhs in
            let left = preferred.firstIndex(of: lhs) ?? preferred.count
            let right = preferred.firstIndex(of: rhs) ?? preferred.count
            return left != right ? left < right : lhs < rhs
        }
        return names.compactMap { name -> String? in
            let value = string(values[name])
            let unsafe = CharacterSet(charactersIn: ";=\r\n ")
            guard !name.isEmpty, !value.isEmpty, name.rangeOfCharacter(from: unsafe) == nil,
                  value.rangeOfCharacter(from: CharacterSet(charactersIn: ";\r\n")) == nil else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    // MARK: 网络

    private func request(_ address: String, form: [String: String]? = nil, checkState: Bool = true) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw LoginError.server("地址无效") }
        var request = URLRequest(url: url)
        request.setValue(Direct115Client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = form.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&")
                .data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LoginError.server("115 登录服务暂时无法访问，请稍后重试")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.server("115 返回的数据无法识别")
        }
        if checkState, Self.failedState(json) {
            let message = Self.string(json["message"] ?? json["error"] ?? json["msg"])
            throw LoginError.server(message.isEmpty ? "115 登录失败，请重新扫码" : message)
        }
        return json
    }

    /// state 为 false 或 0 表示失败（JSON 里的 true/false 和 1/0 解出来都是数字）
    private static func failedState(_ json: [String: Any]) -> Bool {
        guard let state = json["state"] else { return false }
        return integer(state) == 0
    }

    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    static func integer(_ value: Any?) -> Int {
        if let value = value as? NSNumber { return Int(truncating: value) }
        return Int(string(value)) ?? 0
    }
}
