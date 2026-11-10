import Foundation
import UIKit

final class AnimeSigner {
    static let shared = AnimeSigner()

    private let key = Data("ziISjqkXPsGUMRNGyWigxDGtJbfTdcGv".utf8)
    private let iv = Data("WonrnVkxeIxDcFbv".utf8)

    private let appId = "4150439554430627"
    private let version = "2024-09-24"
    private let innerVersion = "2.4.7.9"
    private let currentVersion = "1.0.0.1"

    /// 应用内置的游客令牌，只在还没拿到服务端签发的令牌、且它自己没过期时兜底用。
    static let bundledToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJGVVVEIjoiMjliZmI0ZTktN2I3NS00NDIwLTkxMmQtZDc1YTUwMTExMTNkIiwiQnVmZmVyVGltZSI6ODY0MDAwMDAwMDAwMDAsImV4cCI6MTc5NDU3OTExNywibmJmIjoxNzkzOTc0MzE3fQ.default_token"
    private static let tokenKey = "anime.issued_token"
    private let tokenLock = NSLock()
    private let defaults: UserDefaults

    /// 当前要带在 x-token 里的令牌。
    ///
    /// 游客令牌不是登录接口给的：服务端会在响应头 `new-token` 里主动下发（HS256 JWT），
    /// 客户端存下来，之后的请求带上。所以顺序是：服务端下发过且没过期的 → 内置的且没过期的 → 不带
    /// （不带时服务端判定需要就会重新下发）。
    var token: String {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if let issued = defaults.string(forKey: Self.tokenKey), !Self.isExpired(issued) { return issued }
        if defaults.bool(forKey: Self.bundledRejectedKey) || Self.isExpired(Self.bundledToken) { return "" }
        return Self.bundledToken
    }

    /// 收到响应头里的 `new-token` 时调用。
    func adoptIssuedToken(_ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.split(separator: ".").count == 3 else { return }
        tokenLock.lock(); defer { tokenLock.unlock() }
        defaults.set(value, forKey: Self.tokenKey)
    }

    private static let bundledRejectedKey = "anime.bundled_token_rejected"

    /// 服务端说令牌失效时调用：丢掉存下的令牌，下一次请求重新领。
    func discardIssuedToken() {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if defaults.string(forKey: Self.tokenKey) == nil {
            // 被拒的是内置令牌：以后不再用它
            defaults.set(true, forKey: Self.bundledRejectedKey)
        }
        defaults.removeObject(forKey: Self.tokenKey)
    }

    /// JWT 里的过期时间（秒）；读不出来返回 nil。
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (json["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 提前一分钟算过期；读不出过期时间的当作没过期，交给服务端判断。
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry.timeIntervalSince(now) < 60
    }

    private var deviceId: String {
        if let vendor = UIDevice.current.identifierForVendor?.uuidString {
            return vendor.replacingOccurrences(of: "-", with: "")
        }
        return "10E3199773CC47A99F20B09F17B365D8"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 生成带有动态毫秒时间戳与 AES-256 签名的全套通用请求头
    func headers(customTimestamp: Int64? = nil) -> [String: String] {
        let tsNumber = customTimestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        let ts = String(tsNumber)

        let signPlain = "\(innerVersion)-\(ts)-IOS-\(currentVersion)-\(deviceId)"
        let innerData = Data(signPlain.utf8)
        let innerBase64 = innerData.base64EncodedString()

        var authHeader = ""
        if let innerBytes = innerBase64.data(using: .utf8),
           let encrypted = AnimeCrypto.aes256CbcEncrypt(data: innerBytes, key: key, iv: iv) {
            authHeader = encrypted.base64EncodedString()
        }

        var headerFields: [String: String] = [
            "x-version": version,
            "user-agent": "Dart/3.6 (dart:io)",
            "appid": appId,
            "ts": ts,
            "accept-encoding": "gzip",
            "authentication": authHeader,
            "content-type": "application/json; charset=utf-8"
        ]

        let currentToken = token
        if !currentToken.isEmpty {
            headerFields["x-token"] = currentToken
        }

        return headerFields
    }
}
