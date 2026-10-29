import Foundation
import AVFoundation

@main
struct MagnetEngineSmoke {
    static func main() async throws {
        verifyMagnetParsing()

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
