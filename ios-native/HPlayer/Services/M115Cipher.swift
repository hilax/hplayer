import Foundation

/// 115 客户端接口（离线下载、原画下载地址等）使用的请求加密，俗称 m115。
///
/// 做法与开源项目 115driver 的 pkg/crypto/m115 相同：
/// 随机 16 字节密钥放在明文前面，正文经过两轮异或和反转，再用 115 的 RSA 公钥按 PKCS#1 v1.5 分块加密；
/// 服务器返回的内容用同一把公钥做一次模幂运算还原，再按密钥异或解开。
/// 只依赖 Foundation，云构建里的冒烟测试会用 115driver 生成的数据核对结果。
enum M115Cipher {
    enum CipherError: LocalizedError {
        case invalidBase64
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .invalidBase64: return "115 返回的加密数据无法解码"
            case .invalidPayload: return "115 返回的加密数据格式不对"
            }
        }
    }

    static let keyLength = 128

    static func randomKey() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// 加密请求体。padding 只在测试里指定，正常使用随机的非零填充。
    static func encode(_ input: [UInt8], key: [UInt8], padding: ((Int) -> [UInt8])? = nil) -> String {
        var body = input
        xorTransform(&body, key: deriveKey(key, size: 4))
        body.reverse()
        xorTransform(&body, key: clientKey)
        let buffer = key + body

        var output: [UInt8] = []
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + keyLength - 11, buffer.count)
            let chunk = Array(buffer[offset..<end])
            let padSize = keyLength - chunk.count - 3
            let pad = padding?(padSize) ?? randomPadding(padSize)
            output += encryptBlock(chunk, padding: pad)
            offset = end
        }
        return Data(output).base64EncodedString()
    }

    /// 解开服务器返回的 data 字段
    static func decode(_ text: String, key: [UInt8]) throws -> [UInt8] {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw CipherError.invalidBase64 }
        let input = [UInt8](data)
        var plain: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let end = min(offset + keyLength, input.count)
            let value = publicOperation(Array(input[offset..<end]))
            // 去掉填充：跳过开头的 0，再找到下一个 0，后面才是正文
            var start = 0
            while start < value.count && value[start] == 0 { start += 1 }
            if start < value.count, let separator = value[(start + 1)...].firstIndex(of: 0) {
                plain += value[(separator + 1)...]
            }
            offset = end
        }
        guard plain.count >= 16 else { throw CipherError.invalidPayload }
        var body = Array(plain[16...])
        xorTransform(&body, key: deriveKey(Array(plain[0..<16]), size: 12))
        body.reverse()
        xorTransform(&body, key: deriveKey(key, size: 4))
        return body
    }

    // MARK: 异或

    static func deriveKey(_ seed: [UInt8], size: Int) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: size)
        for index in 0..<size {
            let mixed: UInt8 = seed[index] &+ keySeed[size * index]
            let mask: UInt8 = keySeed[size * (size - index - 1)]
            key[index] = mixed ^ mask
        }
        return key
    }

    static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        let count = data.count
        let keySize = key.count
        guard count > 0, keySize > 0 else { return }
        let head = count % 4
        for index in 0..<head {
            data[index] ^= key[index % keySize]
        }
        for index in head..<count {
            data[index] ^= key[(index - head) % keySize]
        }
    }

    private static func randomPadding(_ size: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<size).map { _ in UInt8.random(in: 1...255, using: &generator) }
    }

    // MARK: RSA

    private static func encryptBlock(_ chunk: [UInt8], padding: [UInt8]) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: keyLength)
        block[1] = 2
        for (index, byte) in padding.enumerated() where 2 + index < keyLength {
            block[2 + index] = byte == 0 ? 1 : byte
        }
        let start = keyLength - chunk.count
        for (index, byte) in chunk.enumerated() {
            block[start + index] = byte
        }
        return publicOperation(block)
    }

    /// 公钥模幂：value ^ 65537 mod N，结果固定 128 字节
    static func publicOperation(_ value: [UInt8]) -> [UInt8] {
        var base = limbs(from: value)
        if compare(base, modulus) >= 0 { subtract(&base, modulus) }
        var result = base
        // 65537 = 2^16 + 1：先平方 16 次，再乘一次底数
        for _ in 0..<16 { result = multiplyMod(result, result) }
        result = multiplyMod(result, base)
        return bytes(from: result, length: keyLength)
    }

    private static let limbCount = 33

    private static let modulus: [UInt32] = {
        let hex = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021"
            + "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633"
            + "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1"
            + "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return M115Cipher.limbs(from: bytes)
    }()

    /// 大端字节转成低位在前的 32 位分组
    private static func limbs(from bytes: [UInt8]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: limbCount)
        for (offset, byte) in bytes.reversed().enumerated() where offset / 4 < limbCount {
            result[offset / 4] |= UInt32(byte) << UInt32((offset % 4) * 8)
        }
        return result
    }

    private static func bytes(from limbs: [UInt32], length: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: length)
        for index in 0..<length where index / 4 < limbs.count {
            output[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 4] >> UInt32((index % 4) * 8))
        }
        return output
    }

    /// (a × b) mod N，a、b 都小于 N。按位「翻倍再加」，只用到移位、加减和比较。
    private static func multiplyMod(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: limbCount)
        var started = false
        for limb in stride(from: limbCount - 1, through: 0, by: -1) {
            let word = b[limb]
            if !started && word == 0 { continue }
            started = true
            for bit in stride(from: 31, through: 0, by: -1) {
                shiftLeftOne(&result)
                if compare(result, modulus) >= 0 { subtract(&result, modulus) }
                if (word >> UInt32(bit)) & 1 == 1 {
                    add(&result, a)
                    if compare(result, modulus) >= 0 { subtract(&result, modulus) }
                }
            }
        }
        return result
    }

    private static func shiftLeftOne(_ value: inout [UInt32]) {
        var carry: UInt32 = 0
        for index in 0..<value.count {
            let current = value[index]
            value[index] = (current << 1) | carry
            carry = current >> 31
        }
    }

    private static func add(_ value: inout [UInt32], _ other: [UInt32]) {
        var carry: UInt64 = 0
        for index in 0..<value.count {
            let sum = UInt64(value[index]) + UInt64(other[index]) + carry
            value[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
    }

    private static func subtract(_ value: inout [UInt32], _ other: [UInt32]) {
        var borrow: UInt64 = 0
        for index in 0..<value.count {
            let current = UInt64(value[index])
            let needed = UInt64(other[index]) + borrow
            if current >= needed {
                value[index] = UInt32(truncatingIfNeeded: current - needed)
                borrow = 0
            } else {
                value[index] = UInt32(truncatingIfNeeded: current + (1 << 32) - needed)
                borrow = 1
            }
        }
    }

    private static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        for index in stride(from: lhs.count - 1, through: 0, by: -1) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? -1 : 1
        }
        return 0
    }

    // MARK: 常量（与 115driver 相同）

    private static let keySeed: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]

    private static let clientKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
        0x4c, 0x01, 0x3f, 0x46,
    ]
}
