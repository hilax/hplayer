import Foundation
import CommonCrypto
import CryptoKit
import Security

enum AnimeCryptoError: LocalizedError {
    case invalidKeyFormat
    case encryptionFailed
    case decryptionFailed
    case invalidPayload
    case rsaDecryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeyFormat: return "密钥格式错误"
        case .encryptionFailed: return "数据加密失败"
        case .decryptionFailed: return "数据解密失败"
        case .invalidPayload: return "密文载荷格式错误"
        case .rsaDecryptionFailed: return "RSA 解密随机密钥失败"
        }
    }
}

final class AnimeCrypto {
    static let shared = AnimeCrypto()

    /// 内置的 2048-bit RSA 私钥（从原客户端 appinfo 逆向提取，用于解密服务端混合加密响应中的 AES randomKey）
    private let rsaPrivateKeyPEM = """
    MIIEowIBAAKCAQEAo0aDQMwcWpsCrvI0J222vaB6zRuAZ1U9VSjhCKwqicXodMlg
    fwhKhjoZ7jVoRKZ6hZ8GNDoANJ7FyV23Cet++aDot4JhkbL4RHBfi8sqUnjWYf+j
    GI/WWgIpGiJKTvzsG+by3Wr0f4c9Ajb334Kwu7bLFpU3nKqDDIfTYrF0hsDiWzJ4
    CN9pOnYa4FZ+pfPy0YaFxLT5MDbsBQ2lqWNxb+OVrjVX+8hiaYnWjwmHlIDAao2i
    rnu+YIGduwv+/PNK6DXl0NN3W0S7PRT9wyBX8j1Tus230dAlHRj0hfCbrqfAX1vV
    TsHxgUnLgUQyQ4PITbJ7SRUqVsY8Y/Y9T4eVNQIDAQABAoIBAFj0HKQbz8LJOvAH
    QsTMcEfle6HtPsqNVQnlaJyp987xxNCDug/be4afdushq7njHVNZLS8c/mmsqsMn
    TIaaB6aGtOLtpKyVXc8jjdqCiH9AGERx2vCRxM1q6eu0DNn1z8jvzRc2oxgrnOBt
    BCSAdjr+vqyCBTdUamtUQKU/WuXip1LwjQ7C2L7AoILBmIFGAjN1rXQqsWi73No1
    /Xvov9y25DZnIgnVTGi++Ue9FXh3qfV7/CQkZ1X6dqQ01dW4PZtpjdI2Wr6A+IC8
    iRaj5HZYcJkJUmNHrFKxL0Z7b2yH/mmr9YXAccIk7yFMFSyhGSoqT1RYheOi5vvS
    VE0WY6ECgYEA0mQb6lBI87FYG79pc+Cb/G/3idZAT9DoTT2DaCFHLG1QKHEabLj9
    vad3v6AjRnFRRoUv3WSuLLIfha5vcpVZ13TvSlqVVd6n7XwSIfnthDQ2ypB75VJT
    //DWYJL4gexGZt0s/smQpK8iB1lKGfKqkOFU+J88wPopyN1QMuYBmVkCgYEAxqur
    UF+abXcYvTwdAbAGH0gkaXAbeLbrwDKZ/qcW+QGUvxoin5j6ZKUUhR1UMD+bF78j
    EQXM07+tpxcl1jM67aYWZTsPtqKi571Y2urIRmiBDDSb5B4AxrUSYAqq6RkA6lXD
    UxAaDT3Tz/TC1V2dtxwJssS/bEOwr/Z127nqAz0CgYAsZDsPoYkDAjRZBnY1oPrI
    tMdCKha/wJCDW6tSWVMvKJF1NwggUJgZYDCAGkXXIynG+2syB4BIpfzItBmHz8N5
    Fo823Q4NZEGCdl9NE/Ltpia5bur1Y/2dTy+siNYuc7AXHCvWRqliViGT818TQoSC
    tUi8fLzQ6vfODgRR+P31YQKBgCDg/EMa71W6Zg+7SRmkZf77U3tXoFREAZQXS8EH
    KhgfmNxfmOdMy/OoFlNJXUt221X8vfLtQM6yZCzI+ewPImt+Fyq9sYYKOGedwHzK
    akasuN6qPjpsdLht8xKN8WcOSkZ91wuCGK2kU8+QtEXXbmiFbV12ji9+rFkSssKg
    bAgJAoGBAI1uglzCpiaLDUpMjqnk83xWu6rujFEWdyLHmzS9QNtQfbXNq4zCdPp8
    tofBtmz+7g30RwFYSJCHUp+kp0rwiNjj4JOMf9x4UtGMel8+CghY4uZP05GWjqRM
    51iy21+njFSSFxbs6PZTMcrNS5lQH0l0gxXmBa6m6bFFGRBMbR9s
    """

