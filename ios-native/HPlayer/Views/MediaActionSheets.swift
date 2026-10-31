import SwiftUI

enum AddMediaAction { case local, cloud, magnet }

struct AddMediaSheet: View {
    let onSelect: (AddMediaAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PageIntroduction(eyebrow: "Build your collection", title: "添加影片")
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).glassCircle() }
                    .accessibilityLabel("关闭")
            }
            DesignGroup {
                action(.local, "folder", "导入本机视频", "从系统「文件」选择视频")
                Divider().padding(.leading, 62)
                action(.cloud, "icloud", "添加 115 文件夹", "浏览目录，加入你的首页")
                Divider().padding(.leading, 62)
                action(.magnet, "link", "打开磁力链接", "使用 115 或本机引擎解析")
            }
            Text("添加后的影片会整理到你的片库。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.contentInset).padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("add")
    }

    private func action(_ action: AddMediaAction, _ symbol: String, _ title: String, _ subtitle: String) -> some View {
        Button { onSelect(action) } label: { LibraryActionRow(symbol: symbol, title: title, subtitle: subtitle) }
            .buttonStyle(.plain)
    }
}

struct MediaActionSheet: View {
    let item: HomeMediaItem
    var position: Double?
    let onPlay: () -> Void
    let onMatch: () -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        DesignPage(eyebrow: "Movie actions", title: "影片选项") {
            HStack(spacing: 18) {
                PosterArtwork(urlString: item.posterURL, title: item.title, width: 82)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.title3.bold())
                    Text([item.year, item.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DesignGroup {
                Button(action: onPlay) {
                    LibraryActionRow(symbol: "play.fill", title: position == nil ? "播放" : "继续播放",
                                     subtitle: position.map { "从 \(playbackTimeText($0)) 继续" } ?? "开始观看这部影片")
                }.buttonStyle(.plain)
                Divider().padding(.leading, 62)
                Button(action: onMatch) {
                    LibraryActionRow(symbol: "photo", title: "匹配封面", subtitle: "选择或更正影片资料")
                }.buttonStyle(.plain)
                Divider().padding(.leading, 62)
                Button { confirmRemove = true } label: {
                    LibraryActionRow(symbol: "trash", title: item.isCloud ? "从首页移除" : "删除本机文件",
                                     subtitle: item.isCloud ? "保留网盘中的原始文件" : "删除导入到 HPlayer 的副本")
                }.buttonStyle(.plain)
            }
        }
        .designScreen("film-menu")
        .confirmationDialog(item.isCloud ? "从首页移除这部影片？" : "删除这个本机文件？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(item.isCloud ? "移除" : "删除", role: .destructive, action: onRemove)
        }
    }
}

struct PerformerCollageCard: View {
    let group: PerformerGroup
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(group.collectionItems.prefix(2))) { item in
                    ArtworkView(urlString: item.posterURL, title: item.title)
                        .scaledToFill().frame(width: (width - 2) / 2, height: width * 0.62)
                        .clipped().allowsHitTesting(false)
                }
            }
            .frame(width: width, height: width * 0.62)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Text("\(group.collectionItems.count) 部作品").font(.caption).foregroundStyle(.secondary)
        }.frame(width: width, alignment: .leading).contentShape(Rectangle())
    }
}

struct PerformerGridView: View {
    let groups: [PerformerGroup]
    var body: some View {
        GeometryReader { proxy in
            let count = max(2, Int(proxy.size.width / 230))
            let width = floor((proxy.size.width - Theme.contentInset * 2 - CGFloat(count - 1) * 14) / CGFloat(count))
            DesignPage(eyebrow: "Collections", title: "演员合集", subtitle: "从你的片库里，重遇熟悉的面孔。") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 14), count: count), spacing: 24) {
                    ForEach(groups) { group in
                        PerformerNavigationLink(group: group) { PerformerCollageCard(group: group, width: width) }
                            .buttonStyle(PosterButtonStyle())
                    }
                }
            }
        }.navigationTitle("演员合集").designScreen("people")
    }
}
