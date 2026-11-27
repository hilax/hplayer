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
    let itemCount: Int
    let containsFolder: Bool
    /// 仅在已记住的密钥失效等需要说明原因的场景下预填；首次默认密钥试探失败时为空
    let initialNotice: String
}

/// 回收站安全密钥提交结果
enum SecurityKeySubmission {
    case succeeded
    case wrongKey(String)
    case failed(String)
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
            .hudProgress(operation)
            .task {
                if !InterfacePreview.active { await load() }
            }
            .sheet(item: $keyRequest) { request in
                SecurityKeySheet(request: request) { key in
                    await submitDeleteWithKey(request.scope, key: key)
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
                .font(.scaled(12))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.recycle.summary")
            Spacer(minLength: 8)
            Button(allSelected ? "取消全选" : "全选") {
                Haptics.select()
                selection = allSelected ? [] : Set(items.map { $0.id })
            }
            .font(.scaled(13, weight: .medium))
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
            HStack(spacing: Theme.Space.md) {
                CheckBadge(selected: selected, size: 24)
                tile(for: item)
                    .frame(width: 96, height: 54)
                    .coverEdge()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(item.name)
                        .font(Theme.Typo.row.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle(for: item))
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if !item.parentName.isEmpty {
                        Text("原位置：" + item.parentName)
                            .font(Theme.Typo.caption)
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
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: Theme.Space.sm - 2, leading: Theme.contentInset, bottom: Theme.Space.sm - 2, trailing: Theme.contentInset))
        .onAppear {
            if item.id == items.last?.id { loadMore() }
        }
    }

    /// 和网盘文件行同一套：文件夹、视频、其他文件都是中性灰图标放在抬高一级的底上（琥珀只留给进度和强调）
    private func tile(for item: Direct115RecycleItem) -> some View {
        let kind = RecycleItemKind.of(item)
        let symbol: String
        switch kind {
        case .folder: symbol = AppIcon.folder.name
        case .video: symbol = AppIcon.video.name
        case .file: symbol = AppIcon.file.name
        }
        return Image(appIconNamed: symbol)
            .font(.scaled(kind == .folder ? 22 : 18, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceRaised)
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
        // 颜色跟随导航栏按键色（Theme.navigationButton），和返回键一致；红色只用在确认弹窗里
        Button("清空") { confirmation = .clear }
            .disabled(items.isEmpty || loading || operation != nil)
            .accessibilityIdentifier("library.recycle.clear")
    }

    private var selectedItems: [Direct115RecycleItem] {
        items.filter { selection.contains($0.id) }
    }

    /// 选中后浮起的操作栏：统一的浮层外观（floatingSurface），按钮用统一的主按钮 / 次要危险按钮
    @ViewBuilder
    private var dock: some View {
        if !selection.isEmpty {
            VStack(spacing: Theme.Space.sm) {
                Text("已选 \(selection.count) 项")
                    .font(Theme.Typo.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("library.recycle.dock.summary")
                HStack(spacing: Theme.Space.sm) {
                    Button {
                        confirmation = .delete(selectedItems)
                    } label: {
                        Label("彻底删除", image: AppIcon.trash.name)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionButtonStyle(kind: .secondaryDestructive))
                    .accessibilityIdentifier("library.recycle.delete")

                    Button {
                        restore(selectedItems)
                    } label: {
                        Label("还原", image: AppIcon.restore.name)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("library.recycle.restore")
                }
            }
            .padding(Theme.Space.md)
            .floatingSurface(cornerRadius: Theme.Radius.sheet)
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.recycle.dock")
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
                failure = error.userMessage
            }
            operation = nil
            guard sessionID == appState.sessionID else { return }
            if let failure {
                Haptics.warning()
                problem = failure
            } else {
                remove(Set(ids))
                HUD.show("已还原 \(ids.count) 项", .success)
            }
            await load(silent: true)
        }
    }

    private func performDelete(_ scope: RecycleScope, key: String) {
        guard operation == nil, let client = appState.directClient() else { return }
        let sessionID = appState.sessionID
        let wasEverything = scope == .everything
        let usedRememberedKey = !rememberedKey.isEmpty && key == rememberedKey
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
                askForKeyOrReport(failure, scope: scope, usedRememberedKey: usedRememberedKey)
            } else {
                await finishDelete(scope, key: key)
            }
        }
    }

    private func submitDeleteWithKey(_ scope: RecycleScope, key: String) async -> SecurityKeySubmission {
        guard let client = appState.directClient() else {
            return .failed("115 登录已失效，请重新登录")
        }
        let sessionID = appState.sessionID
        do {
            try await client.deleteFromRecycleBin(scope.ids, securityKey: key)
            guard sessionID == appState.sessionID else {
                return .failed("登录状态已变更，请重试")
            }
            await finishDelete(scope, key: key)
            return .succeeded
        } catch let fileError as Direct115FileError {
            guard sessionID == appState.sessionID else {
                return .failed("登录状态已变更，请重试")
            }
            if case .needsSecurityKey(let text) = fileError {
                return .wrongKey(text)
            }
            return .failed(fileError.userMessage)
        } catch {
            guard sessionID == appState.sessionID else {
                return .failed("登录状态已变更，请重试")
            }
            return .failed(error.userMessage)
        }
    }

    private func finishDelete(_ scope: RecycleScope, key: String) async {
        rememberedKey = key
        if scope == .everything {
            items = []
            selection = []
            total = 0
            nextOffset = nil
            HUD.show("回收站已清空", .success)
        } else {
            let count = scope.ids.count
            remove(Set(scope.ids))
            HUD.show("已彻底删除 \(count) 项", .success)
        }
        await load(silent: true)
    }

    /// 115 提示需要安全密钥时让用户输入，其他错误直接说明原因
    private func askForKeyOrReport(_ failure: Error, scope: RecycleScope, usedRememberedKey: Bool) {
        if let fileError = failure as? Direct115FileError, case .needsSecurityKey(let text) = fileError {
            if usedRememberedKey { rememberedKey = "" }
            let notice = usedRememberedKey ? (text.isEmpty ? "已记住的安全密钥已失效，请重新输入。" : text) : ""
            let summary = scopeSummary(for: scope)
            Task {
                // 确认弹窗收起或刚结束动画时稍作缓冲，再平滑弹出输入面板
                try? await Task.sleep(nanoseconds: 250_000_000)
                keyRequest = RecycleKeyRequest(
                    scope: scope,
                    itemCount: summary.count,
                    containsFolder: summary.containsFolder,
                    initialNotice: notice
                )
            }
        } else {
            problem = failure.userMessage
        }
    }

    private func scopeSummary(for scope: RecycleScope) -> (count: Int, containsFolder: Bool) {
        switch scope {
        case .everything:
            return (max(total, items.count), items.contains { $0.isDirectory })
        case .selected(let ids):
            let idSet = Set(ids)
            let chosen = items.filter { idSet.contains($0.id) }
            return (ids.count, chosen.contains { $0.isDirectory })
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
            if !silent { self.error = error.userMessage }
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
                if sessionID == appState.sessionID { HUD.show(error.userMessage, .error) }
            }
            loadingMore = false
        }
    }
}

