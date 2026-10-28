import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var path: [Crumb] = []
    @State private var playing: PlaybackSource?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("115 网盘")
                .navigationDestination(for: Crumb.self) { crumb in
                    DirectoryView(
                        cid: crumb.cid,
                        onOpenDir: { path.append($0) },
                        onPlay: { file in
                            playing = .p115(title: file.name, pickCode: file.pickCode)
                        }
                    )
                    .navigationTitle(crumb.name)
                }
        }
        .fullScreenCover(item: $playing) { source in
            PlayerView(source: source)
                .environmentObject(appState)
        }
        .task {
            if appState.isAuthenticated {
                await appState.checkAuth()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.hasServer {
            EmptyStateView(
                icon: "server.rack",
                title: "还没有连接服务器",
                message: "到「设置」里填写 HPlayer 后端地址，就能浏览 115 网盘了"
            )
        } else if !appState.isAuthenticated {
            EmptyStateView(
                icon: "lock",
                title: "需要登录",
                message: "到「设置」里输入访问密码"
            )
        } else {
            DirectoryView(
                cid: "0",
                onOpenDir: { path.append($0) },
                onPlay: { file in
                    playing = .p115(title: file.name, pickCode: file.pickCode)
                }
            )
        }
    }
}
