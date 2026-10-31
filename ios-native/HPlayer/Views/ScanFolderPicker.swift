import SwiftUI

/// 选择要扫描的 115 文件夹：逐层进入，在想扫描的文件夹点「扫描此文件夹」，只扫它和它的子文件夹。
struct ScanFolderPicker: View {
    let onSelect: (String, String) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = []

    var body: some View {
        NavigationStack(path: $path) {
            FolderList(cid: "0", name: "115 网盘", onOpen: { path.append($0) }, onSelect: choose)
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

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(cid, name)
                } label: {
                    Label(cid == "0" ? "扫描整个网盘" : "扫描此文件夹", systemImage: "sparkle.magnifyingglass")
                }
                .accessibilityIdentifier("scan.pickFolder")
            } footer: {
                Text(cid == "0" ? "整个网盘文件多时会比较久，建议只选存放影片的文件夹。" : "会扫描「\(name)」和它里面的所有子文件夹。")
            }
            Section("子文件夹") {
                if loading {
                    ProgressView()
                } else if !error.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                } else if folders.isEmpty {
                    Text("没有子文件夹").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    Button {
                        onOpen(Crumb(cid: folder.id, name: folder.name))
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Theme.accent)
                            Text(folder.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task { await load() }
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
