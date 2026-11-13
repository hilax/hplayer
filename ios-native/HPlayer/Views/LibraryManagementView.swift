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
        HomeLibraryScanView(onStart: { start($0) }, onStartFolder: { start(true, root: ($0, $1)) },
                            onRetryMatching: { metadata.retryFailed(files: files) }, pushed: pushed)
    }

    private func start(_ restart: Bool, root: (id: String, name: String)? = nil) {
        guard let accountID = appState.libraryAccountID, appState.isAuthenticated,
              let client = appState.directClient() else { return }
        metadata.resumeAutomatic()
        // 记下扫描时见到的文件夹，清理已失效文件时要靠它知道被删的文件夹原来在哪
        scanner.onFolders = { folders in
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            library.recordFolders(folders, for: appState)
        }
        scanner.start(accountID: accountID, root: root, fetchPage: { cid, offset in
            try await client.filesPage(cid: cid, offset: offset)
        }, onBatch: { batch in
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            library.add(batch, for: appState)
        }, restart: restart, replayInventory: false)
    }
}
