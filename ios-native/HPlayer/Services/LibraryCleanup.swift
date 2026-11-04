import Combine
import Foundation

/// 同一个文件夹里的一批失效视频（片库里还记着，网盘里已经找不到了）。
struct StaleFileGroup: Identifiable, Equatable {
    enum Reason: Equatable {
        /// 文件夹还在，视频已经不在里面
        case fileGone
        /// 连文件夹也找不到了（删除了，或者被移到了别处）
        case folderGone
    }

    let folderID: String
    let folderName: String
    let reason: Reason
    let files: [P115File]

    var id: String { folderID }
}

/// 找出片库里已经失效的网盘视频。
enum StaleLibraryFiles {
    /// - Parameters:
    ///   - library: 片库里记着的网盘视频
    ///   - found: 这次核对读到的视频提取码
    ///   - liveFolders: 这次核对读到的文件夹（文件夹编号 → 上一级和名字）
    ///   - recordedFolders: 以前扫描时记下的文件夹，文件夹被删以后只能靠它知道原来的位置
    ///   - scopeFolderID: 只核对的那个文件夹；nil 表示核对了整个网盘
    static func find(library: [P115File], found: Set<String>, liveFolders: [String: CloudFolderEntry],
                     recordedFolders: [String: CloudFolderEntry], scopeFolderID: String?, scopeName: String) -> [StaleFileGroup] {
        var live = Set(liveFolders.keys)
        live.insert(scopeFolderID ?? "0")

        let candidates: [P115File]
        if let scope = scopeFolderID {
            // 所选文件夹和它下面的所有子文件夹：这次读到的，加上以前记录里挂在它下面的（可能已被删）
            var inScope = live
            var children: [String: [String]] = [:]
            for (id, entry) in recordedFolders { children[entry.parent, default: []].append(id) }
            var pending = [scope]
            var visited: Set<String> = [scope]
            while let current = pending.popLast() {
                for child in children[current] ?? [] where visited.insert(child).inserted {
                    inScope.insert(child)
                    pending.append(child)
                }
            }
            candidates = library.filter { inScope.contains($0.parentId) && !found.contains($0.pickCode) }
        } else {
            candidates = library.filter { !found.contains($0.pickCode) }
        }

        let groups = Dictionary(grouping: candidates, by: \.parentId).map { folderID, files -> StaleFileGroup in
            let name: String
            if let known = liveFolders[folderID]?.name ?? recordedFolders[folderID]?.name {
                name = known
            } else if folderID == scopeFolderID {
                name = scopeName
            } else if folderID == "0" {
                name = "115 网盘根目录"
            } else {
                name = "名称没有记录的文件夹"
            }
            return StaleFileGroup(
                folderID: folderID, folderName: name,
                reason: live.contains(folderID) ? .fileGone : .folderGone,
                files: files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
        }
        // 文件夹整个没了的排前面，其次按名字
        return groups.sorted { left, right in
            let leftRank = left.reason == .folderGone ? 0 : 1
            let rightRank = right.reason == .folderGone ? 0 : 1
            if leftRank != rightRank { return leftRank < rightRank }
            return left.folderName.localizedStandardCompare(right.folderName) == .orderedAscending
        }
    }
}

/// 「清理已失效文件」：先把所选范围（整个网盘或某个文件夹）在网盘里读一遍，
/// 再和片库里记着的视频对照，网盘里已经没有的列出来，由用户确认后从片库移除。
///
/// 用一个独立的扫描器，不动片库自己的扫描进度；只改这台设备上的片库记录，不碰网盘里的任何文件。
@MainActor
final class LibraryCleanup: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case scanning
        case review
        case nothing
        /// 读整个网盘却一个视频都没读到：多半是网络或 115 出了问题，不能据此清理
        case suspicious
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var groups: [StaleFileGroup] = []
    @Published private(set) var removedCount = 0
    private(set) var scopeName = "整个网盘"
    private(set) var scopeID: String?
    /// 核对时片库里记着的网盘视频总数
    private(set) var libraryCount = 0

