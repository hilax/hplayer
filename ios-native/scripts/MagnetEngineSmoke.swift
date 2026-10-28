import Foundation
import AVFoundation

@main
struct MagnetEngineSmoke {
    static func main() async throws {
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
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let magnet = fixture["magnet"] as? String,
                  let mediaPath = fixture["videoFile"] as? String else { fatalError("Invalid fixture") }
            let media = try Data(contentsOf: URL(fileURLWithPath: mediaPath))
            guard media.count > 65536 else { fatalError("Media fixture is too small") }
            let liveID = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await engine.addMagnet(magnet) }
                group.addTask { try await Task.sleep(nanoseconds: 60_000_000_000); throw NSError(domain: "MagnetSmoke", code: 1) }
                guard let value = try await group.next() else { fatalError("Missing magnet result") }
                group.cancelAll()
                return value
            }
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
            try await engine.removeTorrent(liveID)
            print("Magnet metadata, peer transfer, HTTP range, and AVPlayer playback passed")
        }
        await engine.shutdown()
        print("Torrent engine metadata, local stream, and lifecycle passed")
    }
}
