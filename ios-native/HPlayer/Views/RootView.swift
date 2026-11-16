import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var incomingMagnet: MagnetPlaybackRequest?
    @ObservedObject private var magnetRelay = MagnetRelayCenter.shared

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
            // 全局提示上点了「去播放」：后台准备好的磁力资源从这里打开
            .onChange(of: magnetRelay.openRequest?.id) { _ in
                guard let request = magnetRelay.openRequest else { return }
                magnetRelay.openRequest = nil
                incomingMagnet = request
            }
            // 从别的 App 打开的磁力链接：直接进播放窗口，解析进度显示在窗口里
            .magnetPlayer(item: $incomingMagnet)
    }
}
