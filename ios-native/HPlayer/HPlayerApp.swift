import SwiftUI

@main
struct HPlayerApp: App {
    @UIApplicationDelegateAdaptor(HPlayerAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let value = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"], let url = URL(string: value) {
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
            .preferredColorScheme(.dark)
        }
    }
}

#if DEBUG
private struct PlayerUITestHost: View {
    let first: PlaybackSource
    let second: PlaybackSource
    @State private var presentingPlayer = false

    var body: some View {
        Color.black
            .ignoresSafeArea()
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