// MARK: - 安全密钥

/// 115 开启了安全密钥时，彻底删除需要输入 6 位数字密钥。只在当前页面生命周期内记住，不会持久化保存。
struct SecurityKeySheet: View {
    let request: RecycleKeyRequest
    let onSubmit: (String) async -> SecurityKeySubmission

    @State private var key = ""
    @State private var revealed = false
    @State private var submitting = false
    @State private var errorMessage: String
    @State private var shakeFailed = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: RecycleKeyRequest, onSubmit: @escaping (String) async -> SecurityKeySubmission) {
        self.request = request
        self.onSubmit = onSubmit
        _errorMessage = State(initialValue: request.initialNotice)
    }

    private var canConfirm: Bool { key.count == 6 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                inputField
                digitProgress
                if !errorMessage.isEmpty {
                    errorNotice
                }
                confirmButton
            }
            .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .topTrailing) {
            SheetCloseButton()
                .disabled(submitting)
                .padding(.top, Theme.Space.md)
                .padding(.trailing, Theme.Space.md)
                .accessibilityIdentifier("library.recycle.key.cancel")
        }
        .background(Theme.surface.ignoresSafeArea())
        .designSheet()
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(submitting)
        .animation(reduceMotion ? nil : Motion.smooth, value: errorMessage.isEmpty)
        .task {
            // 等弹层过渡动画完成后再聚焦键盘，避免弹出过程中与键盘动画打架或失焦
            try? await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 400_000_000)
            if !Task.isCancelled && !submitting {
                focused = true
            }
        }
    }

    // MARK: 版面

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(icon: .key)
                .font(.scaled(22, weight: Theme.iconWeight))
                .foregroundStyle(Theme.danger)
                .frame(width: 48, height: 48)
                .background(Theme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.bottom, Theme.Space.xs)
                .accessibilityHidden(true)
            Text("输入安全密钥")
                .font(.scaled(18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(scopeDescription)
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var scopeDescription: String {
        switch request.scope {
        case .everything:
            if request.itemCount > 0 {
                return "即将永久清空回收站全部 \(request.itemCount) 项，请输入 115 的 6 位数字安全密钥。"
            }
            return "即将永久清空回收站，请输入 115 的 6 位数字安全密钥。"
        case .selected:
            let extra = request.containsFolder ? "（含文件夹内文件）" : ""
            return "即将永久删除所选 \(request.itemCount) 项\(extra)，请输入 115 的 6 位数字安全密钥。"
        }
    }

    private var inputField: some View {
        let hasError = !errorMessage.isEmpty
        return HStack(spacing: 0) {
            // 左侧清除键或等宽占位，保证居中的密钥输入视觉对称
            Group {
                if !key.isEmpty && !submitting {
                    Button {
                        Haptics.tap()
                        key = ""
                        errorMessage = ""
                        focused = true
                    } label: {
                        Image(icon: .clear)
                            .font(.scaled(16, weight: Theme.iconWeight))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除密钥")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }

            Group {
                if revealed {
                    TextField("", text: $key, prompt: Text("6 位数字密钥").font(Theme.Typo.row).foregroundColor(Theme.textMuted))
                } else {
                    SecureField("", text: $key, prompt: Text("6 位数字密钥").font(Theme.Typo.row).foregroundColor(Theme.textMuted))
                }
            }
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(submit)
            .focused($focused)
            .disabled(submitting)
            .multilineTextAlignment(.center)
            .font(.scaled(22, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .onChange(of: key) { value in
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                if digits != value { key = digits }
                if !digits.isEmpty && !errorMessage.isEmpty { errorMessage = "" }
            }
            .accessibilityLabel("安全密钥")
            .accessibilityValue("已输入 \(key.count) 位，共 6 位")
            .accessibilityIdentifier("library.recycle.key.field")

            Button {
                Haptics.tap()
                let wasFocused = focused
                revealed.toggle()
                if wasFocused {
                    Task { @MainActor in
                        await Task.yield()
                        focused = true
                    }
                }
            } label: {
                Image(icon: revealed ? .hidden : .eye)
                    .font(.scaled(16, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submitting)
            .accessibilityLabel(revealed ? "隐藏安全密钥" : "显示安全密钥")
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(minHeight: 52)
        .fieldChrome(focused: focused && !hasError, enabled: !submitting)
        .overlay {
            if hasError {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.danger, lineWidth: Theme.Stroke.rule)
            }
        }
        .failureShake(shakeFailed)
        .padding(.top, Theme.Space.lg + Theme.Space.xs)
    }

    private var digitProgress: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    let filled = index < key.count
                    Capsule()
                        .fill(filled ? (canConfirm ? Theme.success : Theme.accent) : Theme.track)
                        .frame(width: filled ? 18 : 12, height: 4)
                }
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: key.count)
            Text("\(key.count)/6")
                .font(Theme.Typo.caption.monospacedDigit())
                .foregroundStyle(canConfirm ? Theme.success : Theme.textTertiary)
        }
        .padding(.top, Theme.Space.sm + 2)
        .accessibilityHidden(true)
    }

    private var errorNotice: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(icon: .alert)
                .font(.scaled(14, weight: Theme.iconWeight))
            Text(errorMessage)
                .font(Theme.Typo.meta)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.top, Theme.Space.md)
        .transition(.opacity)
        .accessibilityIdentifier("library.recycle.key.error")
    }

    private var confirmButton: some View {
        Button(action: submit) {
            HStack(spacing: Theme.Space.sm) {
                if submitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textMuted)
                }
                Text(confirmTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DestructiveActionStyle())
        .disabled(!canConfirm || submitting)
        .padding(.top, Theme.Space.lg + Theme.Space.xs)
        .accessibilityIdentifier("library.recycle.key.confirm")
    }

    private var confirmTitle: String {
        switch request.scope {
        case .everything: return submitting ? "正在清空回收站…" : "清空回收站"
        case .selected: return submitting ? "正在彻底删除…" : "彻底删除"
        }
    }

    // MARK: 提交

    private func submit() {
        guard canConfirm, !submitting else { return }
        let entered = key
        submitting = true
        shakeFailed = false
        errorMessage = ""
        Task {
            let outcome = await onSubmit(entered)
            guard !Task.isCancelled else { return }
            submitting = false
            switch outcome {
            case .succeeded:
                dismiss()
            case .wrongKey(let message):
                errorMessage = message.isEmpty ? "安全密钥错误，请重新输入" : message
                key = ""
                Haptics.warning()
                shakeFailed = true
                focused = true
            case .failed(let message):
                errorMessage = message.isEmpty ? "操作没有完成，请重试" : message
                Haptics.warning()
                shakeFailed = true
            }
        }
    }
}