    private var cachedSecKey: SecKey?

    private init() {
        let clean = rsaPrivateKeyPEM.replacingOccurrences(of: "\n", with: "")
                                    .replacingOccurrences(of: "\r", with: "")
                                    .trimmingCharacters(in: .whitespaces)
        if let keyData = Data(base64Encoded: clean) {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ]
            var error: Unmanaged<CFError>?
            self.cachedSecKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error)
        }
    }

    // MARK: - MD5 摘要计算

    static func md5(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AES-256-CBC PKCS7 (签名加密)

    static func aes256CbcEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        performAES(operation: CCOperation(kCCEncrypt),
                   algorithm: CCAlgorithm(kCCAlgorithmAES),
                   options: CCOptions(kCCOptionPKCS7Padding),
                   key: key,
                   iv: iv,
                   data: data)
    }

    // MARK: - AES-128-CBC PKCS7 (响应解密与播放地址解析)

    static func aes128CbcDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        performAES(operation: CCOperation(kCCDecrypt),
                   algorithm: CCAlgorithm(kCCAlgorithmAES),
                   options: CCOptions(kCCOptionPKCS7Padding),
                   key: key,
                   iv: iv,
                   data: data)
    }

    static func aes128CbcEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        performAES(operation: CCOperation(kCCEncrypt),
                   algorithm: CCAlgorithm(kCCAlgorithmAES),
                   options: CCOptions(kCCOptionPKCS7Padding),
                   key: key,
                   iv: iv,
                   data: data)
    }

    private static func performAES(operation: CCOperation,
                                   algorithm: CCAlgorithm,
                                   options: CCOptions,
                                   key: Data,
                                   iv: Data,
                                   data: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesCrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        CCCrypt(operation,
                                algorithm,
                                options,
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                dataBytes.baseAddress, data.count,
                                bufferBytes.baseAddress, bufferSize,
                                &numBytesCrypted)
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        buffer.count = numBytesCrypted
        return buffer
    }

    // MARK: - RSA-1024/2048 PKCS1 解密

    func rsaDecrypt(cipherData: Data) -> Data? {
        guard let secKey = cachedSecKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(secKey, .rsaEncryptionPKCS1, cipherData as CFData, &error) as Data? else {
            return nil
        }
        return decrypted
    }

    // MARK: - 混合解密 API 响应 (Hybrid Decrypt)

    func decryptAPIResponse(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 弹幕拉取、评论验证码等接口直接返回明文 JSON（API 文档 §6.1 / §6.5）
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return trimmed
        }
        guard trimmed.contains(".") else {
            // 非加密明文（例如某些异常 JSON）
            return trimmed
        }

        let parts = trimmed.components(separatedBy: ".")
        guard parts.count == 2,
              let keyCipherData = Data(base64Encoded: parts[0]),
              let payloadData = Data(base64Encoded: parts[1]) else {
            throw AnimeCryptoError.invalidPayload
        }

        // 1. RSA 解出 16 字节随机密钥字符串
        guard let decryptedKeyData = rsaDecrypt(cipherData: keyCipherData),
              let randomKey = String(data: decryptedKeyData, encoding: .utf8) else {
            throw AnimeCryptoError.rsaDecryptionFailed
        }

        // 2. AES-128 IV 为 randomKey 的反转字符串
        let reversedKey = String(randomKey.reversed())
        guard let keyData = randomKey.data(using: .utf8),
              let ivData = reversedKey.data(using: .utf8) else {
            throw AnimeCryptoError.invalidKeyFormat
        }

        // 3. AES-128-CBC 解密 JSON 载荷
        guard let plainData = Self.aes128CbcDecrypt(data: payloadData, key: keyData, iv: ivData),
              let jsonString = String(data: plainData, encoding: .utf8) else {
            throw AnimeCryptoError.decryptionFailed
        }

        return jsonString
    }
}
