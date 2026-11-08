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

    /// 用户令牌（默认有效 JWT，可由用户设置覆盖）
    var token: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJGVVVEIjoiMjliZmI0ZTktN2I3NS00NDIwLTkxMmQtZDc1YTUwMTExMTNkIiwiQnVmZmVyVGltZSI6ODY0MDAwMDAwMDAwMDAsImV4cCI6MTc5NDU3OTExNywibmJmIjoxNzkzOTc0MzE3fQ.default_token"

    private var deviceId: String {
        if let vendor = UIDevice.current.identifierForVendor?.uuidString {
            return vendor.replacingOccurrences(of: "-", with: "")
        }
        return "10E3199773CC47A99F20B09F17B365D8"
    }

    private init() {}

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

        if !token.isEmpty {
            headerFields["x-token"] = token
        }

        return headerFields
    }
}
