import SwiftUI

/// 彻底删除的范围
enum RecycleScope: Equatable {
    case selected([String])
    /// 清空整个回收站
    case everything

    var ids: [String] {
        switch self {
        case .selected(let ids): return ids
        case .everything: return []
        }
    }
}

/// 回收站里需要用户确认的操作
enum RecycleConfirmation {
    case delete([Direct115RecycleItem])
    case clear
}

/// 115 要求输入安全密钥时弹出的面板
struct RecycleKeyRequest: Identifiable {
    let id = UUID()
    let scope: RecycleScope
    let message: String
}

/// 回收站里一项的种类，决定缩略图位置显示什么图标
enum RecycleItemKind {
    case folder
    case video
    case file

    static func of(_ item: Direct115RecycleItem) -> RecycleItemKind {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext) ? .video : .file
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "ts", "m2ts", "mts", "webm", "flv", "f4v",
        "rmvb", "rm", "mpg", "mpeg", "vob", "3gp", "asf",
    ]
}

/// 回收站：列出 115 回收站里的文件和文件夹，可以还原、彻底删除、清空。
struct RecycleBinView: View {
    @EnvironmentObject private var appState: AppState

    @State private var items: [Direct115RecycleItem]
    @State private var total: Int
    @State private var nextOffset: Int?
    @State private var loading: Bool
    @State private var loadingMore = false
    @State private var error = ""
    @State private var selection: Set<String>
    @State private var confirmation: RecycleConfirmation?
    @State private var keyRequest: RecycleKeyRequest?
    @State private var operation: String?
    @State private var message: String?
    @State private var problem: String?
    /// 这次打开页面期间用户输入过的安全密钥，下次不用再输入
    @State private var rememberedKey = ""
    @State private var loadRequestID = UUID()

    private static let pageSize = 100

    init(initialItems: [Direct115RecycleItem]? = nil, initialSelection: Set<String> = [],
         initialConfirmation: RecycleConfirmation? = nil) {
        _items = State(initialValue: initialItems ?? [])
        _total = State(initialValue: initialItems?.count ?? 0)
        _loading = State(initialValue: initialItems == nil)
        _selection = State(initialValue: initialSelection)
        _confirmation = State(initialValue: initialConfirmation)
    }

