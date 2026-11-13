import Foundation

/// 所选文件和文件夹的汇总，用在底部操作栏和各个确认弹层的文字里。
struct FileSelectionSummary: Equatable {
    private(set) var folders = 0
    private(set) var videos = 0
    private(set) var others = 0
    /// 所选文件的大小合计；文件夹里的内容不在其中
    private(set) var bytes = 0

    init(_ files: [P115File]) {
        for file in files {
            if file.isDir {
                folders += 1
            } else if file.isVideo {
                videos += 1
                bytes += max(0, file.size)
            } else {
                others += 1
                bytes += max(0, file.size)
            }
        }
    }

    var count: Int { folders + videos + others }

    private var parts: [String] {
        var result: [String] = []
        if folders > 0 { result.append("\(folders) 个文件夹") }
        if videos > 0 { result.append("\(videos) 个视频") }
        if others > 0 { result.append("\(others) 个其他文件") }
        return result
    }

    /// 「1 个文件夹，2 个视频」
    var kindsText: String { parts.joined(separator: "，") }

    /// 「1 个文件夹 · 2 个视频，共 6.19 GB」
    var text: String {
        let list = parts.joined(separator: " · ")
        guard bytes > 0 else { return list }
        return list + "，共 " + DownloadFormat.bytes(Int64(bytes))
    }
}

/// 文件夹之间的上下级关系
enum FolderTree {
    /// `roots` 以及记录里挂在它们下面的所有子文件夹的编号
    static func descendants(of roots: Set<String>, recorded: [String: CloudFolderEntry]) -> Set<String> {
        guard !roots.isEmpty else { return [] }
        var children: [String: [String]] = [:]
        for (id, entry) in recorded { children[entry.parent, default: []].append(id) }
        var result = roots
        var pending = Array(roots)
        while let current = pending.popLast() {
            for child in children[current] ?? [] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }
}

/// 在网盘里改名、移动、删除之后，让这台设备上的片库记录和续播记录跟上。
/// 只改本机的记录；网盘里的文件由 `Direct115Client` 的各个操作负责。
@MainActor
enum LibraryFileSync {
    /// 删除这些条目会波及的片库视频：直接选中的视频，加上记录里位于所选文件夹（含子文件夹）下的视频。
    /// 只有扫描时记录过的文件夹层级才能被找到。
    static func affectedVideos(_ selected: [P115File], library: MediaLibraryStore, appState: AppState) -> [P115File] {
        let inLibrary = library.files(for: appState)
        guard !inLibrary.isEmpty else { return [] }
        let folderIDs = Set(selected.filter { $0.isDir }.map { $0.id })
        let tree = FolderTree.descendants(of: folderIDs, recorded: library.folders(for: appState))
        let codes = Set(selected.filter { !$0.isDir }.map { $0.pickCode })
        return inLibrary.filter { codes.contains($0.pickCode) || tree.contains($0.parentId) }
    }

    /// 改名之后：片库里的视频改成新名字；记录过的文件夹同样更新
    static func didRename(_ renamed: P115File, library: MediaLibraryStore, appState: AppState) {
        if renamed.isDir {
            library.updateFolder(renamed.id, name: renamed.name, for: appState)
        } else {
            library.update([renamed], for: appState)
        }
    }

    /// 移动之后：视频的所在文件夹、文件夹的上一级都跟着改
    static func didMove(_ moved: [P115File], to destinationID: String, library: MediaLibraryStore, appState: AppState) {
        var videos: [P115File] = []
        for file in moved {
            if file.isDir {
                library.updateFolder(file.id, parent: destinationID, for: appState)
            } else {
                videos.append(file.replacing(parentId: destinationID))
            }
        }
        library.update(videos, for: appState)
    }

    /// 删除之后：如果用户选择同时清理资料库，移除受影响的视频及其续播记录，返回移除的视频数。
    @discardableResult
    static func didDelete(_ selected: [P115File], removeFromLibrary: Bool, library: MediaLibraryStore,
                          recents: RecentStore?, appState: AppState) -> Int {
        guard removeFromLibrary else { return 0 }
        let videos = affectedVideos(selected, library: library, appState: appState)
        let codes = Set(videos.map { $0.pickCode })
        let folderIDs = Set(selected.filter { $0.isDir }.map { $0.id })
        let tree = FolderTree.descendants(of: folderIDs, recorded: library.folders(for: appState))
        library.remove(pickCodes: codes, for: appState)
        library.forgetFolders(tree, for: appState)
        recents?.removeCloud(pickCodes: codes)
        return codes.count
    }
}

/// 一次文件管理操作之后给用户看的话
enum FileOperationText {
    static func downloadResult(_ summary: DownloadEnqueueSummary) -> String {
        var parts: [String] = []
        if summary.added > 0 { parts.append("已加入下载 \(summary.added) 个文件，可在 我的 › 本机视频 查看") }
        if summary.duplicates > 0 { parts.append("\(summary.duplicates) 个已在下载列表里") }
        if summary.folders > 0 { parts.append("文件夹暂不支持下载，已跳过 \(summary.folders) 个") }
        if summary.unavailable > 0 { parts.append("\(summary.unavailable) 个文件没有下载地址") }
        return parts.isEmpty ? "没有可下载的文件" : parts.joined(separator: "；")
    }

    /// 网盘路径文字，第一级固定叫「网盘」：网盘 / 电影 / 2024
    static func pathLabel(_ trail: [Crumb]) -> String {
        guard !trail.isEmpty else { return "网盘" }
        var names = trail.map { $0.name }
        names[0] = "网盘"
        return names.joined(separator: " / ")
    }
}
