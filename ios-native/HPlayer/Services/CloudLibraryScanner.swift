import Combine
import Foundation

/// Checkpointed, account-isolated directory traversal. Credentials only live in the fetch closure.
/// Call selectAccount when authentication changes and pause when the app leaves the foreground.
@MainActor
final class CloudLibraryScanner: ObservableObject {
    enum Phase: String, Codable {
        case idle, running, paused, failed, completed
    }

    struct Progress: Equatable {
        var scannedFolders = 0
        var discoveredFolders = 0
        var discoveredVideos = 0
    }

    typealias FetchPage = @MainActor (String, Int) async throws -> Direct115FilePage
    typealias BatchHandler = @MainActor ([P115File]) -> Void

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = Progress()
    @Published private(set) var accountID: String?
    @Published private(set) var discoveredFiles: [P115File] = []
    @Published private(set) var currentFolderName = ""
    @Published private(set) var lastError = ""

    var canResume: Bool { phase == .paused || phase == .failed }

    private struct Folder: Codable {
        let id: String
        let name: String
        var offset = 0
        var previousPageSignature = ""
    }

    private struct Checkpoint: Codable {
        let accountID: String
        let scanID: String
        var phase: Phase = .paused
        var pendingFolders = [Folder(id: "0", name: "115 网盘")]
        var completedFolders: [String] = []
        var inventoryChunks = 0
        var videoCount = 0
        var lastError = ""
    }

    private enum ScanError: LocalizedError {
        case invalidPage, invalidFolder, damagedCheckpoint
        var errorDescription: String? {
            switch self {
            case .invalidPage: return "115 返回了重复或无效的分页，请稍后继续扫描。"
            case .invalidFolder: return "115 返回的目录编号无效，扫描尚未完成。"
            case .damagedCheckpoint: return "扫描记录不完整，请重新扫描。"
            }
        }
    }

    private let defaults: UserDefaults
    private let storageKeyPrefix: String
    private let minimumRequestInterval: TimeInterval
    private let retryBaseDelay: TimeInterval
    private let maximumAttempts: Int
    private var checkpoint: Checkpoint?
    private var knownFolders = Set<String>()
    private var knownVideos = Set<String>()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var previousRequestAt: Date?
    private var damagedCheckpoint = false

    init(
        defaults: UserDefaults = .standard,
        storageKeyPrefix: String = "hplayer.cloudLibraryScan.v1",
        minimumRequestInterval: TimeInterval = 0.35,
        maximumAttempts: Int = 3,
        retryBaseDelay: TimeInterval = 1
    ) {
        self.defaults = defaults
        self.storageKeyPrefix = storageKeyPrefix
        self.minimumRequestInterval = max(0, minimumRequestInterval)
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryBaseDelay = max(0, retryBaseDelay)
    }

    /// accountID is a public account scope such as device:12345, never a Cookie or token.
    func selectAccount(_ newAccountID: String?) {
        let next = newAccountID.flatMap { $0.isEmpty ? nil : $0 }
        guard accountID != next else { return }
        pause()
        accountID = next
        checkpoint = nil
        knownFolders = []
        knownVideos = []
        discoveredFiles = []
        progress = Progress()
        phase = .idle
        currentFolderName = ""
        lastError = ""
        damagedCheckpoint = false
        guard let next, let data = defaults.data(forKey: checkpointKey(next)) else { return }
        do {
            var saved = try JSONDecoder().decode(Checkpoint.self, from: data)
            guard saved.accountID == next, saved.inventoryChunks >= 0, saved.videoCount >= 0,
                  saved.pendingFolders.allSatisfy({ !$0.id.isEmpty && $0.id.allSatisfy(\.isNumber) && $0.offset >= 0 }) else {
                throw ScanError.damagedCheckpoint
            }
            var files: [P115File] = []
            for index in 0..<saved.inventoryChunks {
                guard let chunk = defaults.data(forKey: inventoryKey(saved, index: index)) else {
                    throw ScanError.damagedCheckpoint
                }
                files.append(contentsOf: try JSONDecoder().decode([P115File].self, from: chunk))
            }
            guard files.count == saved.videoCount else { throw ScanError.damagedCheckpoint }
            if saved.phase == .running { saved.phase = .paused }
            checkpoint = saved
            discoveredFiles = files
            knownVideos = Set(files.map(Self.videoID))
            knownFolders = Set(saved.pendingFolders.map(\.id) + saved.completedFolders)
            publish(saved)
            try persist(saved)
        } catch {
            damagedCheckpoint = true
            phase = .failed
            lastError = ScanError.damagedCheckpoint.localizedDescription
        }
    }

