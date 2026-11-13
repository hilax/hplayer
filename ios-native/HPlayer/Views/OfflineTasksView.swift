import SwiftUI
import UIKit

/// 离线任务按状态分成三组
enum OfflineFilter: String, CaseIterable {
    case running
    case done
    case failed

    var title: String {
        switch self {
        case .running: return "进行中"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }

    func includes(_ status: Direct115OfflineTask.Status) -> Bool {
        switch self {
        case .running: return status == .waiting || status == .downloading
        case .done: return status == .done
        case .failed: return status == .failed
        }
    }
}

/// 离线任务卡片上的文字
enum OfflineTaskText {
    /// 「63%」
    static func percent(_ task: Direct115OfflineTask) -> String {
        "\(Int(task.percent.rounded()))%"
    }

    /// 「 · 5.82 GB / 9.24 GB」或「 · 等待中」，跟在百分比后面
    static func detail(_ task: Direct115OfflineTask) -> String {
        if task.status == .waiting { return " · 等待中" }
        guard task.size > 0 else { return "" }
        let finished = Int64(Double(task.size) * min(max(task.percent, 0), 100) / 100)
        return " · " + DownloadFormat.bytes(finished) + " / " + DownloadFormat.bytes(Int64(task.size))
    }

    /// 「3.4 MB/s · 剩余约 17 分钟」
    static func rate(_ task: Direct115OfflineTask) -> String {
        switch task.status {
        case .waiting:
            return "暂无速度"
        case .downloading:
            let parts = [
                DownloadFormat.speed(task.speed),
                task.remainingSeconds > 0 ? DownloadFormat.remaining(task.remainingSeconds) : "",
            ].filter { !$0.isEmpty }
            return parts.isEmpty ? "正在下载" : parts.joined(separator: " · ")
        case .done, .failed:
            return ""
        }
    }

    /// 「磁力链接 · 保存到 网盘 / 电影」，等待中的任务写「正在等待资源」
    static func subtitle(_ task: Direct115OfflineTask, folder: String?) -> String {
        var parts = [task.sourceLabel]
        if task.status == .waiting {
            parts.append("正在等待资源")
        } else if let folder, !folder.isEmpty {
            parts.append("保存到 " + folder)
        }
        return parts.joined(separator: " · ")
    }

    /// 已完成任务的说明
    static func finished(_ task: Direct115OfflineTask) -> String {
        task.size > 0 ? "已完成 · " + DownloadFormat.bytes(Int64(task.size)) : "已完成"
    }
}

/// 离线下载：115 云端帮你下载磁力、HTTP、ed2k 链接，完成后文件直接出现在网盘里。
struct OfflineTasksView: View {
    @EnvironmentObject private var appState: AppState
    /// 点「在网盘中查看」：参数是从根目录到保存位置的每一级
    var onShowFolder: (([Direct115PathEntry]) -> Void)?

    @State private var tasks: [Direct115OfflineTask]
    @State private var loading: Bool
    @State private var error = ""
    @State private var filter: String
    @State private var folderLabels: [String: String]
    @State private var showAdd: Bool
    @State private var pendingRemoval: Direct115OfflineTask?
    @State private var pendingClear: Direct115OfflineClearScope?
    @State private var operation: String?
    @State private var message: String?
    @State private var problem: String?
    @State private var loadRequestID = UUID()

    /// 最多读取的页数（每页 30 个任务），避免任务很多时一直读下去
    private static let maxPages = 10
    private static let pollNanoseconds: UInt64 = 5_000_000_000

    /// 全局内存缓存：再次进入页面时瞬间展示，无需等待转圈
    private static var cachedTasks: [Direct115OfflineTask]?
    private static var cachedFolderLabels: [String: String] = [:]
    private static var cachedSessionID: UUID?

    static func clearCache() {
        cachedTasks = nil
        cachedFolderLabels.removeAll()
        cachedSessionID = nil
    }

