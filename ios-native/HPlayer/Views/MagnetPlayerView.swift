import SwiftUI
import UIKit

struct MagnetPlayerView: View {
    var initialMagnet = ""

    @EnvironmentObject private var appState: AppState
    @StateObject private var controller = MagnetController()
    @ObservedObject private var history = MagnetHistoryStore.shared
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @State private var input = ""
    @State private var inputHint = ""
    @State private var showExtras = false
    @State private var showOthers = false
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var detected: MagnetLink? { MagnetLink.parse(input) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                inputCard

                switch controller.phase {
                case .idle:
                    EmptyView()
                case .resolving:
                    resolvingCard
                case .failed:
                    failureCard
                case .ready:
                    if let catalog = controller.catalog {
                        catalogSection(catalog)
                    }
                }

                if controller.phase == .idle || controller.phase == .failed {
                    historySection
                }

                tips
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .animation(.easeOut(duration: 0.2), value: controller.phase)
            .fullScreenCover(item: $controller.cloudQueue) { queue in
                PlayerView(source: queue.source, playlist: queue.items)
                    .environmentObject(appState)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("磁力在线播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { inputFocused = false }
            }
            if !initialMagnet.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            controller.activate()
            configureCloud()
            guard input.isEmpty, !initialMagnet.isEmpty else { return }
            input = initialMagnet
            submit()
        }
        .onChange(of: cloudRelay) { _ in configureCloud() }
        .onChange(of: appState.isAuthenticated) { _ in configureCloud() }
        .onDisappear {
            if !controller.playerVisible && controller.cloudQueue == nil { controller.deactivate() }
        }
        .fullScreenCover(isPresented: $controller.playerVisible) {
            MagnetWatchView(controller: controller)
        }
    }

