import SwiftUI

/// 选择要扫描的 115 文件夹：逐层进入，在想扫描的文件夹点「扫描此文件夹」，只扫它和它的子文件夹。
struct ScanFolderPicker: View {
    let onSelect: (String, String) -> Void
    var initialFolders: [P115File]? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = []

    var body: some View {
        NavigationStack(path: $path) {
            FolderList(cid: "0", name: "115 网盘", onOpen: { path.append($0) }, onSelect: choose, initialFolders: initialFolders)
                .libraryFormStyle()
                .navigationTitle("选择要扫描的文件夹")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Crumb.self) { crumb in
                    FolderList(cid: crumb.cid, name: crumb.name, onOpen: { path.append($0) }, onSelect: choose)
                        .libraryFormStyle()
                        .navigationTitle(crumb.name)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func choose(_ cid: String, _ name: String) {
        onSelect(cid, name)
        dismiss()
    }
}

private struct FolderList: View {
    let cid: String
    let name: String
    let onOpen: (Crumb) -> Void
    let onSelect: (String, String) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var folders: [P115File] = []
    @State private var loading = true
    @State private var error = ""

    init(cid: String, name: String, onOpen: @escaping (Crumb) -> Void, onSelect: @escaping (String, String) -> Void, initialFolders: [P115File]? = nil) {
        self.cid = cid; self.name = name; self.onOpen = onOpen; self.onSelect = onSelect
        _folders = State(initialValue: initialFolders ?? [])
        _loading = State(initialValue: initialFolders == nil)
    }

    var body: some View {
        DesignPage(eyebrow: "Choose a folder", title: "选择扫描目录", subtitle: "只整理需要的文件夹，保留目录中的原文件。") {
            HStack(spacing: 8) {
                Image(systemName: "icloud").foregroundStyle(Theme.accent)
                Text(name).font(.subheadline.weight(.medium))
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).surfaceCard()
            GroupLabel(title: "子文件夹")
            DesignGroup {
                if loading { ProgressView().frame(maxWidth: .infinity).padding(32) }
                else if !error.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    }.padding(20)
                } else if folders.isEmpty {
                    Text("没有子文件夹").font(.subheadline).foregroundStyle(.secondary).padding(24)
                }
                ForEach(folders) { folder in
                    Button { onOpen(Crumb(cid: folder.id, name: folder.name)) } label: {
                        LibraryActionRow(symbol: "folder", title: folder.name, subtitle: "进入文件夹")
                    }.buttonStyle(.plain)
                    if folder.id != folders.last?.id { Divider().padding(.leading, 62) }
                }
            }
            DesignNotice(text: cid == "0" ? "整个网盘文件较多时耗时较长，建议只选择存放影片的文件夹。" : "会扫描「\(name)」及其中的所有子文件夹。")
        }
        .safeAreaInset(edge: .bottom) {
            Button { onSelect(cid, name) } label: {
                Label(cid == "0" ? "扫描整个网盘" : "扫描此文件夹", systemImage: "viewfinder")
            }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("scan.pickFolder")
                .padding(Theme.contentInset).background(Theme.pageBackground)
        }
        .designScreen("folder-picker")
        .task { if !InterfacePreview.active { await load() } }
    }

    private func load() async {
        guard let client = appState.directClient() else { loading = false; error = "请先登录 115"; return }
        var offset = 0
        var result: [P115File] = []
        do {
            for _ in 0..<20 {
                let page = try await client.filesPage(cid: cid, offset: offset)
                result += page.files.filter { $0.isDir && !$0.id.isEmpty }
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            folders = result
        } catch is CancellationError {
        } catch {
            self.error = "读取文件夹失败：\(error.localizedDescription)"
        }
        loading = false
    }
}