    init(onShowFolder: (([Direct115PathEntry]) -> Void)? = nil, initialTasks: [Direct115OfflineTask]? = nil,
         initialFilter: OfflineFilter = .running, initialFolderLabels: [String: String] = [:],
         initialShowAdd: Bool = false) {
        self.onShowFolder = onShowFolder
        let existing = initialTasks ?? Self.cachedTasks ?? []
        _tasks = State(initialValue: existing)
        _loading = State(initialValue: initialTasks == nil && existing.isEmpty)
        _filter = State(initialValue: initialFilter.rawValue)
        var labels = Self.cachedFolderLabels
        for (k, v) in initialFolderLabels { labels[k] = v }
        _folderLabels = State(initialValue: labels)
        _showAdd = State(initialValue: initialShowAdd)
    }

    var body: some View {
        VStack(spacing: 0) {
            CountSegmentedControl(segments: segments, selection: $filter, identifierPrefix: "library.offline.segment")
                .padding(.horizontal, 16)
                .padding(.top, 12)
            content
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("离线下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addButton }
        }
        .designScreen("offline")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay { operationOverlay }
        .toast($message)
        .task {
            if InterfacePreview.active { return }
            if Self.cachedSessionID != appState.sessionID {
                Self.clearCache()
                Self.cachedSessionID = appState.sessionID
            }
            await load(silent: !loading)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                if Task.isCancelled { break }
                // 轮询进行中任务时仅刷新首页，速度更快且不浪费网络带宽
                if hasRunning, operation == nil, !showAdd { await load(silent: true, onlyFirstPage: true) }
            }
        }
        .sheet(isPresented: $showAdd) {
            OfflineAddSheet(client: appState.directClient()) { summary in
                filter = OfflineFilter.running.rawValue
                message = "已添加 \(summary.succeeded) 个离线任务"
                Task { await load(silent: true, onlyFirstPage: true) }
            }
        }
        .confirmationDialog("删除这个离线任务？", isPresented: removalBinding, titleVisibility: .visible,
                            presenting: pendingRemoval) { task in
            Button("仅删除任务") { remove(task, deleteFiles: false) }
            Button("删除任务和已下载的文件", role: .destructive) { remove(task, deleteFiles: true) }
            Button("取消", role: .cancel) { }
        } message: { task in
            Text(task.name.isEmpty ? "这个任务" : "「" + task.name + "」")
        }
        .alert(clearAlertTitle, isPresented: clearBinding, presenting: pendingClear) { scope in
            Button(scope == .failed ? "清除失败任务" : "清除已完成", role: .destructive) { clear(scope) }
            Button("取消", role: .cancel) { }
        } message: { scope in
            Text(scope == .failed ? "只清除列表里的失败记录。" : "只清除列表里的记录，已经下载到网盘的文件会保留。")
        }
        .alert("操作没有完成", isPresented: problemBinding) {
            Button("好", role: .cancel) { }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: 数据

    private var selectedFilter: OfflineFilter {
        OfflineFilter(rawValue: filter) ?? .running
    }

    private var visibleTasks: [Direct115OfflineTask] {
        let current = selectedFilter
        return tasks.filter { current.includes($0.status) }
    }

    private var segments: [CountSegment] {
        OfflineFilter.allCases.map { option in
            CountSegment(id: option.rawValue, title: option.title,
                         count: tasks.filter { option.includes($0.status) }.count)
        }
    }

    private var hasRunning: Bool {
        tasks.contains { OfflineFilter.running.includes($0.status) }
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var clearBinding: Binding<Bool> {
        Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })
    }

    private var clearAlertTitle: String {
        guard let scope = pendingClear else { return "" }
        return scope == .failed ? "清除失败的任务？" : "清除已完成的任务？"
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !error.isEmpty && tasks.isEmpty {
            EmptyStateView(
                icon: AppIcon.alert.name,
                title: "离线任务加载失败",
                message: error,
                actionTitle: "重试",
                action: { Task { await load() } }
            )
        } else if visibleTasks.isEmpty {
            emptyState
        } else {
            taskList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch selectedFilter {
        case .running:
            EmptyStateView(
                icon: AppIcon.cloudDownload.name,
                title: "没有进行中的任务",
                message: "添加磁力、HTTP 或 ed2k 链接，115 会在云端帮你下载，不占用手机流量和存储。",
                actionTitle: "添加任务",
                action: { showAdd = true }
            )
        case .done:
            EmptyStateView(
                icon: AppIcon.cloudReady.name,
                title: "还没有已完成的任务",
                message: "任务下载完成后会出现在这里，文件保存在你选的网盘文件夹里。"
            )
        case .failed:
            EmptyStateView(
                icon: AppIcon.cloudFailed.name,
                title: "没有失败的任务",
                message: "资源失效或没有下载源的任务会出现在这里。"
            )
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                    card(task)
                        .reveal(index, id: task.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load(silent: true) }
    }

    // MARK: 任务卡片

    private func card(_ task: Direct115OfflineTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                statusTile(task.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name.isEmpty ? "未命名任务" : task.name)
                        .font(.scaled(14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(OfflineTaskText.subtitle(task, folder: folderLabels[task.folderID]))
                        .font(.scaled(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                taskMenu(task)
            }
            cardFooter(task)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.offline.task.\(task.id)")
    }

    private func statusTile(_ status: Direct115OfflineTask.Status) -> some View {
        let symbol: String
        let tint: Color
        let background: Color
        switch status {
        case .waiting:
            symbol = AppIcon.clock.name
            tint = Theme.accent
            background = Theme.tileTint
        case .downloading:
            symbol = AppIcon.cloudDownload.name
            tint = Theme.accent
            background = Theme.tileTint
        case .done:
            symbol = AppIcon.cloudReady.name
            tint = Theme.success
            background = Theme.success.opacity(0.14)
        case .failed:
            symbol = AppIcon.cloudFailed.name
            tint = Theme.danger
            background = Theme.danger.opacity(0.14)
        }
        return Image(systemName: symbol)
            .font(.scaled(18, weight: Theme.iconWeight))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    @ViewBuilder
    private func cardFooter(_ task: Direct115OfflineTask) -> some View {
        switch task.status {
        case .waiting, .downloading:
            VStack(spacing: 8) {
                ThinProgressBar(fraction: task.percent / 100)
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Text(OfflineTaskText.percent(task))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                        Text(OfflineTaskText.detail(task))
                    }
                    Spacer(minLength: 8)
                    Text(OfflineTaskText.rate(task))
                }
                .font(.scaled(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .padding(.top, 12)
        case .done:
            HStack(spacing: 6) {
                Image(systemName: AppIcon.success.name)
                    .font(.scaled(13, weight: .semibold))
                Text(OfflineTaskText.finished(task))
            }
            .font(.scaled(12))
            .foregroundStyle(Theme.success)
            .padding(.top, 10)
        case .failed:
            Text("下载失败，可能是资源已失效或没有下载源。可以删除后重新添加。")
                .font(.scaled(12))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func taskMenu(_ task: Direct115OfflineTask) -> some View {
        Menu {
            if !task.sourceURL.isEmpty {
                Button {
                    copyLink(task)
                } label: {
                    Label("复制链接", systemImage: AppIcon.copy.name)
                }
            }
            if onShowFolder != nil && !task.folderID.isEmpty {
                Button {
                    showFolder(task)
                } label: {
                    Label("在网盘中查看", systemImage: AppIcon.folder.name)
                }
            }
            Button(role: .destructive) {
                pendingRemoval = task
            } label: {
                Label("删除任务", systemImage: AppIcon.trash.name)
            }
        } label: {
            Image(systemName: AppIcon.more.name)
                .font(.scaled(16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("任务菜单")
        .accessibilityIdentifier("library.offline.menu.\(task.id)")
    }

    // MARK: 顶栏与底栏

    private var addButton: some View {
        Button {
            showAdd = true
        } label: {
            Image(systemName: AppIcon.add.name)
                .font(.scaled(15, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 32, height: 32)
                .background(Theme.primaryAction, in: Circle())
        }
        .accessibilityLabel("添加任务")
        .accessibilityIdentifier("library.offline.add")
    }

    private var clearScope: Direct115OfflineClearScope {
        selectedFilter == .failed ? .failed : .completed
    }

    private var canClear: Bool {
        guard operation == nil, !loading else { return false }
        if selectedFilter == .failed { return tasks.contains { $0.status == .failed } }
        return tasks.contains { $0.status == .done }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                pendingClear = clearScope
            } label: {
                Label(selectedFilter == .failed ? "清除失败任务" : "清除已完成", systemImage: AppIcon.trash.name)
            }
            .buttonStyle(FooterButtonStyle())
            .disabled(!canClear)
            .accessibilityIdentifier("library.offline.clear")

            Button {
                showAdd = true
            } label: {
                Label("添加任务", systemImage: AppIcon.add.name)
            }
            .buttonStyle(FooterButtonStyle(prominent: true))
            .accessibilityIdentifier("library.offline.addBottom")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Theme.pageBackground.opacity(0.96))
    }

    @ViewBuilder
    private var operationOverlay: some View {
        if let text = operation {
            OperationOverlay(text: text)
        }
    }

    // MARK: 操作

    private func run(_ title: String, _ work: @escaping (Direct115Client) async throws -> String) {
        guard operation == nil, let client = appState.directClient() else { return }
        let sessionID = appState.sessionID
        operation = title
        Task {
            var done: String?
            var failure: String?
            do {
                done = try await work(client)
            } catch {
                failure = error.localizedDescription
            }
            operation = nil
            guard sessionID == appState.sessionID else { return }
            if let failure {
                Haptics.warning()
                problem = failure
            } else {
                Haptics.success()
                message = done
            }
            await load(silent: true)
        }
    }

    private func remove(_ task: Direct115OfflineTask, deleteFiles: Bool) {
        let hash = task.remoteHash.isEmpty ? task.infoHash : task.remoteHash
        guard !hash.isEmpty else {
            problem = "这个任务没有编号，无法删除。"
            return
        }
        tasks.removeAll { $0.id == task.id }
        Self.cachedTasks = tasks
        run(deleteFiles ? "正在删除任务和文件…" : "正在删除任务…") { client in
            try await client.deleteOfflineTasks([hash], deleteFiles: deleteFiles)
            return deleteFiles ? "已删除任务，文件已移入回收站" : "已删除任务"
        }
    }

    private func clear(_ scope: Direct115OfflineClearScope) {
        tasks.removeAll { scope == .failed ? $0.status == .failed : $0.status == .done }
        Self.cachedTasks = tasks
        run("正在清除任务…") { client in
            try await client.clearOfflineTasks(scope)
            return scope == .failed ? "已清除失败的任务" : "已清除已完成的任务"
        }
    }

    private func copyLink(_ task: Direct115OfflineTask) {
        UIPasteboard.general.string = task.sourceURL
        Haptics.success()
        message = "已复制链接"
    }

    private func showFolder(_ task: Direct115OfflineTask) {
        guard let client = appState.directClient(), let onShowFolder else { return }
        let folderID = task.folderID
        let sessionID = appState.sessionID
        Task {
            do {
                let trail = try await client.folderTrail(id: folderID)
                guard sessionID == appState.sessionID else { return }
                if trail.isEmpty {
                    problem = "没能找到保存位置，它可能已经被移动或删除。"
                } else {
                    onShowFolder(trail)
                }
            } catch {
                if sessionID == appState.sessionID { problem = error.localizedDescription }
            }
        }
    }

    // MARK: 加载

    private static func unique(_ tasks: [Direct115OfflineTask]) -> [Direct115OfflineTask] {
        var seen = Set<String>()
        return tasks.filter { seen.insert($0.id).inserted }
    }

    private func load(silent: Bool = false, onlyFirstPage: Bool = false) async {
        guard appState.isAuthenticated, let client = appState.directClient() else {
            loading = false
            error = "请先登录 115"
            return
        }
        let sessionID = appState.sessionID
        let requestID = UUID()
        loadRequestID = requestID
        if !silent && tasks.isEmpty {
            loading = true
            error = ""
        }
        do {
            // 第 1 步：优先加载第一页，立即呈现在界面上（消除白屏/长时转圈）
            let firstResult = try await client.offlinePage(1)
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }

            if onlyFirstPage {
                // 仅刷新首页：将更新的任务与已有列表合并，保持其他页数据
                tasks = Self.unique(firstResult.tasks + tasks)
                Self.cachedTasks = tasks
                Self.cachedSessionID = sessionID
                error = ""
                loading = false
                resolveFoldersAsync(client, sessionID: sessionID)
                return
            }

            var collected = firstResult.tasks
            tasks = Self.unique(collected)
            Self.cachedTasks = tasks
            Self.cachedSessionID = sessionID
            error = ""
            loading = false
            resolveFoldersAsync(client, sessionID: sessionID)

            // 第 2 步：后台并发加载剩余页（限制最多 maxPages 页）
            let totalPages = min(firstResult.pageCount, Self.maxPages)
            if totalPages > 1 {
                let remainingPages = Array(2...totalPages)
                await withTaskGroup(of: (Int, [Direct115OfflineTask])?.self) { group in
                    var pageIndex = 0
                    let concurrency = 3
                    while pageIndex < remainingPages.count && pageIndex < concurrency {
                        let p = remainingPages[pageIndex]
                        pageIndex += 1
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let res = try? await client.offlinePage(p)
                            return res.map { (p, $0.tasks) }
                        }
                    }

                    for await result in group {
                        guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { break }
                        if let (_, newTasks) = result, !newTasks.isEmpty {
                            collected.append(contentsOf: newTasks)
                            tasks = Self.unique(collected)
                            Self.cachedTasks = tasks
                        }
                        if pageIndex < remainingPages.count {
                            let nextP = remainingPages[pageIndex]
                            pageIndex += 1
                            group.addTask {
                                guard !Task.isCancelled else { return nil }
                                let res = try? await client.offlinePage(nextP)
                                return res.map { (nextP, $0.tasks) }
                            }
                        }
                    }
                }
                guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
                tasks = Self.unique(collected)
                Self.cachedTasks = tasks
                resolveFoldersAsync(client, sessionID: sessionID)
            }
        } catch {
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            if !silent && tasks.isEmpty { self.error = error.localizedDescription }
            loading = false
        }
    }

    /// 异步并发解析任务保存位置，并写入全局缓存
    private func resolveFoldersAsync(_ client: Direct115Client, sessionID: UUID) {
        Task {
            let wanted = Set(tasks.map { $0.folderID }).filter { !$0.isEmpty && folderLabels[$0] == nil && Self.cachedFolderLabels[$0] == nil }
            guard !wanted.isEmpty else { return }
            await withTaskGroup(of: (String, String)?.self) { group in
                for id in wanted.prefix(8) {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        if let names = try? await client.folderPath(id: id), !names.isEmpty {
                            return (id, names.joined(separator: " / "))
                        }
                        return nil
                    }
                }
                for await result in group {
                    guard let (id, label) = result, !Task.isCancelled, sessionID == appState.sessionID else { continue }
                    folderLabels[id] = label
                    Self.cachedFolderLabels[id] = label
                }
            }
        }
    }
}

// MARK: - 添加离线任务

/// 添加离线任务：粘贴链接，选保存位置，交给 115。
struct OfflineAddSheet: View {
    let client: Direct115Client?
    let onAdded: (Direct115OfflineAddSummary) -> Void

    /// 上次选的保存位置；为空表示 115 默认的离线下载文件夹
    @AppStorage("hplayer.offline.saveFolderID") private var savedFolderID = ""
    @AppStorage("hplayer.offline.saveFolderPath") private var savedFolderPath = ""
    @State private var text: String
    @State private var submitting = false
    @State private var notice: String?
    @State private var showFolderPicker = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(client: Direct115Client?, initialText: String = "", onAdded: @escaping (Direct115OfflineAddSummary) -> Void) {
        self.client = client
        self.onAdded = onAdded
        _text = State(initialValue: initialText)
    }

    var body: some View {
        let batch = OfflineLinkBatch.parse(text)
        return VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    linksLabel
                    editor
                    hintRow(batch)
                    Text("保存设置")
                        .font(.scaled(13))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                    settingsGroup
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            footer(batch)
        }
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .designScreen("offline-add")
        .sheet(isPresented: $showFolderPicker) {
            SaveFolderPickerSheet(client: client) { id, path in
                savedFolderID = id
                savedFolderPath = path
            }
        }
    }

    // MARK: 版面

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(.scaled(16))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.offlineAdd.cancel")
            Spacer()
            Text("添加离线任务")
                .font(.scaled(17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 32, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(minHeight: 56)
    }

    private var linksLabel: some View {
        HStack {
            Text("下载链接（一行一条）")
                .font(.scaled(13))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Button {
                paste()
            } label: {
                Label("从剪贴板粘贴", systemImage: AppIcon.paste.name)
                    .font(.scaled(13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 32)
            }
            .accessibilityIdentifier("library.offlineAdd.paste")
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.scaled(13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .accessibilityIdentifier("library.offlineAdd.links")
            if text.isEmpty {
                Text("粘贴磁力、HTTP、ed2k 链接，一行一条")
                    .font(.scaled(13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 150)
        .background(Theme.pageBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
        }
    }

    private func hintRow(_ batch: OfflineLinkBatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("已识别 \(batch.links.count) 条")
                    .font(.scaled(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                Text(batch.links.isEmpty ? "支持磁力、HTTP、ed2k、FTP 链接，也可以只贴 BT 哈希" : batch.kindSummary + "，支持 ed2k、ftp 与 BT 链接")
                    .font(.scaled(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.offlineAdd.hint")
            if !batch.rejected.isEmpty {
                DesignNotice(symbol: AppIcon.alert.name,
                             text: "有 \(batch.rejected.count) 行无法识别，会被忽略。", warning: true)
            }
            if batch.links.count > Direct115Client.offlineAddLimit {
                DesignNotice(symbol: AppIcon.alert.name,
                             text: "一次最多添加 \(Direct115Client.offlineAddLimit) 条链接，请分批添加。", warning: true)
            }
        }
        .padding(.top, 8)
    }

    private var settingsGroup: some View {
        VStack(spacing: 0) {
            Button {
                showFolderPicker = true
            } label: {
                LibraryActionRow(symbol: AppIcon.folder.name, title: "保存到",
                                 subtitle: savedFolderPath.isEmpty ? "115 默认的离线下载文件夹" : savedFolderPath)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.offlineAdd.folder")
            if !savedFolderID.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 60)
                Button {
                    savedFolderID = ""
                    savedFolderPath = ""
                } label: {
                    LibraryActionRow(symbol: AppIcon.restore.name, title: "使用默认位置",
                                     subtitle: "保存到 115 默认的离线下载文件夹", showsChevron: false, tone: .neutral)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.offlineAdd.defaultFolder")
            }
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func footer(_ batch: OfflineLinkBatch) -> some View {
        let count = batch.links.count
        let canSubmit = count > 0 && count <= Direct115Client.offlineAddLimit && !submitting && client != nil
        return VStack(spacing: 10) {
            if let notice {
                DesignNotice(symbol: AppIcon.alert.name, text: notice, warning: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("library.offlineAdd.notice")
            }
            Button {
                submit(batch)
            } label: {
                HStack(spacing: 8) {
                    if submitting {
                        ProgressView()
                    } else {
                        Image(systemName: AppIcon.cloudDownload.name)
                    }
                    Text(submitting ? "正在提交…" : "开始离线下载（\(count)）")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!canSubmit)
            .accessibilityIdentifier("library.offlineAdd.submit")
            Text("任务由 115 云端下载，不占用手机流量与存储")
                .font(.scaled(12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    // MARK: 操作

    private func paste() {
        guard let clip = UIPasteboard.general.string, !clip.isEmpty else {
            notice = "剪贴板里没有文字。"
            return
        }
        notice = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = clip
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + clip
        }
        Haptics.select()
    }

    private func shortLink(_ link: String) -> String {
        link.count > 48 ? String(link.prefix(48)) + "…" : link
    }

    private func submit(_ batch: OfflineLinkBatch) {
        guard let client, !submitting, !batch.links.isEmpty else { return }
        let links = batch.links.map { $0.text }
        let folderID: String? = savedFolderID.isEmpty ? nil : savedFolderID
        submitting = true
        notice = nil
        focused = false
        Task {
            do {
                let status = try await client.user()
                guard let userID = status.userId, userID > 0 else {
                    throw Direct115OfflineError.server("没能确认 115 账号，请重新登录后再试")
                }
                let summary = try await client.addOfflineTasks(links, userID: userID, folderID: folderID)
                submitting = false
                if summary.failures.isEmpty {
                    Haptics.success()
                    dismiss()
                    onAdded(summary)
                } else {
                    Haptics.warning()
                    // 留下没成功的链接，方便修改后重试
                    text = summary.failures.map { $0.link }.joined(separator: "\n")
                    let reasons = summary.failures.prefix(3).map { shortLink($0.link) + "：" + ($0.error.errorDescription ?? "失败") }
                    var line = "已添加 \(summary.succeeded) 条，\(summary.failures.count) 条没有成功。" + reasons.joined(separator: "；")
                    if summary.failures.count > 3 { line += "……" }
                    notice = line
                    if summary.succeeded > 0 { onAdded(summary) }
                }
            } catch {
                submitting = false
                Haptics.warning()
                notice = error.localizedDescription
            }
        }
    }
}

// MARK: - 选择保存位置

/// 选一个网盘文件夹作为离线任务的保存位置。
struct SaveFolderPickerSheet: View {
    let client: Direct115Client?
    /// 参数：文件夹编号，以及「网盘 / 电影」这样的路径文字
    let onConfirm: (String, String) -> Void

    @State private var trail: [Crumb]
    @State private var folders: [P115File]
    @State private var loading: Bool
    @State private var error = ""
    @State private var showNewFolder = false
    @State private var skipFirstLoad: Bool
    @Environment(\.dismiss) private var dismiss

    init(client: Direct115Client?, preloadedFolders: [P115File]? = nil, onConfirm: @escaping (String, String) -> Void) {
        self.client = client
        self.onConfirm = onConfirm
        _trail = State(initialValue: [Crumb(cid: "0", name: "网盘")])
        _folders = State(initialValue: preloadedFolders ?? [])
        _loading = State(initialValue: preloadedFolders == nil)
        _skipFirstLoad = State(initialValue: preloadedFolders != nil)
    }

    private var current: Crumb { trail.last ?? Crumb(cid: "0", name: "网盘") }
    private var pathText: String { FileOperationText.pathLabel(trail) }

    var body: some View {
        VStack(spacing: 0) {
            header
            FolderTrailBar(trail: trail, identifierPrefix: "library.savePicker") { index in
                trail = Array(trail.prefix(index + 1))
            }
            folderList
            footer
        }
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: current.cid) {
            if skipFirstLoad {
                skipFirstLoad = false
                return
            }
            await load(current.cid)
        }
        .sheet(isPresented: $showNewFolder) {
            NamePromptSheet(title: "新建文件夹", hint: "会创建在「\(current.name)」里面。",
                            confirmTitle: "创建", placeholder: "文件夹名称") { name in
                createFolder(name)
            }
        }
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(.scaled(16))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.savePicker.cancel")
            Spacer()
            Text("选择保存位置")
                .font(.scaled(17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("新建") { showNewFolder = true }
                .font(.scaled(16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("library.savePicker.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private var folderList: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !error.isEmpty {
            VStack(spacing: 12) {
                DesignNotice(symbol: AppIcon.alert.name, text: error, warning: true)
                Button("重试") { Task { await load(current.cid) } }
                    .buttonStyle(SecondaryActionStyle())
                    .frame(maxWidth: 160)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty {
            Text("这里没有子文件夹")
                .font(.scaled(14))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func folderRow(_ folder: P115File) -> some View {
        Button {
            Haptics.tap()
            trail.append(Crumb(cid: folder.id, name: folder.name))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: AppIcon.folder.name)
                    .font(.scaled(18, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                Text(folder.name)
                    .font(.scaled(15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: AppIcon.forward.name)
                    .font(.scaled(12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 64)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.savePicker.folder.\(folder.id)")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: AppIcon.folder.name)
                    .font(.scaled(13, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.accent)
                Text("保存位置：")
                    .font(.scaled(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                Text(pathText)
                    .font(.scaled(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.savePicker.destination")
            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(SecondaryActionStyle())
                    .frame(width: 112)
                Button("保存到此处") {
                    let destination = current
                    let label = pathText
                    dismiss()
                    onConfirm(destination.cid, label)
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("library.savePicker.confirm")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func load(_ cid: String) async {
        guard let client else {
            loading = false
            error = "请先登录 115"
            return
        }
        loading = true
        error = ""
        do {
            let listed = try await client.files(cid: cid)
            guard !Task.isCancelled, cid == current.cid else { return }
            folders = listed.filter { $0.isDir }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loading = false
        } catch {
            guard !Task.isCancelled, cid == current.cid else { return }
            self.error = error.localizedDescription
            folders = []
            loading = false
        }
    }

    private func createFolder(_ name: String) {
        guard let client else { return }
        let parent = current.cid
        Task {
            do {
                let folder = try await client.createFolder(named: name, in: parent)
                guard parent == current.cid else { return }
                folders.append(folder)
                folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                error = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
