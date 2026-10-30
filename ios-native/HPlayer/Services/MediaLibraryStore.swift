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
    }

    func files(for appState: AppState) -> [P115File] {
        guard appState.isAuthenticated, let scope = appState.libraryAccountID else { return [] }
        return cloudByAccount[scope] ?? []
    }

    private var mediaCache: (scope: String, revision: Int, items: [LibraryMedia])?
    private var revision = 0

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

    private func save() {
        needsSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 扫描的多页更新合并落盘；退出前立即保存，避免每页重编码整份片库。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave else { return }
        guard let data = try? JSONEncoder().encode(cloudByAccount) else { return }
        defaults.set(data, forKey: storageKey)
        needsSave = false
    }
}
