import SwiftUI

struct MetadataSourcesView: View {
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @State private var showTMDB = false
    @State private var showDMM = false
    @State private var tmdbEnabled = !TMDBClient.storedKey.isEmpty
    @State private var dmmEnabled = DMMClient.storedCredentials() != nil

    var body: some View {
        Form {
            Section("影视资料") {
                LabeledContent("番组计划", value: "自动使用")
                LabeledContent("IMDb / Cinemeta", value: "自动使用")
                Button { showTMDB = true } label: {
                    LibraryActionRow(symbol: "key", title: "TMDB", value: tmdbEnabled ? "已开启" : "可选")
                }
                .buttonStyle(.plain)
            }
            Section {
                Toggle("按番号匹配成人影片", isOn: $adultMatching)
                    .accessibilityIdentifier("scan.adultMatching")
                if adultMatching {
                    Button { showDMM = true } label: {
                        LibraryActionRow(symbol: "key", title: "FANZA（DMM）官方接口", value: dmmEnabled ? "已开启" : "可选")
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("番号资料") } footer: {
                Text("默认关闭。开启后只发送识别出的番号，不发送 115 Cookie、路径或视频内容。关闭后已有资料仍会保留。")
            }
        }
        .libraryFormStyle()
        .navigationTitle("资料来源")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTMDB, onDismiss: { tmdbEnabled = !TMDBClient.storedKey.isEmpty }) { TMDBKeyView() }
        .sheet(isPresented: $showDMM, onDismiss: { dmmEnabled = DMMClient.storedCredentials() != nil }) { DMMKeyView() }
    }
}
