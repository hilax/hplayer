import SwiftUI

@main
struct HPlayerApp: App {
    @UIApplicationDelegateAdaptor(HPlayerAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let style = ProcessInfo.processInfo.environment["HPLAYER_SCAN_TEST_STYLE"] {
                    ScanUITestHost()
                        .preferredColorScheme(style == "dark" ? .dark : .light)
                } else if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                    HomeUITestHost()
                } else if let value = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"], let url = URL(string: value) {
                    let first = PlaybackSource.direct(title: "测试影片", url: url)
                    let second = PlaybackSource.direct(title: "测试下一集", url: url)
                    PlayerUITestHost(first: first, second: second)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environmentObject(appState)
            .onAppear { AppearanceController.apply(appearance) }
            .onChange(of: appearance) { mode in AppearanceController.apply(mode) }
        }
    }
}

#if DEBUG
/// A real, idle scanner and empty stores let UI tests exercise the scan page
/// without a 115 session or any network requests.
private struct ScanUITestHost: View {
    @StateObject private var scanner = CloudLibraryScanner()
    @StateObject private var metadata = MediaMetadataStore()
    @StateObject private var library = MediaLibraryStore()
    @StateObject private var local = LocalMediaStore()

    var body: some View {
        HomeLibraryScanView(onStart: { _ in }, onStartFolder: { _, _ in }, onRetryMatching: {})
            .environmentObject(scanner)
            .environmentObject(metadata)
            .environmentObject(library)
            .environmentObject(local)
    }
}

private struct HomeUITestHost: View {
    @EnvironmentObject private var appState: AppState
    @State private var ready = false

    var body: some View {
        Group {
            if ready { HomeView(appState: appState) }
            else { ProgressView() }
        }.task {
            let store = LocalMediaStore()
            for name in ["The.Demon.Hunter.S01E71.2026.mkv", "Arrival.2016.mp4", "Dune.2021.mp4",
                         "仙逆.Renegade.Immortal.S01E05.2023.1080p.WEB-DL.mp4"] {
                let url = store.mediaDirectory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) { try? Data(name.utf8).write(to: url) }
            }
            ready = true
        }
    }
}

private struct PlayerUITestHost: View {
    let first: PlaybackSource
    let second: PlaybackSource
    @State private var presentingPlayer = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Button("重新播放测试视频") { presentingPlayer = true }
                .accessibilityIdentifier("playbackTest.reopen")
        }
            .task {
                await Task.yield()
                presentingPlayer = true
            }
            .fullScreenCover(isPresented: $presentingPlayer) {
                PlayerView(source: first, playlist: [first, second])
            }
    }
}
#endif
