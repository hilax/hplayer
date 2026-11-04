import Foundation

struct LibraryMedia: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int
    let localURL: URL?
    let pickCode: String
    let sha1: String
    let thumbnail: String

    init(local: LocalMedia) {
        id = local.id; name = local.name; size = local.size
        localURL = local.url; pickCode = ""; sha1 = ""; thumbnail = ""
    }

    init(cloud: P115File) {
        id = "115|\(cloud.pickCode)"; name = cloud.name; size = cloud.size
        localURL = nil; pickCode = cloud.pickCode; sha1 = cloud.sha1; thumbnail = cloud.thumbUrl
    }

    var source: PlaybackSource {
        if let localURL { return .direct(title: name, url: localURL) }
        return .p115(title: name, pickCode: pickCode)
    }
}

@MainActor
final class MediaLibraryStore: ObservableObject {
    @Published private var cloudByAccount: [String: [P115File]]
    private let storageKey = "hplayer.posterLibrary.cloud.v1"
    private let foldersKey = "hplayer.posterLibrary.folders.v1"
    /// 扫描时见过的文件夹（按账号：文件夹编号 → 上一级和名字）。不显示在界面上，所以不发布。
    private var foldersByAccount: [String: [String: CloudFolderEntry]] = [:]
    private var needsFolderSave = false
    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?
    private var needsSave = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: [P115File]].self, from: data) {
            cloudByAccount = decoded
        } else {
            cloudByAccount = [:]
        }
        if let data = defaults.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([String: [String: CloudFolderEntry]].self, from: data) {
            foldersByAccount = decoded
        }
    }

    func files(for appState: AppState) -> [P115File] {
        guard appState.isAuthenticated, let scope = appState.libraryAccountID else { return [] }
        return cloudByAccount[scope] ?? []
    }

    private var mediaCache: (scope: String, revision: Int, items: [LibraryMedia])?
    private(set) var revision = 0

    /// 首页每次刷新都要用到；片库很大时缓存转换结果，只在内容变化后重算。
    func media(for appState: AppState) -> [LibraryMedia] {
        guard appState.isAuthenticated, let scope = appState.libraryAccountID else { return [] }
        if let cache = mediaCache, cache.scope == scope, cache.revision == revision { return cache.items }
        let items = (cloudByAccount[scope] ?? []).map(LibraryMedia.init(cloud:))
        mediaCache = (scope, revision, items)
        return items
    }

    func add(_ files: [P115File], for appState: AppState) {
        guard appState.isAuthenticated, let scope = appState.libraryAccountID else { return }
        var result = cloudByAccount[scope] ?? []
        var indices = Dictionary(result.enumerated().map { ($0.element.pickCode, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for file in files where file.isVideo && !file.isDir && !file.pickCode.isEmpty {
            if let index = indices[file.pickCode] {
                if result[index] != file { result[index] = file; changed = true }
            } else {
                indices[file.pickCode] = result.count
                result.append(file)
                changed = true
            }
        }
        guard changed else { return }
        cloudByAccount[scope] = result
        revision += 1
        save()
    }

    func remove(pickCode: String, for appState: AppState) {
        guard let scope = appState.libraryAccountID else { return }
        cloudByAccount[scope]?.removeAll { $0.pickCode == pickCode }
        revision += 1
        save()
    }

    /// 批量移除；清理已失效文件用。
    func remove(pickCodes: Set<String>, for appState: AppState) {
        guard !pickCodes.isEmpty, let scope = appState.libraryAccountID, var files = cloudByAccount[scope] else { return }
        let before = files.count
        files.removeAll { pickCodes.contains($0.pickCode) }
        guard files.count != before else { return }
        cloudByAccount[scope] = files
        revision += 1
        save()
    }

    /// 当前账号扫描时见过的文件夹
    func folders(for appState: AppState) -> [String: CloudFolderEntry] {
        guard appState.isAuthenticated, let scope = appState.libraryAccountID else { return [:] }
        return foldersByAccount[scope] ?? [:]
    }

    func recordFolders(_ entries: [String: CloudFolderEntry], for appState: AppState) {
        guard !entries.isEmpty, appState.isAuthenticated, let scope = appState.libraryAccountID else { return }
        var current = foldersByAccount[scope] ?? [:]
        var changed = false
        for (id, entry) in entries where current[id] != entry {
            current[id] = entry
            changed = true
        }
        guard changed else { return }
        foldersByAccount[scope] = current
        needsFolderSave = true
        save()
    }

    func forgetFolders(_ ids: Set<String>, for appState: AppState) {
        guard !ids.isEmpty, let scope = appState.libraryAccountID, var current = foldersByAccount[scope] else { return }
        let before = current.count
        for id in ids { current[id] = nil }
        guard current.count != before else { return }
        foldersByAccount[scope] = current
        needsFolderSave = true
        save()
    }

    private func save() {
        needsSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush(background: true)
        }
    }

    /// 扫描的多页更新合并落盘；退出前立即保存，避免每页重编码整份片库。
    private static let ioQueue = DispatchQueue(label: "hplayer.library.io", qos: .utility)

    func flush(background: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave else { return }
        needsSave = false
        let snapshot = cloudByAccount
        let folders = needsFolderSave ? foldersByAccount : nil
        needsFolderSave = false
        let defaults = defaults
        let key = storageKey
        let foldersKey = foldersKey
        let write = {
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
            if let folders, let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: foldersKey) }
        }
        // 定时保存在后台编码；退出、暂停时的保存等写完再返回。
        if background { Self.ioQueue.async(execute: write) } else { Self.ioQueue.sync(execute: write) }
    }
}
