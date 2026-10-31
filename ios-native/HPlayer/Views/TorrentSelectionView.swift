import SwiftUI

struct TorrentSelectionView: View {
    private enum Field: Hashable { case path, folder }
    @FocusState private var focusedField: Field?
    let info: TorrentInfo
    @Binding var selected: Set<Int>
    @Binding var savePath: String
    @Binding var folderId: String
    var busy: Bool
    var error: String
    let onSubmit: () -> Void

    private var selectedSize: Int { info.files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.size } }
    private var canSubmit: Bool { !busy && !selected.isEmpty && !savePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        DesignPage(eyebrow: "Choose what to save", title: "选择下载文件", subtitle: "只保存你需要的内容。") {
            HStack(spacing: 14) {
                Image(systemName: "doc.zipper").font(.largeTitle).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.name.isEmpty ? "BT 种子" : info.name).font(.headline).lineLimit(2)
                    Text("\(info.files.count) 个文件 · \(formatSize(info.size))").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
            HStack {
                Text("种子内容").font(.headline)
                Spacer()
                Button(selected.count == info.files.count ? "全不选" : "全选") {
                    selected = selected.count == info.files.count ? [] : Set(info.files.map(\.index))
                }.font(.subheadline)
            }
            DesignGroup {
                ForEach(info.files) { file in
                    Button { if selected.contains(file.index) { selected.remove(file.index) } else { selected.insert(file.index) } } label: {
                        HStack(spacing: 13) {
                            Image(systemName: selected.contains(file.index) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(selected.contains(file.index) ? Theme.accent : Color.secondary)
                            Image(systemName: "doc.video").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(file.path).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                                Text(formatSize(file.size)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("torrent.file.\(file.index)")
                    .accessibilityAddTraits(selected.contains(file.index) ? .isSelected : [])
                    if file.index != info.files.last?.index { Divider().padding(.leading, 52) }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Label("保存位置", systemImage: "folder").font(.headline)
                DesignField(label: "相对于目标文件夹的路径", placeholder: "HPlayer", text: $savePath)
                    .focused($focusedField, equals: .path).submitLabel(.done).onSubmit { focusedField = nil }
                DesignField(label: "目标文件夹 ID（根目录为 0）", placeholder: "0", text: $folderId).keyboardType(.numberPad).focused($focusedField, equals: .folder)
            }.padding(18).surfaceCard()
            if !error.isEmpty { DesignNotice(symbol: "exclamationmark.circle", text: error, warning: true) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack {
                    Text("已选 \(selected.count) 个文件"); Spacer(); Text(formatSize(selectedSize))
                }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("torrent.selectionSummary")
                Button(action: onSubmit) { Label(busy ? "正在创建任务…" : "创建云下载任务", systemImage: "icloud.and.arrow.down") }
                    .buttonStyle(PrimaryActionStyle()).disabled(!canSubmit)
            }.padding(Theme.contentInset).background(Theme.pageBackground)
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } } }
        .navigationTitle("选择下载文件")
        .designScreen("torrent-files")
    }
}
