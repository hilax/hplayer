import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var incomingMagnet: IncomingMagnet?

    var body: some View {
        HomeView()
            .task {
                await appState.checkAuth()
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "magnet" else { return }
                incomingMagnet = IncomingMagnet(value: url.absoluteString)
            }
            .sheet(item: $incomingMagnet) { magnet in
                NavigationStack { MagnetPlayerView(initialMagnet: magnet.value) }
            }
    }
}

private struct IncomingMagnet: Identifiable {
    let id = UUID()
    let value: String
}
