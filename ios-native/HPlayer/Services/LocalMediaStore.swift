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

    private let fm = FileManager.default
    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "ts", "flv", "webm", "wmv",
    ]

    var mediaDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Media", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init() {
        refresh()
    }

    func refresh() {
        guard let items = try? fm.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            return
        }

        files = items
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                return LocalMedia(
                    url: url,
                    size: values?.fileSize ?? 0,
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            let destination = mediaDirectory.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try? fm.copyItem(at: url, to: destination)
        }
        refresh()
    }

    func delete(_ media: LocalMedia) {
        try? fm.removeItem(at: media.url)
        refresh()
    }
}