    /// Starts a new scan or resumes its last committed page. Replays saved inventory first:
    /// a process exit between saving a page and updating the poster library cannot lose videos.
    func start(accountID: String, fetchPage: @escaping FetchPage, onBatch: @escaping BatchHandler, restart: Bool = false, replayInventory: Bool = true) {
        selectAccount(accountID)
        guard self.accountID == accountID, !accountID.isEmpty else { return }
        if phase == .running && !restart { return }
        if damagedCheckpoint && !restart { return }
        invalidateTask()
        do {
            if checkpoint == nil || restart {
                let old = checkpoint
                let fresh = Checkpoint(accountID: accountID, scanID: UUID().uuidString)
                try persist(fresh)
                checkpoint = fresh
                knownFolders = ["0"]
                knownVideos = []
                discoveredFiles = []
                damagedCheckpoint = false
                if let old { removeInventory(old) }
            }
            guard var saved = checkpoint else { return }
            let token = generation
            saved.phase = .running
            saved.lastError = ""
            try persist(saved)
            checkpoint = saved
            publish(saved)
            task = Task { [weak self] in
                // Let the sheet paint before restoring a potentially large inventory. Replaying once
                // avoids repeatedly merging and saving the full library for every hundred saved files.
                await Task.yield()
                guard let self, self.isCurrent(token, accountID), !Task.isCancelled else { return }
                if replayInventory, !self.discoveredFiles.isEmpty { onBatch(self.discoveredFiles) }
                guard self.isCurrent(token, accountID), !Task.isCancelled else { return }
                await self.run(token: token, accountID: accountID, fetchPage: fetchPage, onBatch: onBatch)
            }
        } catch {
            phase = .failed
            lastError = "无法保存扫描进度，请稍后重试。"
        }
    }

    func resume(fetchPage: @escaping FetchPage, onBatch: @escaping BatchHandler, replayInventory: Bool = true) {
        guard let accountID else { return }
        start(accountID: accountID, fetchPage: fetchPage, onBatch: onBatch, replayInventory: replayInventory)
    }

    func pause() {
        invalidateTask()
        guard phase == .running, var saved = checkpoint else { return }
        saved.phase = .paused
        checkpoint = saved
        try? persist(saved)
        publish(saved)
    }

    private func invalidateTask() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func isCurrent(_ token: UInt64, _ accountID: String) -> Bool {
        generation == token && self.accountID == accountID
    }

