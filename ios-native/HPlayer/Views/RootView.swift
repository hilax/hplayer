import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var incomingMagnet: MagnetPlaybackRequest?

    var body: some View {
        HomeView(appState: appState)
            .task {
                PlayerWarmup.prepare()
                await appState.checkAuth()
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "magnet" else { return }
                incomingMagnet = MagnetPlaybackRequest(magnet: url.absoluteString)
            }
            // 从别的 App 打开的磁力链接：直接进播放窗口，解析进度显示在窗口里
            .magnetPlayer(item: $incomingMagnet)
    }
}
