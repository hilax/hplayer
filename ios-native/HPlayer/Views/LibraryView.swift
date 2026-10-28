import SwiftUI

struct Crumb: Hashable {
    let cid: String
    let name: String
}

struct DirectoryView: View {
    let cid: String
    let onOpenDir: (Crumb) -> Void
    let onPlay: (P115File) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var files: [P115File] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                VStack(spacing: 12) {
                    Text(error)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load() }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                Text("这个目录是空的")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files) { file in
                    Button {
                        if file.isDir {
                            onOpenDir(Crumb(cid: file.id, name: file.name))
                        } else {
                            onPlay(file)
                        }
                    } label: {
                        row(for: file)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .task(id: cid) {
            await load()
        }
    }

    private func row(for file: P115File) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDir ? "folder.fill" : "play.rectangle.fill")
                .font(.title3)
                .foregroundColor(file.isDir ? .blue : .green)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                if !file.isDir {
                    Text(formatSize(file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let client = appState.client() else { return }
        loading = true
        error = ""
        do {
            let response: FileListResponse = try await client.get("/api/files?cid=\(cid)")
            files = response.files
                .filter { $0.isDir || $0.isVideo }
                .sorted { a, b in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
    }
}
