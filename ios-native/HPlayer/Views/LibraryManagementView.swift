import SwiftUI

/// Maintenance belongs to Resources. All operations use the existing shared stores.
struct LibraryManagementView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore

    private var files: [LibraryMedia] { HomeLibrary.media(local: local, cloud: library, appState: appState) }

    var body: some View {
        HomeLibraryScanView(onStart: { start($0) }, onStartFolder: { start(true, root: ($0, $1)) },
                            onRetryMatching: { metadata.retryFailed(files: files) })
    }

    private func start(_ restart: Bool, root: (id: String, name: String)? = nil) {
        guard let accountID = appState.libraryAccountID, appState.isAuthenticated,
              let client = appState.directClient() else { return }
        metadata.resumeAutomatic()
        scanner.start(accountID: accountID, root: root, fetchPage: { cid, offset in
            try await client.filesPage(cid: cid, offset: offset)
        }, onBatch: { batch in
            guard appState.isAuthenticated, appState.libraryAccountID == accountID else { return }
            library.add(batch, for: appState)
        }, restart: restart, replayInventory: false)
    }
}
