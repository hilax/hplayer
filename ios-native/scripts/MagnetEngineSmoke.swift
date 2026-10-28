import Foundation

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
        await engine.shutdown()
        print("Torrent engine metadata, local stream, and lifecycle passed")
    }
}
