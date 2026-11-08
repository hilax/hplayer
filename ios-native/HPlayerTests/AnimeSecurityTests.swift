import XCTest
import CommonCrypto
@testable import HPlayer

final class AnimeSecurityTests: XCTestCase {

    func testMD5HashCalculation() {
        let input = "hello anime"
        let hash = AnimeCrypto.md5(input)
        XCTAssertEqual(hash, "f06889680fa6bed118b1071dcb95be86")
    }

    func testAES256RoundTrip() {
        let key = Data("ziISjqkXPsGUMRNGyWigxDGtJbfTdcGv".utf8)
        let iv = Data("WonrnVkxeIxDcFbv".utf8)
        let plain = "2.4.7.9-1794108715730-IOS-1.0.0.1-10E3199773CC47A99F20B09F17B365D8"
        let plainData = Data(plain.utf8)

        guard let encrypted = AnimeCrypto.aes256CbcEncrypt(data: plainData, key: key, iv: iv) else {
            XCTFail("AES256 加密失败")
            return
        }

        XCTAssertFalse(encrypted.isEmpty)

        // 解密验证
        var outData = Data(count: encrypted.count + 16)
        var outLength = 0
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let cipherBytes = [UInt8](encrypted)

        let status = outData.withUnsafeMutableBytes { outBuf in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes, key.count,
                ivBytes,
                cipherBytes, encrypted.count,
                outBuf.baseAddress, outBuf.count,
                &outLength
            )
        }

        XCTAssertEqual(status, Int32(kCCSuccess))
        outData.count = outLength
        XCTAssertEqual(String(data: outData, encoding: .utf8), plain)
    }

    func testAES128RoundTrip() {
        let key = Data("UY9kxQEtk8Dn08Kr".utf8)
        let iv = Data("J5jQnzGVRfCe4CUk".utf8)
        let plain = "test-stream-address-payload-12345"
        let plainData = Data(plain.utf8)

        guard let encrypted = AnimeCrypto.aes128CbcEncrypt(data: plainData, key: key, iv: iv) else {
            XCTFail("AES128 加密失败")
            return
        }

        guard let decrypted = AnimeCrypto.aes128CbcDecrypt(data: encrypted, key: key, iv: iv) else {
            XCTFail("AES128 解密失败")
            return
        }

        XCTAssertEqual(String(data: decrypted, encoding: .utf8), plain)
    }

    func testAnimeSignerHeaders() {
        let ts: Int64 = 1794108715730
        let headers = AnimeSigner.shared.headers(customTimestamp: ts)

        XCTAssertEqual(headers["x-version"], "2024-09-24")
        XCTAssertEqual(headers["user-agent"], "Dart/3.6 (dart:io)")
        XCTAssertEqual(headers["appid"], "4150439554430627")
        XCTAssertEqual(headers["ts"], "1794108715730")
        XCTAssertFalse(headers["authentication"]?.isEmpty ?? true)
    }

    func testRealAnimeClientFetch() async throws {
        do {
            let channels = try await AnimeClient.shared.fetchChannels()
            print("Fetched channels count:", channels.count)
            XCTAssertFalse(channels.isEmpty)

            let list = try await AnimeClient.shared.fetchVideoList(sort: "weight", limit: 6, page: 1)
            print("Fetched list count:", list.items.count)
            XCTAssertFalse(list.items.isEmpty)

            guard let firstVideo = list.items.first else { return }
            let detail = try await AnimeClient.shared.fetchDetail(id: firstVideo.id)
            print("Fetched detail for:", detail.name, "parts count:", detail.parts.count)
            XCTAssertFalse(detail.name.isEmpty)
            XCTAssertFalse(detail.parts.isEmpty)

            if let firstRoute = detail.parts.first, let firstEp = firstRoute.part.first {
                print("Fetching play cred for route:", firstRoute.play, "episode:", firstEp)
                let cred = try await AnimeClient.shared.fetchPlayCredential(id: detail.id, play: firstRoute.play, part: firstEp)
                print("Got play cred url:", cred.url.prefix(30))
                XCTAssertFalse(cred.url.isEmpty)

                let resolved = try await AnimePlaybackResolver.shared.resolve(playCode: cred.url, title: "\(detail.name) \(firstEp)")
                print("Resolved final stream URL:", resolved.url.absoluteString)
                XCTAssertTrue(resolved.url.absoluteString.hasPrefix("http"))
            }
        } catch {
            print("Client fetch failed with error:", error)
            XCTFail("AnimeClient fetch failed: \(error)")
        }
    }
}
