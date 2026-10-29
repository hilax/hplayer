import Foundation
import AVFoundation

@main
struct MagnetEngineSmoke {
    static func main() async throws {
        verifyMagnetParsing()
        verifyM115Cipher()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-magnet-smoke-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await NuvioEngine.create(configuration: .init(dataDirectory: data, cacheDirectory: cache, uploadMode: .disabled))
        var torrent = Data("d4:infod6:lengthi4e4:name8:test.mp412:piece lengthi16384e6:pieces20:".utf8)
        torrent.append(Data(repeating: 0, count: 20))
        torrent.append(Data("ee".utf8))
        let id = try await engine.addTorrent(torrent)
        let files = try await engine.files(for: id)
        guard files.count == 1, files[0].path == "test.mp4", files[0].size == 4 else { fatalError("Torrent metadata mismatch") }
        let stream = try await engine.prepareStream(torrentID: id, fileIndex: files[0].index)
        guard stream.url.host == "127.0.0.1", stream.fileSize == 4 else { fatalError("Invalid local stream") }
        let snapshot = try await engine.currentStreamStats(stream.id)
        guard snapshot.fileSize == 4 else { fatalError("Invalid stream status") }
        try await engine.stopStream(stream.id)
        try await engine.removeTorrent(id)

        if CommandLine.arguments.count > 1 {
            let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
                  let magnet = fixture["magnet"] as? String,
                  let mediaPath = fixture["videoFile"] as? String else { fatalError("Invalid fixture") }
            let media = try Data(contentsOf: URL(fileURLWithPath: mediaPath))
            guard media.count > 65536 else { fatalError("Media fixture is too small") }
            // 和 App 一样：整理链接、补上公共 Tracker 和 DHT 引导节点后交给引擎
            guard let link = MagnetLink.parse("分享给你：\(magnet) 记得看") else { fatalError("Fixture magnet was not recognized") }
            let engineURI = link.engineURI(publicTrackers: PublicTrackers.builtIn)
            let liveID = try await withTimeout(seconds: 60) { try await engine.addMagnet(engineURI) }
            let liveFiles = try await engine.files(for: liveID)
            guard liveFiles.count == 1, liveFiles[0].path == "fixture.mp4", liveFiles[0].size == UInt64(media.count) else { fatalError("Magnet metadata mismatch") }
            let liveStream = try await engine.prepareStream(torrentID: liveID, fileIndex: liveFiles[0].index)
            let stats = try await engine.preloadStream(liveStream, minimumContiguousBytes: 65536)
            guard stats.contiguousReadyBytes >= 65536 else { fatalError("Preload did not become ready") }
            var request = URLRequest(url: liveStream.url)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            request.timeoutInterval = 30
            let (actual, response) = try await URLSession.shared.data(for: request)
            let expected = Data(media.prefix(65536))
            guard (response as? HTTPURLResponse)?.statusCode == 206, actual == expected else { fatalError("Peer-streamed bytes differ from seed") }
            let player = AVPlayer(url: liveStream.url)
            player.play()
            var advanced = false
            for _ in 0..<100 {
                if player.currentItem?.status == .failed { throw player.currentItem?.error ?? NSError(domain: "MagnetPlayback", code: 1) }
                if player.currentTime().seconds.isFinite && player.currentTime().seconds > 0.25 { advanced = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            player.pause()
            guard advanced else { fatalError("AVPlayer did not advance") }
            try await engine.stopStream(liveStream.id)

            // 不移除任务直接关闭引擎：种子信息应当留在本机，重新打开时只凭哈希就能立刻拿到文件列表
            await engine.shutdown()
            let reopened = try await NuvioEngine.create(configuration: .init(dataDirectory: data, cacheDirectory: cache, uploadMode: .disabled))
            let hashOnly = "magnet:?xt=urn:btih:\(link.infoHash)"
            let started = Date()
            let restoredID = try await withTimeout(seconds: 15) { try await reopened.addMagnet(hashOnly) }
            let restoredFiles = try await reopened.files(for: restoredID)
            guard restoredFiles.count == 1, restoredFiles[0].path == "fixture.mp4" else { fatalError("Restored metadata mismatch") }
            print("Restored magnet metadata from local state in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            try await reopened.removeTorrent(restoredID)
            await reopened.shutdown()
            print("Magnet metadata, peer transfer, HTTP range, AVPlayer playback, and metadata cache passed")
        }
        await engine.shutdown()
        print("Torrent engine metadata, local stream, and lifecycle passed")
    }

    static func withTimeout<T: Sendable>(seconds: UInt64, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw NSError(domain: "MagnetSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out after \(seconds) s"])
            }
            guard let value = try await group.next() else { fatalError("Missing result") }
            group.cancelAll()
            return value
        }
    }