    var body: some View {
        content
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { clearButton }
            }
            .designScreen("recycle")
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .overlay { operationOverlay }
            .toast($message)
            .task {
                if !InterfacePreview.active { await load() }
            }
            .sheet(item: $keyRequest) { request in
                SecurityKeySheet(message: request.message) { key in
                    performDelete(request.scope, key: key)
                }
            }
            .alert(confirmationTitle, isPresented: confirmationBinding, presenting: confirmation) { pending in
                confirmationActions(pending)
            } message: { pending in
                Text(confirmationMessage(pending))
            }
            .alert("操作没有完成", isPresented: problemBinding) {
                Button("好", role: .cancel) { }
            } message: {
                Text(problem ?? "")
            }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !error.isEmpty {
            EmptyStateView(
                icon: AppIcon.alert.name,
                title: "回收站加载失败",
                message: error,
                actionTitle: "重试",
                action: { Task { await load() } }
            )
        } else if items.isEmpty {
            EmptyStateView(
                icon: AppIcon.recycleBin.name,
                title: "回收站是空的",
                message: "删除的文件会先进入这里，还原后回到原来的位置。"
            )
        } else {
            VStack(spacing: 0) {
                ManagementBanner(text: "删除的文件会先进入这里，还原后回到原来的位置。回收站里的文件保留多久由 115 决定，彻底删除后无法找回。")
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                summaryBar
                itemList
            }
        }
    }

    private var summaryText: String {
        let count = max(total, items.count)
        var text = "\(count) 项"
        if nextOffset == nil {
            let bytes = items.reduce(0) { $0 + max(0, $1.size) }
            if bytes > 0 { text += " · " + formatSize(bytes) }
        }
        return text
    }

    private var allSelected: Bool {
        !items.isEmpty && selection.count == items.count
    }

    private var summaryBar: some View {
        HStack {
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.recycle.summary")
            Spacer(minLength: 8)
            Button(allSelected ? "取消全选" : "全选") {
                Haptics.select()
                selection = allSelected ? [] : Set(items.map { $0.id })
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 32)
            .accessibilityIdentifier("library.recycle.selectAll")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var itemList: some View {
        List {
            ForEach(items) { item in
                row(item)
            }
            if nextOffset != nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load(silent: true) }
    }

    private func row(_ item: Direct115RecycleItem) -> some View {
        let selected = selection.contains(item.id)
        return Button {
            toggle(item)
        } label: {
            HStack(spacing: 12) {
                CheckBadge(selected: selected, size: 22)
                tile(for: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle(for: item))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if !item.parentName.isEmpty {
                        Text("原位置：" + item.parentName)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("library.recycle.row.\(item.id)")
        .listRowBackground(selected ? Theme.tileTint : Color.clear)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Theme.hairline)
        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
        .onAppear {
            if item.id == items.last?.id { loadMore() }
        }
    }

    private func tile(for item: Direct115RecycleItem) -> some View {
        let kind = RecycleItemKind.of(item)
        let symbol: String
        switch kind {
        case .folder: symbol = AppIcon.folder.name
        case .video: symbol = AppIcon.video.name
        case .file: symbol = AppIcon.file.name
        }
        return Image(systemName: symbol)
            .font(.system(size: kind == .folder ? 22 : 18, weight: Theme.iconWeight))
            .foregroundStyle(kind == .folder ? Theme.accent : Theme.textSecondary)
            .frame(width: 84, height: 48)
            .background(kind == .folder ? Theme.tileTint : Theme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
    }

    private func subtitle(for item: Direct115RecycleItem) -> String {
        var parts: [String] = []
        if item.isDirectory {
            parts.append("文件夹")
        } else {
            let size = formatSize(item.size)
            if !size.isEmpty { parts.append(size) }
        }
        parts.append("删除于 " + DeletedTimeText.text(item.deletedAt))
        return parts.joined(separator: " · ")
    }

    private func toggle(_ item: Direct115RecycleItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        Haptics.select()
    }

    // MARK: 顶栏与底部操作

    private var clearButton: some View {
        Button("清空") { confirmation = .clear }
            .foregroundStyle(Theme.danger)
            .disabled(items.isEmpty || loading || operation != nil)
            .accessibilityIdentifier("library.recycle.clear")
    }

    private var selectedItems: [Direct115RecycleItem] {
        items.filter { selection.contains($0.id) }
    }

    @ViewBuilder
    private var dock: some View {
        if !selection.isEmpty {
            VStack(spacing: 10) {
                Text("已选 \(selection.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("library.recycle.dock.summary")
                HStack(spacing: 10) {
                    Button {
                        confirmation = .delete(selectedItems)
                    } label: {
                        Label("彻底删除", systemImage: AppIcon.trash.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.danger.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.pressable(scale: 0.96))
                    .accessibilityIdentifier("library.recycle.delete")

                    Button {
                        restore(selectedItems)
                    } label: {
                        Label("还原", systemImage: AppIcon.restore.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.onPrimary)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.primaryAction, in: Capsule())
                    }
                    .buttonStyle(.pressable(scale: 0.96))
                    .accessibilityIdentifier("library.recycle.restore")
                }
            }
            .padding(12)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.recycle.dock")
        }
    }

    @ViewBuilder
    private var operationOverlay: some View {
        if let text = operation {
            OperationOverlay(text: text)
        }
    }

    // MARK: 确认

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .delete(let chosen)?: return "彻底删除 \(chosen.count) 项？"
        case .clear?: return "清空回收站？"
        case nil: return ""
        }
    }

    private func confirmationMessage(_ pending: RecycleConfirmation) -> String {
        switch pending {
        case .delete(let chosen):
            let hasFolder = chosen.contains { $0.isDirectory }
            let extra = hasFolder ? "文件夹里的内容也会一起删除。" : ""
            return "所选内容会从 115 永久删除，无法找回。" + extra
        case .clear:
            return "回收站里的全部 \(max(total, items.count)) 项会从 115 永久删除，无法找回。"
        }
    }

    @ViewBuilder
    private func confirmationActions(_ pending: RecycleConfirmation) -> some View {
        switch pending {
        case .delete(let chosen):
            Button("彻底删除", role: .destructive) {
                performDelete(.selected(chosen.map { $0.id }), key: currentKey)
            }
        case .clear:
            Button("清空", role: .destructive) {
                performDelete(.everything, key: currentKey)
            }
        }
        Button("取消", role: .cancel) { }
    }

    private var currentKey: String {
        rememberedKey.isEmpty ? Direct115Client.defaultSecurityKey : rememberedKey
    }

    // MARK: 操作

    private func restore(_ chosen: [Direct115RecycleItem]) {
        guard operation == nil, !chosen.isEmpty, let client = appState.directClient() else { return }
        let ids = chosen.map { $0.id }
        let sessionID = appState.sessionID
        operation = "正在还原 \(ids.count) 项…"
        Task {
            var failure: String?
            do {
                try await client.restoreFromRecycleBin(ids)
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
                remove(Set(ids))
                message = "已还原 \(ids.count) 项"
            }
            await load(silent: true)
        }
    }

    private func performDelete(_ scope: RecycleScope, key: String) {
        guard operation == nil, let client = appState.directClient() else { return }
        let sessionID = appState.sessionID
        let wasEverything = scope == .everything
        operation = wasEverything ? "正在清空回收站…" : "正在彻底删除…"
        Task {
            var failure: Error?
            do {
                try await client.deleteFromRecycleBin(scope.ids, securityKey: key)
            } catch {
                failure = error
            }
            operation = nil
            guard sessionID == appState.sessionID else { return }
            if let failure {
                Haptics.warning()
                askForKeyOrReport(failure, scope: scope)
            } else {
                Haptics.success()
                rememberedKey = key
                if wasEverything {
                    items = []
                    selection = []
                    total = 0
                    nextOffset = nil
                    message = "回收站已清空"
                } else {
                    let count = scope.ids.count
                    remove(Set(scope.ids))
                    message = "已彻底删除 \(count) 项"
                }
            }
            await load(silent: true)
        }
    }

    /// 115 提示需要安全密钥时让用户输入，其他错误直接说明原因
    private func askForKeyOrReport(_ failure: Error, scope: RecycleScope) {
        if let fileError = failure as? Direct115FileError, case .needsSecurityKey(let text) = fileError {
            Task {
                // 刚收起的面板还在动画里，稍等一下再弹出输入框
                try? await Task.sleep(nanoseconds: 350_000_000)
                keyRequest = RecycleKeyRequest(scope: scope, message: text)
            }
        } else {
            problem = failure.localizedDescription
        }
    }

    private func remove(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        total = max(0, total - ids.count)
    }

    // MARK: 加载

    private func load(silent: Bool = false) async {
        guard appState.isAuthenticated, let client = appState.directClient() else {
            loading = false
            error = "请先登录 115"
            return
        }
        let sessionID = appState.sessionID
        let requestID = UUID()
        loadRequestID = requestID
        if !silent {
            loading = true
            error = ""
        }
        do {
            let page = try await client.recycleBin(offset: 0, limit: Self.pageSize)
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            items = page.items
            total = page.total
            nextOffset = page.nextOffset
            selection = selection.intersection(Set(page.items.map { $0.id }))
            error = ""
            loading = false
        } catch {
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            if !silent { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func loadMore() {
        guard let offset = nextOffset, !loadingMore, !loading, appState.isAuthenticated,
              let client = appState.directClient() else { return }
        loadingMore = true
        let sessionID = appState.sessionID
        let requestID = loadRequestID
        Task {
            do {
                let page = try await client.recycleBin(offset: offset, limit: Self.pageSize)
                if sessionID == appState.sessionID, requestID == loadRequestID {
                    let known = Set(items.map { $0.id })
                    items.append(contentsOf: page.items.filter { !known.contains($0.id) })
                    total = page.total
                    nextOffset = page.nextOffset
                }
            } catch {
                if sessionID == appState.sessionID { message = error.localizedDescription }
            }
            loadingMore = false
        }
    }
}

// MARK: - 安全密钥

/// 115 开启了安全密钥时，彻底删除需要输入 6 位数字密钥。只在这次删除里使用，不会保存。
struct SecurityKeySheet: View {
    let message: String
    let onConfirm: (String) -> Void

    @State private var key = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canConfirm: Bool { key.count == 6 }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("取消") { dismiss() }
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("library.recycle.key.cancel")
                Spacer()
                Text("输入安全密钥")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Color.clear.frame(width: 32, height: 1)
            }
            Text(message.isEmpty ? "彻底删除需要 115 的 6 位数字安全密钥。" : message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("6 位数字安全密钥", text: $key)
                .keyboardType(.numberPad)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .padding(.vertical, 14)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .onChange(of: key) { value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if digits != value { key = digits }
                }
                .accessibilityIdentifier("library.recycle.key.field")
            Button("彻底删除") {
                let entered = key
                dismiss()
                onConfirm(entered)
            }
            .buttonStyle(DestructiveActionStyle())
            .disabled(!canConfirm)
            .accessibilityIdentifier("library.recycle.key.confirm")
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }
}