    // MARK: 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("粘贴磁力链接、信息哈希，或包含链接的整段文字", text: $input, axis: .vertical)
                .font(.subheadline)
                .lineLimit(3...6)
                .focused($inputFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onChange(of: input) { _ in inputHint = "" }

            recognitionLine

            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    DispatchQueue.main.async { pasted(text) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Theme.accent)

                if !input.isEmpty {
                    Button("清空") {
                        input = ""
                        inputHint = ""
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: submit) {
                    capsuleLabel("解析", systemImage: "bolt.fill", prominent: true)
                }
                .buttonStyle(.plain)
                .disabled(detected == nil)
                .opacity(detected == nil ? 0.45 : 1)
                .accessibilityIdentifier("magnet.resolve")
            }

            if cloudAvailable {
                Toggle(isOn: $cloudRelay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同时交给 115 离线下载")
                            .font(.subheadline.weight(.medium))
                        Text("热门资源 115 几秒就能离线完成，直接用 115 播放；会占用离线额度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
            }
        }
        .padding(16)
        .surfaceCard(cornerRadius: 22)
    }

    private var cloudAvailable: Bool {
        appState.isDirect && appState.isAuthenticated
    }

    private func configureCloud() {
        controller.configureCloud(client: appState.directClient(), enabled: cloudRelay)
    }

    @ViewBuilder
    private var recognitionLine: some View {
        if let link = detected {
            Label {
                Text(link.displayName.map { "已识别：\($0)" } ?? "已识别信息哈希 \(link.shortHash)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        } else if !inputHint.isEmpty {
            Label(inputHint, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("没有识别到磁力链接", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pasted(_ text: String) {
        input = text
        if MagnetLink.parse(text) != nil {
            submit()
        } else {
            inputHint = "剪贴板里没有识别到磁力链接"
        }
    }

    private func submit() {
        inputFocused = false
        if controller.start(input) {
            inputHint = ""
            showExtras = false
            showOthers = false
        } else {
            inputHint = "没有识别到磁力链接。支持 magnet 链接、40 位哈希，或夹在文字里的链接。"
        }
    }

    // MARK: 解析中

    private var resolvingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.link?.displayName ?? "正在解析磁力链接")
                        .font(.headline)
                        .lineLimit(2)
                    Text("已用 \(controller.elapsed) 秒 · \(controller.link?.shortHash ?? "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(.engine, title: "启动 BT 引擎", detail: nil)
                stepRow(.peers, title: "寻找节点", detail: peersDetail)
                stepRow(.metadata, title: "获取文件列表", detail: "从 \(controller.swarm.connected) 个节点获取")
            }

            if controller.cloud != .off {
                cloudRow
            }

            if controller.elapsed >= 25 {
                Text("冷门资源找节点会久一些，可以继续等待；超过两分半会提示你。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                controller.reset()
            } label: {
                Text("取消")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .surfaceCard(cornerRadius: 22)
    }

    private var peersDetail: String {
        let swarm = controller.swarm
        if swarm.connected > 0 { return "已连接 \(swarm.connected) 个" }
        if swarm.connecting > 0 { return "正在连接 \(swarm.connecting) 个" }
        return "搜索中"
    }

    private func stepRow(_ step: MagnetController.ResolveStep, title: String, detail: String?) -> some View {
        let current = controller.step
        let done = current > step
        let active = current == step
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Theme.success : (active ? Theme.accent : Theme.track))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if active {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
            }
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(done || active ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            if active, let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 115 离线

    private var cloudRow: some View {
        HStack(spacing: 10) {
            Image(systemName: cloudIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(cloudTint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.cloudStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let percent) = controller.cloud, percent > 0, percent < 100 {
                    ProgressView(value: percent, total: 100)
                        .tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            if controller.cloud == .submitting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var cloudIcon: String {
        switch controller.cloud {
        case .ready: return "checkmark.icloud.fill"
        case .failed: return "exclamationmark.icloud"
        default: return "icloud.and.arrow.down"
        }
    }

    private var cloudTint: Color {
        switch controller.cloud {
        case .ready: return Theme.success
        case .failed: return Theme.warning
        default: return Theme.accent
        }
    }

    /// 正在用 BT 播放时 115 离线完成了，提示可以切过去
    private var cloudSwitchBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("115 离线已完成")
                    .font(.subheadline.weight(.semibold))
                Text("改用 115 播放，不用等节点，拖动也更流畅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                controller.useCloudCatalog()
            } label: {
                Text("改用 115")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .surfaceCard(cornerRadius: 18)
    }

    // MARK: 解析失败

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("解析没有完成")
                        .font(.headline)
                    Text(controller.error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if controller.cloud != .off {
                cloudRow
            }
            HStack(spacing: 10) {
                Button {
                    controller.retry()
                } label: {
                    capsuleLabel("重试", systemImage: "arrow.clockwise", prominent: true)
                }
                .buttonStyle(.plain)
                Button {
                    controller.reset()
                    input = ""
                } label: {
                    capsuleLabel("换一个链接", systemImage: "xmark", prominent: false)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .surfaceCard(cornerRadius: 22)
    }

    // MARK: 文件列表

    @ViewBuilder
    private func catalogSection(_ catalog: MagnetCatalog) -> some View {
        torrentHeader(catalog)

        if catalog.source == .bt, controller.cloudCatalog != nil {
            cloudSwitchBanner
        } else if catalog.source == .bt, controller.cloud != .off, controller.cloud != .ready {
            cloudRow
                .padding(14)
                .surfaceCard(cornerRadius: 18)
        }

        if catalog.main.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("没有可以播放的视频")
                    .font(.headline)
                Text(catalog.hasArchivesOnly
                     ? "这个资源里只有压缩包等文件，没法在线播放。"
                     : "这个资源里没有常见格式的视频文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .surfaceCard(cornerRadius: 22)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                GroupLabel(title: catalog.main.count > 1 ? "正片 · \(catalog.main.count) 个" : "正片")
                VStack(spacing: 0) {
                    ForEach(Array(catalog.main.enumerated()), id: \.element.id) { offset, file in
                        if catalog.hasFolders, offset == 0 || catalog.main[offset - 1].folder != file.folder {
                            folderHeader(file.folder)
                        }
                        fileRow(file, number: catalog.main.count > 1 ? offset + 1 : nil, showsEpisode: catalog.main.count > 1)
                    }
                }
                .padding(.vertical, 6)
                .surfaceCard(cornerRadius: 20)
            }
        }

        if !catalog.extras.isEmpty {
            collapsibleGroup(title: "其他视频（样片、广告等）· \(catalog.extras.count)", expanded: $showExtras) {
                ForEach(catalog.extras) { file in
                    fileRow(file, number: nil, showsEpisode: false)
                }
            }
        }

        if !catalog.others.isEmpty {
            collapsibleGroup(title: "其他文件 · \(catalog.others.count)", expanded: $showOthers) {
                ForEach(catalog.others) { file in
                    otherRow(file)
                }
            }
        }
    }

    private func torrentHeader(_ catalog: MagnetCatalog) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: "link", colors: [Theme.brandCyan, Theme.brandBlue], size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(catalog.name)
                        .font(.headline)
                        .lineLimit(3)
                    Text(headerDetail(catalog))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button {
                        if let uri = controller.link?.uri {
                            UIPasteboard.general.string = uri
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    } label: {
                        Label("复制磁力链接", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        controller.reset()
                        input = ""
                    } label: {
                        Label("关闭这个资源", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("更多")
            }

            if let primary = primaryAction(catalog) {
                Button {
                    controller.play(primary.file)
                } label: {
                    Label(primary.title, systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accentGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .surfaceCard(cornerRadius: 22)
    }

    private func headerDetail(_ catalog: MagnetCatalog) -> String {
        var parts: [String] = [catalog.source == .cloud ? "115 离线" : "BT 边下边播"]
        let size = formatSize(Int(clamping: catalog.totalSize))
        if !size.isEmpty { parts.append(size) }
        if catalog.source == .bt { parts.append("\(catalog.fileCount) 个文件") }
        if catalog.main.count > 1 { parts.append("\(catalog.main.count) 个正片") }
        return parts.joined(separator: " · ")
    }

    /// 顶部的大按钮：有播放记录时继续上次那一集，否则从第一个开始
    private func primaryAction(_ catalog: MagnetCatalog) -> (title: String, file: MagnetFile)? {
        if let last = controller.lastPlayed {
            let label = last.episodeLabel ?? last.title
            if let saved = controller.savedPosition(for: last) {
                return ("继续播放 \(label) · \(timeText(saved))", last)
            }
            return ("继续播放 \(label)", last)
        }
        guard let first = catalog.main.first else { return nil }
        return (catalog.main.count > 1 ? "从第一个开始播放" : "播放", first)
    }

    private func folderHeader(_ folder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.folderBack)
            Text(folder.isEmpty ? "根目录" : folder)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(_ file: MagnetFile, number: Int?, showsEpisode: Bool) -> some View {
        let isLast = controller.lastPlayed?.index == file.index
        let saved = controller.savedPosition(for: file)
        return Button {
            controller.play(file)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isLast ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.tileTint))
                    if let number {
                        Text("\(number)")
                            .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(isLast ? Color.white : Theme.accent)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isLast ? Color.white : Theme.accent)
                    }
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(file.ext.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(file.sizeText)
                        if showsEpisode, let episode = file.episodeLabel {
                            Text(episode)
                        }
                        if let saved {
                            Text("看到 \(timeText(saved))")
                                .foregroundStyle(Theme.accent)
                        } else if isLast {
                            Text("上次播放")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func otherRow(_ file: MagnetFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: file.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text([file.folder, file.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func icon(for kind: MagnetFile.Kind) -> String {
        switch kind {
        case .video: return "film"
        case .subtitle: return "captions.bubble"
        case .image: return "photo"
        case .archive: return "doc.zipper"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }

    private func collapsibleGroup<Content: View>(
        title: String,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                VStack(spacing: 0) { rows }
                    .padding(.vertical, 6)
                    .surfaceCard(cornerRadius: 20)
            }
        }
    }

    // MARK: 最近播放

    @ViewBuilder
    private var historySection: some View {
        if !history.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近播放")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") { history.removeAll() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    ForEach(history.items.prefix(12)) { item in
                        historyRow(item)
                    }
                }
                .padding(.vertical, 6)
                .surfaceCard(cornerRadius: 20)

                Text("长按可以复制链接或删除记录。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func historyRow(_ item: MagnetHistoryItem) -> some View {
        Button {
            guard let link = MagnetLink.parse(item.magnet) else { return }
            input = item.magnet
            inputHint = ""
            showExtras = false
            showOthers = false
            controller.open(link)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(historyDetail(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.magnet
            } label: {
                Label("复制磁力链接", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                history.remove(item.infoHash)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }

    private func historyDetail(_ item: MagnetHistoryItem) -> String {
        var parts: [String] = []
        if let title = item.lastFileTitle, item.videoCount > 1 { parts.append("看到：\(title)") }
        let size = formatSize(Int(clamping: item.totalSize))
        if !size.isEmpty { parts.append(size) }
        parts.append(item.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    // MARK: 说明

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("边下边播，会使用手机流量和存储空间；缓存最多 1–2 GB，会自动清理。", systemImage: "info.circle")
            Label("解析过的资源会记在本机，再次打开不用重新解析，并从上次看到的位置继续。", systemImage: "bolt.horizontal.circle")
            if cloudAvailable {
                Label("115 离线的文件保存在你 115 网盘的「云下载」文件夹，看完可以自己删除。", systemImage: "icloud")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    // MARK: 小部件

    private func capsuleLabel(_ title: String, systemImage: String, prominent: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(prominent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised), in: Capsule())
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// 磁力播放器：在通用播放控制层上加上网络状态、选集和自动下一集。
private struct MagnetWatchView: View {
    @ObservedObject var controller: MagnetController

    var body: some View {
        PlaybackControlsView(
            playback: controller.playback,
            title: controller.playingFile?.title ?? controller.catalog?.name ?? "磁力在线播放",
            loading: controller.preparing,
            loadingText: controller.preparingText,
            error: controller.playError,
            items: controller.playlist.map { file in
                PlaybackListItem(id: String(file.index), title: file.title, subtitle: subtitle(for: file))
            },
            selectedID: controller.playingIndex.map { String($0) } ?? "",
            networkStatus: controller.networkStatus,
            onSelect: { id in
                guard let index = UInt32(id), let file = controller.playlist.first(where: { $0.index == index }) else { return }
                controller.play(file)
            },
            onRetry: { controller.retryPlayback() },
            onClose: { controller.closePlayer() }
        )
    }

    private func subtitle(for file: MagnetFile) -> String {
        [file.episodeLabel ?? "", file.sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
