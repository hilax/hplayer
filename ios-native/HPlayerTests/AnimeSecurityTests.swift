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

    func testDecodesRealWorldAnimePayloads() throws {
        // 接口真实样本：stars 在列表里是字符串、在详情里是数字。
        let listJSON = """
        {"code":20000,"message":"请求成功!","data":{"total":1,"items":[{"id":180167,"cid":20,"name":"恋爱与选举与巧克力","pic":"http://p4-ad.adukwai.com/x.jpg","year":"2012","area":"日本","continu":"13全","type":"后宫,校园","stars":""}]}}
        """
        let listResponse = try JSONDecoder().decode(
            AnimeAPIResponse<AnimeVideoListResult>.self, from: Data(listJSON.utf8)
        )
        XCTAssertEqual(listResponse.data?.items.first?.name, "恋爱与选举与巧克力")
        XCTAssertEqual(listResponse.data?.items.first?.safePicURLString, "https://p4-ad.adukwai.com/x.jpg")

        let detailJSON = """
        {"code":20000,"message":"请求成功!","data":{"id":180167,"name":"恋爱与选举与巧克力","stars":1,"pic":"http://p4-ad.adukwai.com/x.jpg","parts":[{"play":"newup-jp","play_zh":"日语","single_clarity_display":1,"part":["第01集"]}]}}
        """
        let detailResponse = try JSONDecoder().decode(
            AnimeAPIResponse<AnimeVideoDetail>.self, from: Data(detailJSON.utf8)
        )
        XCTAssertEqual(detailResponse.data?.stars, "1")
        XCTAssertEqual(detailResponse.data?.safePicURLString, "https://p4-ad.adukwai.com/x.jpg")
        XCTAssertEqual(detailResponse.data?.parts.first?.part.first, "第01集")
    }

    func testAnimeQualityResolutionAndSorting() throws {
        let q1 = PlaybackQualityItem(id: "0", title: "720P 高清", url: URL(string: "http://example.com/720.m3u8")!)
        let q2 = PlaybackQualityItem(id: "1", title: "1080P 超清", url: URL(string: "http://example.com/1080.m3u8")!)
        let q3 = PlaybackQualityItem(id: "2", title: "480P 标清", url: URL(string: "http://example.com/480.m3u8")!)

        let stream = AnimeResolvedStream(
            url: q2.url,
            headers: ["User-Agent": ""],
            format: "hls",
            title: "测试番剧 第01集",
            qualityTitle: "1080P 超清",
            qualities: [q2, q1, q3]
        )

        // 验证默认画质为最高画质
        XCTAssertEqual(stream.qualityTitle, "1080P 超清")
        XCTAssertEqual(stream.url.absoluteString, "http://example.com/1080.m3u8")
        XCTAssertEqual(stream.qualities.count, 3)

        // 验证构建出的 PlaybackSource 包含多画质
        let source = PlaybackSource.online(
            title: stream.title,
            url: stream.url,
            headers: stream.headers,
            qualities: stream.qualities,
            currentQuality: stream.qualityTitle
        )
        if case .online(_, let url, _, let qualities, let curQ) = source {
            XCTAssertEqual(url.absoluteString, "http://example.com/1080.m3u8")
            XCTAssertEqual(curQ, "1080P 超清")
            XCTAssertEqual(qualities.count, 3)
        } else {
            XCTFail("PlaybackSource.online 匹配失败")
        }
    }
}