    /// 115 离线下载接口的请求加密要和开源项目 115driver 的结果一模一样（数据由它的 Go 代码生成，填充固定）
    static func verifyM115Cipher() {
        func expect(_ condition: Bool, _ name: String) {
            if !condition { fatalError("m115 cipher failed: \(name)") }
        }
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        let key = Array("0123456789abcdef".utf8)
        let padding: (Int) -> [UInt8] = { size in (0..<size).map { UInt8(($0 * 7 + 1) % 255) + 1 } }
        let short = Array(#"{"pickcode":"abc123"}"#.utf8)
        let long = Array(#"{"ac":"add_task_urls","app_ver":"27.0.5.7","uid":"123456","url[0]":"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=%E6%B5%8B%E8%AF%95&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"}"#.utf8)
        expect(hex(M115Cipher.deriveKey(key, size: 4)) == "5deaf340", "derive 4")
        expect(hex(M115Cipher.deriveKey(key, size: 12)) == "7c51776bb51382084c681d4e", "derive 12")
        expect(M115Cipher.encode(short, key: key, padding: padding) == "MiG3x9TZ100SKCqPXdqKzJBmmAJmFcUyX34149R6x/6m23JBirNu4GaFvaytHUOvCOQzeta8prJLtdtcgd6T0A5RlXd22nRDwsWce5+gebmhNql7dxmnZJaCPxJiIrODeYgXT8guXySVYH686GAmcyu8gJBQhZBIIecbCkk6RGw=", "encode one block")
        expect(M115Cipher.encode(long, key: key, padding: padding) == "Sp/t7eZNBapsTtS3iLlgGsq6pw0GSF7XsZs4f3T+ILd5Ntxe9DxEy6ouw7p2u1Z8XDgdqyXFdHdAfZOtXVs5yP5RL8VllECVbDP7C2AmytYfpXrHjYY9sljnM4feB6IDRgY8LrIWKMrz9+Sz3JdrNtpFtT2qw+NFsqpViH0ImqcW3HSOEvWCXIDzKtkSctE6W2WJynzytUJWT8+LfFC8PGdS7tf4T2W/70FDbcjCk4ow9K5Dm2rPkJffLkV5m9wj5PWB65FEfmDwOWBAc1B9l1RIgLvMXrTxaoa85/mJSo0M2kXnIq8uVhZo8+OOfyOgC/IaWLLMTybRYBKZNCBoNw==", "encode two blocks")
        let decoded = try? M115Cipher.decode("LJgMsY4Y0UqOtrIwSUArgiGltcQZuTdPw/UuG5sFfJcydO6EGnPVFsThF1Jugit8VoCg4rN1mxYUghRywjG2rEsm5JUl3SNpobPehDA3+QRKGeymzCLJmc7W3Q/LjdgNmPDtxWJvsXXDMyWJjy4Z+K5LZPw8YtUZleJayDKHEIhW76XxVEl2iuui3EZcAm3XNn1iqr+mCmxeojo1ES6jF0XHS7mQNOpRufZud/5WxBTcCcbc2ezPgYYgZOr1HpS/9s6YLg+hUNcGDodDrJtedvSOog3k0kOymqXl8xRIsDEUJql2ZJ876e2G7FitOI4p7dhF1+IvnT0c+6pxgMMtrg==", key: key)
        expect(decoded.map(hex) == "b3e230724e7801b1f3ce5f5b1e37447f03ac2a45292841459523b608f879f2c17bbc1747ddd0e69fdf2ead275e29a0d7a88625c81d6a68ae663216f902ccff7dd516bb69651cd011da805e342f0d19ff724014a0cfc98016d7e1e8b8ef820ea182e0ebc965f1710d140b58dc6c55a89ea241086c60b0ffda22c4d4af07d3f66024d440a6bae67e66915da6fc2d00cce22833af681d71b18c9da788b3e29cc6f0b89908a9d2146bb6c514fb48632e182747e71e46042f925e0c822c5a733d720089d80913bccf22099ebf53", "decode")
        let started = Date()
        for _ in 0..<5 { _ = M115Cipher.encode(long, key: M115Cipher.randomKey()) }
        print("m115 cipher passed (5 encodes in \(String(format: "%.3f", Date().timeIntervalSince(started))) s)")
    }

    /// 各种粘贴进来的写法都要能识别
    static func verifyMagnetParsing() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let base32 = "AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH"
        func expect(_ condition: Bool, _ name: String) {
            if !condition { fatalError("Magnet parsing failed: \(name)") }
        }

        let plain = MagnetLink.parse("magnet:?xt=urn:btih:\(hash)&dn=Test")
        expect(plain?.infoHash == hash && plain?.displayName == "Test", "plain")

        let messy = MagnetLink.parse("资源：MAGNET:?XT=URN:BTIH:\(hash.uppercased())&DN=测试 视频.mp4 大小 1GB")
        expect(messy?.infoHash == hash, "uppercase link inside text")
        expect(messy?.displayName == "测试", "unencoded name ends at whitespace")
        expect(messy?.uri.hasPrefix("magnet:?xt=urn:btih:\(hash)&dn=%E6%B5%8B%E8%AF%95") == true, "canonical uri")

        let punctuated = MagnetLink.parse("【磁力】magnet:?xt=urn:btih:\(hash)&dn=%E6%B5%8B%E8%AF%95】")
        expect(punctuated?.displayName == "测试", "percent-encoded name before Chinese bracket")

        expect(MagnetLink.parse(hash.uppercased())?.infoHash == hash, "bare hash")
        expect(MagnetLink.parse("提取码 \(hash) 谢谢")?.infoHash == hash, "hash inside text")
        expect(MagnetLink.parse("magnet:?xt=urn:btih:\(base32)")?.infoHash == hash, "base32 link")
        expect(MagnetLink.parse(base32.lowercased())?.infoHash == hash, "bare base32")

        let thunder = "thunder://" + Data("AAmagnet:?xt=urn:btih:\(hash)ZZ".utf8).base64EncodedString()
        expect(MagnetLink.parse(thunder)?.infoHash == hash, "thunder link")

        let v2 = String(repeating: "ab", count: 32)
        let v2Link = MagnetLink.parse("magnet:?xt=urn:btmh:1220\(v2)")
        expect(v2Link?.infoHash == v2 && v2Link?.isV2Only == true, "v2 link")

        expect(MagnetLink.parse("hello world") == nil, "plain text")
        expect(MagnetLink.parse("magnet:?xt=urn:btih:1234") == nil, "short hash")
        expect(MagnetLink.parse("abc\(hash)") == nil, "hash glued to letters")

        guard let rich = MagnetLink.parse("magnet:?xt=urn:btih:\(hash)&tr=udp%3A%2F%2Fexample.org%3A80%2Fannounce&tr=wss%3A%2F%2Fexample.org&x.pe=127.0.0.1:6881") else {
            fatalError("Magnet parsing failed: rich link")
        }
        expect(rich.trackers == ["udp://example.org:80/announce"], "keeps supported trackers only")
        let uri = rich.engineURI(publicTrackers: PublicTrackers.builtIn)
        expect(uri.hasPrefix("magnet:?xt=urn:btih:\(hash)&tr=udp%3A%2F%2Fexample.org%3A80%2Fannounce"), "original tracker first")
        expect(uri.contains("&x.pe=127.0.0.1:6881"), "keeps x.pe")
        expect(uri.contains("&dht=router.bittorrent.com:6881"), "adds DHT bootstrap node")
        expect(uri.components(separatedBy: "&tr=").count - 1 == PublicTrackers.builtIn.count + 1, "adds public trackers")
        expect(PublicTrackers.builtIn.allSatisfy { MagnetLink.isValidTracker($0) }, "built-in trackers are valid")
        print("Magnet link parsing passed")
    }
}
