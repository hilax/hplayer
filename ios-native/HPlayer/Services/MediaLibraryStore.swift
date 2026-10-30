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

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: [P115File]].self, from: data) {
            cloudByAccount = decoded
        } else {
            cloudByAccount = [:]
        }
    }

    func files(for appState: AppState) -> [P115File] {
        guard appState.isAuthenticated, let scope = scope(appState) else { return [] }
        return cloudByAccount[scope] ?? []
    }

    func add(_ files: [P115File], for appState: AppState) {
        guard let scope = scope(appState) else { return }
        var result = cloudByAccount[scope] ?? []
        for file in files where file.isVideo && !file.isDir && !file.pickCode.isEmpty {
            result.removeAll { $0.pickCode == file.pickCode }
            result.append(file)
        }
        cloudByAccount[scope] = result
        save()
    }

    func remove(pickCode: String, for appState: AppState) {
        guard let scope = scope(appState) else { return }
        cloudByAccount[scope]?.removeAll { $0.pickCode == pickCode }
        save()
    }

    private func scope(_ appState: AppState) -> String? {
        let cookie = appState.directCookie ?? ""
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "UID", let userID = pair[1].split(separator: "_").first {
                return "device:\(userID)"
            }
        }
        return nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cloudByAccount) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
