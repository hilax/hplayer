import SwiftUI

/// 文件扫描和封面匹配各自展示状态；文件扫描完成不代表所有影片都能识别。
struct HomeLibraryScanView: View {
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false

    let onStart: (Bool) -> Void
    let onStartFolder: (String, String) -> Void
    @State private var pickingFolder = false
    let onRetryMatching: () -> Void

    @State private var matchedVideos = 0

    private func refreshMatched() {
        // 只在匹配结果变化时数一次，不在每次扫描进度刷新时重算。
        matchedVideos = library.media(for: appState).filter { metadata.metadataByMediaID[$0.id]?.hasUsablePoster == true }.count
    }

    private var status: String {
        switch scanner.phase {
        case .idle: return "扫描你的 115 片库"
        case .running: return "正在扫描全盘"
        case .paused: return "扫描已暂停"
        case .failed: return "扫描尚未完成"
        case .completed: return "文件扫描完成"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: scanner.phase == .completed ? "checkmark.circle" : "sparkle.magnifyingglass")
                            .font(.system(size: 28)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(status).font(.headline)
                            Text(metadata.isMatching ? "正在自动匹配封面" : "仅展示匹配到封面的影片")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if scanner.phase == .running || metadata.isMatching { ProgressView() }
                    }.padding(.vertical, 8)
                    LabeledContent("扫描范围", value: scanner.scopeName ?? "整个网盘")
                    LabeledContent("已扫描文件夹", value: "\(scanner.progress.scannedFolders) / \(scanner.progress.discoveredFolders)")
                    LabeledContent("本次发现视频", value: "\(scanner.progress.discoveredVideos)")
                    LabeledContent("片库已匹配视频", value: "\(matchedVideos)")
                    if scanner.phase == .running, !scanner.currentFolderName.isEmpty {
                        LabeledContent("正在扫描", value: scanner.currentFolderName)
                    }
                } footer: {
                    Text("电影和剧集会自动归类。同一部剧合并成一张海报，没有匹配到的文件仍可在资源库播放。")
                }

                if !scanner.lastError.isEmpty {
                    Section {
                        Label(scanner.lastError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.warning)
                    } footer: {
                        Text("已发现的影片和扫描进度都已保留，可稍后继续。")
                    }
                }

                Section {
                    Toggle("按番号匹配成人影片", isOn: $adultMatching)
                        .accessibilityIdentifier("scan.adultMatching")
                } header: {
                    Text("资料来源")
                } footer: {
                    Text("开启后，文件名带番号的影片会优先用 R18.dev 匹配，查不到才去番组计划和 IMDb。只发送番号，不发送 115 Cookie、路径或视频内容。封面由第三方图片服务提供；关闭后已匹配的封面仍会保留。")
                }

                Section {
                    if scanner.phase == .running {
                        Button("暂停扫描", systemImage: "pause.circle") {
                            scanner.pause()
                            metadata.stopByUser()
                            library.flush()
                        }.accessibilityIdentifier("scan.pause")
                    } else if scanner.canResume {
                        Button("继续全盘扫描", systemImage: "play.circle") { onStart(false) }
                            .accessibilityIdentifier("scan.resume")
                        Button("从头重新扫描", systemImage: "arrow.clockwise") { onStart(true) }
                    } else {
                        Button(scanner.phase == .completed ? "重新扫描全盘" : "开始全盘扫描", systemImage: "sparkle.magnifyingglass") {
                            onStart(scanner.phase == .completed)
                        }.accessibilityIdentifier("scan.start")
                    }
                    if metadata.isMatching {
                        Button("停止匹配封面", systemImage: "stop.circle", role: .destructive) {
                            metadata.stopByUser()
                            library.flush()
                        }.accessibilityIdentifier("scan.stopMatching")
                    }
                    if scanner.phase != .running {
                        Button("选择文件夹扫描", systemImage: "folder.badge.gearshape") { pickingFolder = true }
                            .accessibilityIdentifier("scan.chooseFolder")
                    }
                    Button("重新匹配未识别封面", systemImage: "photo.badge.magnifyingglass", action: onRetryMatching)
                        .disabled(library.files(for: appState).isEmpty && local.files.isEmpty)
                    NavigationLink("管理未匹配影片") { HomeUnmatchedMediaView() }
                } footer: {
                    Text("扫描在前台进行，退出 App 后可从这里继续。只读取文件列表，不下载整部视频，也不删除网盘文件。")
                }
            }
            .task(id: metadata.metadataByMediaID.count) { refreshMatched() }
            .navigationTitle("115 全盘扫描")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $pickingFolder) {
            ScanFolderPicker(onSelect: onStartFolder).environmentObject(appState)
        }
    }
}

/// 未识别文件不占用首页，但仍可以从扫描页播放或手动校正封面。
private struct HomeUnmatchedMediaView: View {
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var appState: AppState
    @State private var matching: MatchRequest?
    @State private var playing: PlaybackQueue?

    private var items: [HomeMediaItem] {
        HomeLibrary.items(HomeLibrary.media(local: local, cloud: library, appState: appState), metadata: metadata.metadataByMediaID)
            .filter { $0.metadata?.hasUsablePoster != true }
    }

    var body: some View {
        List {
            if items.isEmpty {
                Text("当前没有待匹配影片").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button {
                    matching = MatchRequest(item: item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "film").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.media.name).foregroundStyle(.primary).lineLimit(2)
                            Text(item.sourceLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text("匹配").font(.subheadline).foregroundStyle(Theme.accent)
                    }.padding(.vertical, 4)
                }
                .contextMenu {
                    Button("播放", systemImage: "play.fill") {
                        playing = PlaybackQueue(source: item.media.source, items: [item.media.source])
                    }
                }
            }
        }
        .navigationTitle("未匹配影片")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $matching) { request in
            MetadataMatchView(file: request.file, current: request.current, onMatch: { result in
                await metadata.match(result, to: request.file)
            }, onClear: nil)
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