    private func run(token: UInt64, accountID: String, fetchPage: @escaping FetchPage, onBatch: @escaping BatchHandler) async {
        do {
            if isCurrent(token, accountID), var saved = checkpoint, saved.pendingFolders.isEmpty {
                saved.phase = .completed
                saved.lastError = ""
                try persist(saved)
                checkpoint = saved
                publish(saved)
                task = nil
                return
            }
            while isCurrent(token, accountID), let folder = checkpoint?.pendingFolders.first {
                let page = try await fetch(folder, token: token, accountID: accountID, using: fetchPage)
                try Task.checkCancellation()
                guard isCurrent(token, accountID), var saved = checkpoint else { return }
                let signature = page.files.map { "\($0.isDir ? "d" : "f"):\($0.id)" }.joined(separator: ",")
                if folder.offset > 0, !page.files.isEmpty, signature == folder.previousPageSignature {
                    throw ScanError.invalidPage
                }
                if let next = page.nextOffset {
                    guard next > folder.offset, !page.files.isEmpty else { throw ScanError.invalidPage }
                    saved.pendingFolders[0].offset = next
                    saved.pendingFolders[0].previousPageSignature = signature
                } else {
                    saved.pendingFolders.removeFirst()
                    saved.completedFolders.append(folder.id)
                }
                var newVideos: [P115File] = []
                var newFolderIDs = Set<String>()
                var newVideoIDs = Set<String>()
                for file in page.files {
                    if file.isDir {
                        guard !file.id.isEmpty, file.id.allSatisfy(\.isNumber) else { throw ScanError.invalidFolder }
                        if !knownFolders.contains(file.id), newFolderIDs.insert(file.id).inserted {
                            saved.pendingFolders.append(Folder(id: file.id, name: file.name))
                        }
                    } else if file.isVideo {
                        let id = Self.videoID(file)
                        if !knownVideos.contains(id), newVideoIDs.insert(id).inserted { newVideos.append(file) }
                    }
                }
                // Store only the new inventory chunk; don't rewrite thousands of video records per page.
                if !newVideos.isEmpty {
                    let data = try JSONEncoder().encode(newVideos)
                    defaults.set(data, forKey: inventoryKey(saved, index: saved.inventoryChunks))
                    saved.inventoryChunks += 1
                    saved.videoCount += newVideos.count
                }
                saved.phase = saved.pendingFolders.isEmpty ? .completed : .running
                saved.lastError = ""
                try persist(saved)
                checkpoint = saved
                knownFolders.formUnion(newFolderIDs)
                knownVideos.formUnion(newVideoIDs)
                discoveredFiles.append(contentsOf: newVideos)
                publish(saved)
                // There is no suspension between the account check, checkpoint commit and callback.
                guard isCurrent(token, accountID) else { return }
                if !newVideos.isEmpty { onBatch(newVideos) }
                guard isCurrent(token, accountID) else { return }
                if saved.phase == .completed { task = nil; return }
            }
        } catch is CancellationError {
            // pause/selectAccount already committed the state; a stale task must not change it.
        } catch {
            guard isCurrent(token, accountID), var saved = checkpoint else { return }
            saved.phase = .failed
            let name = saved.pendingFolders.first?.name ?? "115 网盘"
            saved.lastError = "\(name)：\(error.localizedDescription)"
            checkpoint = saved
            try? persist(saved)
            publish(saved)
            task = nil
        }
    }

    private func fetch(_ folder: Folder, token: UInt64, accountID: String, using fetchPage: FetchPage) async throws -> Direct115FilePage {
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard isCurrent(token, accountID) else { throw CancellationError() }
            if let previousRequestAt {
                try await sleep(max(0, minimumRequestInterval - Date().timeIntervalSince(previousRequestAt)))
            }
            try Task.checkCancellation()
            guard isCurrent(token, accountID) else { throw CancellationError() }
            previousRequestAt = Date()
            do {
                return try await fetchPage(folder.id, folder.offset)
            } catch {
                if error is CancellationError { throw error }
                guard attempt + 1 < maximumAttempts, Self.isTransient(error) else { throw error }
                try await sleep(retryBaseDelay * pow(2, Double(attempt)))
            }
        }
        throw ScanError.invalidPage
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 60) * 1_000_000_000))
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let http = error as? Direct115HTTPError { return http.statusCode == 429 || (500...599).contains(http.statusCode) }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(code)
    }

    private static func videoID(_ file: P115File) -> String {
        file.id.isEmpty ? "pick:\(file.pickCode)|\(file.parentId)|\(file.name)" : "file:\(file.id)"
    }

    private func publish(_ saved: Checkpoint) {
        phase = saved.phase
        progress = Progress(scannedFolders: saved.completedFolders.count,
                            discoveredFolders: saved.completedFolders.count + saved.pendingFolders.count,
                            discoveredVideos: saved.videoCount)
        currentFolderName = saved.pendingFolders.first?.name ?? ""
        lastError = saved.lastError
    }

    private func checkpointKey(_ accountID: String) -> String {
        "\(storageKeyPrefix).\(Data(accountID.utf8).base64EncodedString()).checkpoint"
    }

    private func inventoryKey(_ saved: Checkpoint, index: Int) -> String {
        "\(checkpointKey(saved.accountID)).\(saved.scanID).inventory.\(index)"
    }

    private func persist(_ saved: Checkpoint) throws {
        defaults.set(try JSONEncoder().encode(saved), forKey: checkpointKey(saved.accountID))
    }

    private func removeInventory(_ saved: Checkpoint) {
        for index in 0..<saved.inventoryChunks { defaults.removeObject(forKey: inventoryKey(saved, index: index)) }
    }
}
