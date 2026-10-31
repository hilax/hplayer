import SwiftUI

struct MetadataSourcesView: View {
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @State private var credentials = false
    @State private var tmdbEnabled = !TMDBClient.storedKey.isEmpty
    @State private var dmmEnabled = DMMClient.storedCredentials() != nil

    var body: some View {
        DesignPage(eyebrow: "Metadata sources", title: "资料来源", subtitle: "让每部影片，都有自己的名字。") {
            GroupLabel(title: "影视资料")
            DesignGroup {
                LibraryActionRow(symbol: "sparkles", title: "番组计划", subtitle: "动画与亚洲影视资料", value: "自动使用")
                Divider().padding(.leading, 62)
                LibraryActionRow(symbol: "film", title: "IMDb / Cinemeta", subtitle: "电影与剧集资料", value: "自动使用")
                Divider().padding(.leading, 62)
                Button { credentials = true } label: {
                    LibraryActionRow(symbol: "key", title: "TMDB", subtitle: "可选的中文海报与影片资料", value: tmdbEnabled ? "已开启" : "未配置")
                }.buttonStyle(.plain)
            }
            GroupLabel(title: "番号资料")
            VStack(alignment: .leading, spacing: 16) {
                Toggle("按番号匹配成人影片", isOn: $adultMatching)
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("scan.adultMatching")
                DesignNotice(symbol: "lock.shield", text: "默认关闭。只发送识别出的番号，不发送 115 Cookie、文件路径或视频内容。")
                if adultMatching {
                    Divider()
                    Button { credentials = true } label: {
                        LibraryActionRow(symbol: "key", title: "FANZA（DMM）", value: dmmEnabled ? "已开启" : "可选")
                    }.buttonStyle(.plain)
                }
            }.padding(18).surfaceCard()
            Button { credentials = true } label: { Label("管理接口凭证", systemImage: "key") }
                .buttonStyle(SecondaryActionStyle())
            DesignNotice(text: "关闭资料来源不会删除已经匹配的封面与资料。")
        }
        .navigationTitle("资料来源")
        .designScreen("metadata")
        .sheet(isPresented: $credentials, onDismiss: {
            tmdbEnabled = !TMDBClient.storedKey.isEmpty
            dmmEnabled = DMMClient.storedCredentials() != nil
        }) { NavigationStack { MetadataCredentialsView() } }
    }
}
