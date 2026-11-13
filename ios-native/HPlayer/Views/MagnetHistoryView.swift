import SwiftUI

/// 磁力「播放记录」：在磁力页右上角打开。以前在「传输中心 › 边下边播」里，传输中心拆掉后放到磁力页自己身上。
/// 点一条直接续播（引擎读本机保存的种子信息，不用重新解析），左滑删除，右上角可清空。
struct MagnetHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var history = MagnetHistoryStore.shared

    @State private var playLaunch: MagnetLaunch?
    @State private var confirmClear = false

    var body: some View {
        Group {
            if history.items.isEmpty {
                EmptyStateView(
                    icon: AppIcon.history.name,
                    title: "还没有播放过磁力资源",
                    message: "在磁力页播放过的资源会记在这里，下次点一下就从上次的位置接着看。"
                )
            } else {
                List {
                    ForEach(history.items) { item in
                        Button {
                            playLaunch = MagnetLaunch(value: item.magnet)
                        } label: {
                            MagnetHistoryRow(item: item)
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: Theme.contentInset, bottom: 6, trailing: Theme.contentInset))
                        .accessibilityIdentifier("magnet.history.\(item.infoHash)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                remove(item)
                            } label: {
                                Label("删除", systemImage: AppIcon.trash.name)
                            }
                        }
                        .contextMenu {
                            Button {
                                playLaunch = MagnetLaunch(value: item.magnet)
                            } label: {
                                Label(item.lastProgress == nil ? "播放" : "续播", systemImage: AppIcon.play.name)
                            }
                            Button {
                                UIPasteboard.general.string = item.magnet
                            } label: {
                                Label("复制磁力链接", systemImage: AppIcon.copy.name)
                            }
                            Button(role: .destructive) {
                                remove(item)
                            } label: {
                                Label("删除记录", systemImage: AppIcon.trash.name)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("播放记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !history.items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("清空") { confirmClear = true }
                        .accessibilityIdentifier("magnet.history.clear")
                }
            }
        }
        .confirmationDialog("清空全部磁力播放记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) {
                for item in history.items {
                    PlaybackFrameStore.shared.remove(PlaybackFrameStore.key(forMagnet: item.infoHash))
                }
                history.removeAll()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只删除记录和观看进度，不影响 115 网盘里的文件。")
        }
        .sheet(item: $playLaunch) { launch in
            NavigationStack { MagnetPlayerView(initialMagnet: launch.value, closesAfterPlayback: true) }
                .environmentObject(appState)
        }
        .designScreen("magnet-history")
    }

    private func remove(_ item: MagnetHistoryItem) {
        PlaybackFrameStore.shared.remove(PlaybackFrameStore.key(forMagnet: item.infoHash))
        history.remove(item.infoHash)
    }
}

/// 一条记录：上次停下时的画面（没有就用图标），名称，看到哪一集、大小、时间，以及进度条。
private struct MagnetHistoryRow: View {
    let item: MagnetHistoryItem

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            thumbnail
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(item.name)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottom) {
            if let frame = PlaybackFrameStore.shared.image(for: PlaybackFrameStore.key(forMagnet: item.infoHash)) {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.surfaceRaised
                Image(systemName: AppIcon.magnet.name)
                    .font(.scaled(18, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let fraction = item.lastProgress?.fraction, fraction > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.scrim)
                        Rectangle().fill(Theme.accentFill).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
        .coverEdge()
        .accessibilityHidden(true)
    }

    private var detail: String {
        var parts: [String] = []
        if let title = item.lastFileTitle, item.videoCount > 1 { parts.append("看到：\(title)") }
        let size = formatSize(Int(clamping: item.totalSize))
        if !size.isEmpty { parts.append(size) }
        parts.append(item.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
