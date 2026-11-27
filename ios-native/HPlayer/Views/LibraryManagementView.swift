import SwiftUI

/// Maintenance belongs to Resources. All operations use the existing shared stores.
struct LibraryManagementView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore

    /// 从「我的」、片库频道压进公共导航栈时为 true（系统返回键、从右侧推入）
    var pushed = false

    private var files: [LibraryMedia] { HomeLibrary.media(local: local, cloud: library, appState: appState) }

    var body: some View {
        HomeLibraryScanView(
            onStart: { restart in start(restart) },
            onStartFolders: { targets in start(true, roots: targets) },
            onRetryMatching: { metadata.retryFailed(files: files) },
            pushed: pushed
        )
    }

    private func start(_ restart: Bool, roots: [ScanFolderTarget] = []) {
        guard let accountID = appState.libraryAccountID, appState.isAuthenticated,
              let client = appState.directClient() else { return }
        metadata.resumeAutomatic()
        let library = self.library
        let local = self.local
        let metadata = self.metadata
        let appState = self.appState
        // 记下扫描时见到的文件夹，清理已失效文件时要靠它知道被删的文件夹原来在哪
        scanner.onFolders = { folders in
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            library.recordFolders(folders, for: appState)
        }
        scanner.onComplete = {
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            Task {
                await metadata.waitUntilRestored()
                guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
                let allFiles = HomeLibrary.media(local: local, cloud: library, appState: appState)
                await metadata.prewarmNames(allFiles.map(\.name), priority: .utility)
                guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
                metadata.enqueueScanned(allFiles, in: allFiles)
            }
        }
        scanner.start(
            accountID: accountID,
            roots: roots.map { (id: $0.id, name: $0.name) },
            fetchPage: { cid, offset in
                try await client.filesPage(cid: cid, offset: offset)
            },
            onBatch: { batch in
                guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
                library.add(batch, for: appState)
                guard !batch.isEmpty else { return }
                let newlyScanned = batch.filter { $0.isVideo && !$0.isDir && !$0.pickCode.isEmpty }.map(LibraryMedia.init(cloud:))
                guard !newlyScanned.isEmpty else { return }
                Task {
                    await metadata.waitUntilRestored()
                    guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
                    await metadata.prewarmNames(newlyScanned.map(\.name), priority: .utility)
                    guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
                    let allFiles = HomeLibrary.media(local: local, cloud: library, appState: appState)
                    metadata.enqueueScanned(newlyScanned, in: allFiles)
                }
            },
            restart: restart,
            replayInventory: false
        )
    }
}
