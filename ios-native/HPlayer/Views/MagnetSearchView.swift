import SwiftUI
import UIKit

/// 磁力在线搜索与聚合页面（默认基于 JavBus 实时检索）。
struct MagnetSearchView: View {
    var onSelectMagnet: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.javbus_host") private var customHost = ""
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true

    @State private var keyword = ""
    @State private var items: [MagnetSearchItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var detectedClipboardCode: String?
    @State private var selectedItem: MagnetSearchItem?
    @State private var showingSettingsSheet = false
    @State private var toastMessage: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchHeaderCard

                if let clipboardCode = detectedClipboardCode, !clipboardCode.isEmpty, keyword != clipboardCode {
                    clipboardHint(code: clipboardCode)
                }

                if isSearching {
                    loadingView
                } else if let error = searchError {
                    errorCard(message: error)
                } else if !items.isEmpty {
                    resultsSection
                } else if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyResultView
                } else {
                    initialGuideView
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("磁力聚合搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: AppIcon.settings.name)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            MagnetDetailSheet(item: item) { chosenMagnet in
                selectedItem = nil
                dismiss()
                onSelectMagnet(chosenMagnet)
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            JavBusHostSettingsSheet()
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: items)
        .animation(Motion.smooth, value: isSearching)
        .animation(Motion.smooth, value: toastMessage)
        .task {
            checkClipboard()
        }
    }

    // MARK: - 搜索输入卡片

    private var searchHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: AppIcon.search.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("输入番号（如 SSIS-888）或片名关键词", text: $keyword)
                    .font(.body)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { triggerSearch() }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        items = []
                        searchError = nil
                    } label: {
                        Image(systemName: AppIcon.clear.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("搜索") {
                    searchFocused = false
                    triggerSearch()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .surfaceCard(cornerRadius: 22)
    }

    // MARK: - 剪贴板快速提示

    private func clipboardHint(code: String) -> some View {
        Button {
            keyword = code
            triggerSearch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AppIcon.copy.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("识别到剪贴板番号: \(code)，点击快速搜索")
                    .font(.footnote.weight(.medium))
                Spacer()
                Image(systemName: AppIcon.forward.name)
                    .font(.system(size: 14))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 结果列表

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("检索结果 (\(items.count))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点击查看磁力资源")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    searchResultCard(item: item)
                        .onTapGesture {
                            selectedItem = item
                        }
                }
            }
        }
    }

    private func searchResultCard(item: MagnetSearchItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // 封面图片
            AsyncImage(url: item.coverURL) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Theme.surfaceRaised)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Rectangle()
                        .fill(Theme.surfaceRaised)
                        .overlay {
                            Image(systemName: AppIcon.poster.name)
                                .foregroundStyle(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 86, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let date = item.releaseDate {
                    HStack(spacing: 4) {
                        Image(systemName: AppIcon.clock.name)
                            .font(.system(size: 11))
                        Text(date)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                HStack {
                    Spacer()
                    Label("获取磁力", systemImage: AppIcon.download.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .surfaceCard(cornerRadius: 16)
    }

    // MARK: - 辅助状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Theme.accent)
            Text("正在实时检索 JavBus...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 36))
                .foregroundStyle(Color.orange)

            Text("检索未完成")
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("更换镜像域名") {
                    showingSettingsSheet = true
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)

                Button("重新尝试") {
                    triggerSearch()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .surfaceCard(cornerRadius: 20)
    }

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.search.name)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("未找到相关资源")
                .font(.headline)
            Text("建议尝试直接输入标准番号（如 SSIS-888）或更换镜像站后再试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var initialGuideView: some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.link.name)
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text("番号与磁力聚合检索")
                .font(.headline)
            Text("输入影片番号直接实时抓取 JavBus 详情与磁力列表。\n检索到的磁力可直接调用 115 云下载秒开播放。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(20)
    }

    // MARK: - 行为操作

    private func triggerSearch() {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        searchError = nil

        Task {
            do {
                let results = try await JavBusSource.shared.search(keyword: q)
                await MainActor.run {
                    self.items = results
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.searchError = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        if let extracted = AVCatalogCode.extract(clip) {
            detectedClipboardCode = extracted
        }
    }
}

// MARK: - 磁力详情 Sheet

struct MagnetDetailSheet: View {
    let item: MagnetSearchItem
    var onSelectMagnet: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @State private var magnets: [MagnetTorrentItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var copiedMagnetID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerCard

                Divider()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("正在拉取磁力链接列表...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorText {
                    VStack(spacing: 12) {
                        Image(systemName: AppIcon.alert.name)
                            .font(.system(size: 32))
                            .foregroundStyle(Color.orange)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新获取") { fetchMagnets() }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if magnets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: AppIcon.archive.name)
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("该影片暂无磁力链接")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    magnetListView
                }
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("磁力资源列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            fetchMagnets()
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.surfaceRaised)
                }
            }
            .frame(width: 58, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = item.releaseDate {
                    Text("发行日期: \(date)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.surface)
    }

    private var magnetListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(magnets) { torrent in
                    magnetRow(torrent: torrent)
                }
            }
            .padding(16)
        }
    }

    private func magnetRow(torrent: MagnetTorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if torrent.hasSubtitles {
                    Text("中文字幕")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                if torrent.isHD {
                    Text("1080P 高清")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Text(torrent.size)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                if let date = torrent.date {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }

            Text(torrent.name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 10) {
                // 115 云下载播放（推荐动作）
                Button {
                    onSelectMagnet(torrent.magnetURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: AppIcon.play.name)
                        Text(cloudRelay ? "115 云下载播放" : "磁力播放")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                // 复制链接
                Button {
                    UIPasteboard.general.string = torrent.magnetURL
                    copiedMagnetID = torrent.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedMagnetID == torrent.id { copiedMagnetID = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedMagnetID == torrent.id ? AppIcon.check.name : AppIcon.copy.name)
                        Text(copiedMagnetID == torrent.id ? "已复制" : "复制磁力")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Spacer()
            }
        }
        .padding(14)
        .surfaceCard(cornerRadius: 14)
    }

    private func fetchMagnets() {
        isLoading = true
        errorText = nil
        Task {
            do {
                let fetched = try await JavBusSource.shared.fetchMagnets(for: item)
                await MainActor.run {
                    self.magnets = fetched
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - 镜像域名设置弹窗

struct JavBusHostSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.javbus_host") private var customHost = ""
    @State private var inputHost = ""

    private let presets = [
        "https://www.javbus.com",
        "https://www.busdmm.work",
        "https://www.dmmsee.art"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("JavBus 访问域名"), footer: Text("当默认域名 javbus.com 受到网络屏蔽或 Cloudflare 防护拦截时，可切换为官方备用或镜像域名。")) {
                    TextField("https://www.javbus.com", text: $inputHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("常用预设域名") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            inputHost = preset
                        } label: {
                            HStack {
                                Text(preset)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if inputHost == preset {
                                    Image(systemName: AppIcon.check.name)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("恢复默认域名") {
                        inputHost = "https://www.javbus.com"
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("镜像域名配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        customHost = inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .onAppear {
                inputHost = customHost.isEmpty ? "https://www.javbus.com" : customHost
            }
        }
    }
}