    let scanner = CloudLibraryScanner(storageKeyPrefix: "hplayer.libraryCleanup.v1")
    private let appState: AppState
    private let library: MediaLibraryStore
    private var accountID: String?
    private var live: [String: CloudFolderEntry] = [:]
    private var running = false
    private var observer: AnyCancellable?

    init(appState: AppState, library: MediaLibraryStore) {
        self.appState = appState
        self.library = library
        observer = scanner.$phase.removeDuplicates().sink { [weak self] _ in
            // @Published 在值改变之前就通知，等这一轮结束再读扫描器的状态
            Task { @MainActor in self?.scannerChanged() }
        }
    }

    var isFolderScope: Bool { scopeID != nil }

    /// scope 为 nil：核对整个网盘
    func start(scope: (id: String, name: String)?) {
        guard let accountID = appState.libraryAccountID, appState.isAuthenticated, let client = appState.directClient() else {
            phase = .failed("请先登录 115 网盘")
            return
        }
        self.accountID = accountID
        scopeID = scope?.id
        scopeName = scope?.name ?? "整个网盘"
        live = [:]
        groups = []
        running = true
        phase = .scanning
        scanner.onFolders = { [weak self] folders in
            guard let self, self.accountID == self.appState.libraryAccountID, self.appState.isAuthenticated else { return }
            self.live.merge(folders) { _, new in new }
            // 顺便记下目录的上下级，以后文件夹被删了还能知道它原来在哪
            self.library.recordFolders(folders, for: self.appState)
        }
        scanner.start(accountID: accountID, root: scope, fetchPage: { cid, offset in
            try await client.filesPage(cid: cid, offset: offset)
        }, onBatch: { _ in }, restart: true, replayInventory: false)
    }

    /// 核对中途出错后接着读
    func retry() {
        guard let client = appState.directClient() else {
            phase = .failed("请先登录 115 网盘")
            return
        }
        running = true
        phase = .scanning
        scanner.resume(fetchPage: { cid, offset in
            try await client.filesPage(cid: cid, offset: offset)
        }, onBatch: { _ in }, replayInventory: false)
    }

    /// 回到选择范围
    func stop() {
        cancel()
        groups = []
        phase = .choosing
    }

    /// 页面关掉时：停下并丢掉临时的扫描结果
    func cancel() {
        running = false
        scanner.onFolders = nil
        scanner.discardSavedState()
    }

    func remove(folderIDs: Set<String>) {
        let chosen = groups.filter { folderIDs.contains($0.folderID) }
        let pickCodes = Set(chosen.flatMap { $0.files.map(\.pickCode) })
        library.remove(pickCodes: pickCodes, for: appState)
        library.forgetFolders(Set(chosen.filter { $0.reason == .folderGone }.map(\.folderID)), for: appState)
        library.flush()
        removedCount = pickCodes.count
        phase = .done
    }

    private func scannerChanged() {
        guard running else { return }
        switch scanner.phase {
        case .completed:
            finish()
        case .failed:
            running = false
            let message = scanner.lastError
            phase = .failed(message.isEmpty ? "核对没有完成，请重试" : message)
        default:
            break
        }
    }

    private func finish() {
        running = false
        guard accountID == appState.libraryAccountID, appState.isAuthenticated else {
            scanner.discardSavedState()
            phase = .failed("115 账号已经变更，请重新核对")
            return
        }
        let found = Set(scanner.discoveredFiles.map(\.pickCode))
        let files = library.files(for: appState)
        libraryCount = files.count
        scanner.discardSavedState()
        if scopeID == nil, found.isEmpty, !files.isEmpty {
            phase = .suspicious
            return
        }
        groups = StaleLibraryFiles.find(
            library: files, found: found, liveFolders: live,
            recordedFolders: library.folders(for: appState), scopeFolderID: scopeID, scopeName: scopeName
        )
        phase = groups.isEmpty ? .nothing : .review
    }
}
