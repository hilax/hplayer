import Foundation

struct LocalMedia: Identifiable, Hashable {
    let url: URL
    let size: Int
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// 管理导入到 App 沙盒里的本地视频
final class LocalMediaStore: ObservableObject {
    @Published private(set) var files: [LocalMedia] = []
    @Published private(set) var isImporting = false

    private let fm = FileManager.default
    private let directory: URL?
    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "ts", "flv", "webm", "wmv",
    ]

    var mediaDirectory: URL {
        if let directory {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Media", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init(directory: URL? = nil) {
        self.directory = directory
        refresh()
    }

    func refresh() {
        guard let items = try? fm.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            return
        }

        files = items.compactMap { url -> LocalMedia? in
            guard videoExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return LocalMedia(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }

    }

    /// Copy off the main thread; publish only complete files and preserve existing videos.
    @MainActor
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [String] {
        guard !isImporting else { return ["已有视频正在导入，请稍后再试。"] }
        isImporting = true
        defer { isImporting = false }
        let directory = mediaDirectory
        let extensions = videoExtensions
        let failures = await Task.detached(priority: .userInitiated) {
            Self.copyFiles(urls, into: directory, extensions: extensions)
        }.value
        refresh()
        return failures
    }

    private static func copyFiles(_ urls: [URL], into directory: URL, extensions: Set<String>) -> [String] {
        let manager = FileManager.default
        var failures: [String] = []
        for source in urls {
            guard source.isFileURL, extensions.contains(source.pathExtension.lowercased()) else {
                failures.append("\(source.lastPathComponent)：不支持的视频格式。")
                continue
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let original = directory.appendingPathComponent(source.lastPathComponent)
            if source.standardizedFileURL.resolvingSymlinksInPath() == original.standardizedFileURL.resolvingSymlinksInPath() {
                continue
            }
            let temporary = manager.temporaryDirectory.appendingPathComponent("HPlayerImport-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: temporary) }
            do {
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    failures.append("\(source.lastPathComponent)：请选择视频文件。")
                    continue
                }
                try manager.copyItem(at: source, to: temporary)
                let stem = source.deletingPathExtension().lastPathComponent
                var suffix = 1
                while true {
                    let name = suffix == 1 ? source.lastPathComponent : "\(stem) (\(suffix)).\(source.pathExtension)"
                    let destination = directory.appendingPathComponent(name)
                    if manager.fileExists(atPath: destination.path) { suffix += 1; continue }
                    do {
                        try manager.moveItem(at: temporary, to: destination)
                        break
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        suffix += 1
                    }
                }
            } catch {
                failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    func delete(_ media: LocalMedia) {
        try? fm.removeItem(at: media.url)
        refresh()
    }
}
