import SwiftUI

@main
struct HPlayerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let value = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"], let url = URL(string: value) {
                    let first = PlaybackSource.direct(title: "测试影片", url: url)
                    let second = PlaybackSource.direct(title: "测试下一集", url: url)
                    PlayerView(source: first, playlist: [first, second])
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
