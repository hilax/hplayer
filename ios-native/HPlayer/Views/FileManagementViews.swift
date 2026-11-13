import SwiftUI
import UIKit

// MARK: - 危险操作的主按钮

/// 删除这类危险操作的主按钮：红色胶囊 + 白字（和其他按钮同一套状态）。
struct DestructiveActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, kind: .destructive, minHeight: 50)
    }
}

// MARK: - 轻提示

/// 屏幕底部短暂出现的提示条：已移动、已加入下载……
private struct ToastModifier: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = text {
                    Text(message)
                        .font(Theme.Typo.row.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.vertical, Theme.Space.md)
                        .floatingSurface()
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("library.toast")
                        .task(id: message) {
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            guard !Task.isCancelled else { return }
                            text = nil
                        }
                }
            }
            .animation(Motion.smooth, value: text)
    }
}

extension View {
    /// 底部轻提示：给 `text` 赋值就会出现，几秒后自己消失。
    func toast(_ text: Binding<String?>) -> some View {
        modifier(ToastModifier(text: text))
    }
}

/// 操作进行中的遮罩：挡住重复点击，并告诉用户在做什么。
struct OperationOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
            HStack(spacing: Theme.Space.md) {
                ProgressView().tint(Theme.textSecondary)
                Text(text).font(Theme.Typo.row.weight(.medium)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.lg)
            .floatingSurface()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.operation")
    }
}

// MARK: - 底部操作栏

/// 多选之后浮在底部的操作栏：移动、复制、重命名、信息、下载、加入首页、删除。
struct FileActionDock: View {
    let summary: FileSelectionSummary
    var busy = false
    let canRename: Bool
    let canInspect: Bool
    let canDownload: Bool
    let canAddToHome: Bool
    let onMove: () -> Void
    let onCopy: () -> Void
    let onRename: () -> Void
    let onInfo: () -> Void
    let onDownload: () -> Void
    let onAddToHome: () -> Void
    let onDelete: () -> Void

    private var hasSelection: Bool { summary.count > 0 }

    var body: some View {
        VStack(spacing: 6) {
            Text(hasSelection ? summary.text : "点按项目进行选择")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("library.dock.summary")
            HStack(spacing: 0) {
                action(.moveTo, "移动", "library.dock.move", enabled: hasSelection, perform: onMove)
                action(.copy, "复制", "library.dock.copy", enabled: hasSelection, perform: onCopy)
                action(.rename, "重命名", "library.dock.rename", enabled: canRename, perform: onRename)
                action(.info, "信息", "library.dock.info", enabled: canInspect, perform: onInfo)
                action(.download, "下载", "library.dock.download", enabled: canDownload, perform: onDownload)
                action(.addToLibrary, "加入首页", "library.dock.home", enabled: canAddToHome, perform: onAddToHome)
                action(.trash, "删除", "library.dock.delete", enabled: hasSelection, danger: true, perform: onDelete)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .padding(.horizontal, 4)
        .floatingSurface(cornerRadius: Theme.Radius.sheet)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.dock")
    }

    private func action(_ icon: AppIcon, _ title: String, _ identifier: String, enabled: Bool,
                        danger: Bool = false, perform: @escaping () -> Void) -> some View {
        let active = enabled && !busy
        let iconColor: Color = !active ? Theme.textTertiary : (danger ? Theme.danger : Theme.accent)
        let titleColor: Color = !active ? Theme.textTertiary : (danger ? Theme.danger : Theme.textPrimary)
        return Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: icon.name)
                    .font(.system(size: 20, weight: Theme.iconWeight))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .disabled(!active)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 起名弹层（新建文件夹、重命名）

struct NamePromptSheet: View {
    let title: String
    var hint = ""
    let confirmTitle: String
    let placeholder: String
    let onConfirm: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, hint: String = "", confirmTitle: String, placeholder: String,
         initial: String = "", onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.hint = hint
        self.confirmTitle = confirmTitle
        self.placeholder = placeholder
        self.onConfirm = onConfirm
        _text = State(initialValue: initial)
    }

    private var cleaned: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalidCharacters: Bool { cleaned.contains("/") || cleaned.contains("\\") }
    private var canConfirm: Bool { !cleaned.isEmpty && !invalidCharacters }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button("取消") { dismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("library.name.cancel")
                    Spacer()
                }
            }
            .frame(height: 44)

            TextField(placeholder, text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(confirm)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay(alignment: .trailing) {
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: AppIcon.clear.name)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }
                }
                .accessibilityIdentifier("library.name.field")

            if invalidCharacters {
                DesignNotice(symbol: AppIcon.alert.name, text: "名称里不能包含 / 或 \\", warning: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !hint.isEmpty {
                DesignNotice(text: hint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(confirmTitle, action: confirm)
                .buttonStyle(PrimaryActionStyle())
                .disabled(!canConfirm)
                .accessibilityIdentifier("library.name.confirm")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            focused = true
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        let value = cleaned
        dismiss()
        onConfirm(value)
    }
}

// MARK: - 删除确认

struct DeleteConfirmSheet: View {
    let files: [P115File]
    /// 其中已经在 HPlayer 资料库里的视频数（包括所选文件夹下记录过的）
    let libraryVideoCount: Int
    @Binding var removeFromLibrary: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var summary: FileSelectionSummary { FileSelectionSummary(files) }
    private var shown: [P115File] { Array(files.prefix(5)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    fileList
                    if libraryVideoCount > 0 { libraryOption }
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            buttons
        }
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var explanation: String {
        if summary.folders > 0 {
            return "文件会移入 115 回收站，可在回收站中还原。\n夹内的文件会一并移入。"
        }
        return "文件会移入 115 回收站，可在回收站中还原。"
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: AppIcon.trash.name)
                .font(.system(size: 24, weight: Theme.iconWeight))
                .foregroundStyle(Theme.danger)
                .frame(width: 48, height: 48)
                .background(Theme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.bottom, 6)
            Text("删除 \(files.count) 项？")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(for file: P115File) -> AppIcon {
        if file.isDir { return .folder }
        return file.isVideo ? .video : .file
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(shown) { file in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: file).name)
                        .font(.system(size: 14, weight: Theme.iconWeight))
                        .foregroundStyle(file.isDir ? Theme.accent : Theme.textSecondary)
                        .frame(width: 18)
                    Text(file.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(file.isDir ? "文件夹" : formatSize(file.size))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(height: 38)
                if file.id != shown.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
            if files.count > shown.count {
                Text("另有 \(files.count - shown.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .padding(.top, 16)
    }

    private var libraryOption: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("同时从 HPlayer 资料库移除")
                    .font(.system(size: 14, weight: .medium))
                Text("其中 \(libraryVideoCount) 个视频已入库，海报与观看记录将一并清理")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("同时从 HPlayer 资料库移除", isOn: $removeFromLibrary)
                .labelsHidden()
                .tint(Theme.gold)
                .accessibilityIdentifier("library.delete.librarySwitch")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .padding(.top, 12)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button("移入回收站") {
                dismiss()
                onConfirm()
            }
            .buttonStyle(DestructiveActionStyle())
            .accessibilityIdentifier("library.delete.confirm")
            Button("取消") { dismiss() }
                .buttonStyle(SecondaryActionStyle())
                .accessibilityIdentifier("library.delete.cancel")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

// MARK: - 移动 / 复制到

enum FileDestinationMode: String, Identifiable {
    case move
    case copy

    var id: String { rawValue }
    var title: String { self == .move ? "移动到" : "复制到" }
    var verb: String { self == .move ? "移动" : "复制" }
}

/// 选择目标文件夹：从当前所在的位置开始，逐级进入；可以新建文件夹；在「移动到」和「复制到」之间切换。
struct FolderPickerSheet: View {
    let client: Direct115Client?
    let files: [P115File]
    /// 所选文件现在所在的文件夹；移动到这里是没有意义的
    let sourceFolderID: String
    let onConfirm: (FileDestinationMode, Crumb) -> Void

    @State private var mode: FileDestinationMode
    @State private var trail: [Crumb]
    @State private var folders: [P115File]
    @State private var loading: Bool
    @State private var error = ""
    @State private var showNewFolder = false
    @State private var skipFirstLoad: Bool
    @Environment(\.dismiss) private var dismiss

    init(client: Direct115Client?, files: [P115File], sourceFolderID: String, trail: [Crumb],
         mode: FileDestinationMode, preloadedFolders: [P115File]? = nil,
         onConfirm: @escaping (FileDestinationMode, Crumb) -> Void) {
        self.client = client
        self.files = files
        self.sourceFolderID = sourceFolderID
        self.onConfirm = onConfirm
        _mode = State(initialValue: mode)
        _trail = State(initialValue: trail.isEmpty ? [Crumb(cid: "0", name: "网盘")] : trail)
        _folders = State(initialValue: preloadedFolders ?? [])
        _loading = State(initialValue: preloadedFolders == nil)
        _skipFirstLoad = State(initialValue: preloadedFolders != nil)
    }

    private var current: Crumb { trail.last ?? Crumb(cid: "0", name: "网盘") }
    private var summary: FileSelectionSummary { FileSelectionSummary(files) }
    private var blockedIDs: Set<String> { Set(files.filter { $0.isDir }.map { $0.id }) }
    private var pathText: String { FileOperationText.pathLabel(trail) }
    private var alreadyHere: Bool { mode == .move && current.cid == sourceFolderID }
    private var canConfirm: Bool { !alreadyHere && !blockedIDs.contains(current.cid) }

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
            summaryCard
            breadcrumb
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

    // MARK: 版面

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.picker.cancel")
            Spacer()
            Text("选择目标文件夹")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("新建") { showNewFolder = true }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("library.picker.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(minHeight: 56)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach([FileDestinationMode.move, FileDestinationMode.copy]) { option in
                let selected = mode == option
                Button {
                    if !selected {
                        Haptics.select()
                        mode = option
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(selected ? Theme.surfaceHigh : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
                .accessibilityIdentifier("library.picker.mode.\(option.rawValue)")
            }
        }
        .padding(3)
        .background(Theme.pageBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var summaryCard: some View {
        HStack(spacing: 10) {
            Image(systemName: AppIcon.folder.name)
                .font(.system(size: 16, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
            Text("将 \(summary.count) 项（\(summary.kindsText)）\(mode.verb)到所选位置")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: AppIcon.forward.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    let last = index == trail.count - 1
                    Button {
                        if !last {
                            Haptics.tap()
                            trail = Array(trail.prefix(index + 1))
                        }
                    } label: {
                        Text(index == 0 ? "网盘" : crumb.name)
                            .font(.system(size: 13, weight: last ? .semibold : .regular))
                            .foregroundStyle(last ? Theme.accent : Theme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .frame(maxWidth: 170, minHeight: 28)
                            .background(last ? Theme.tileTint : Theme.surfaceRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.picker.crumb.\(index)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 12)
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
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        pickerRow(folder)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func pickerRow(_ folder: P115File) -> some View {
        let blocked = blockedIDs.contains(folder.id)
        return Button {
            guard !blocked else { return }
            Haptics.tap()
            trail.append(Crumb(cid: folder.id, name: folder.name))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: AppIcon.folder.name)
                    .font(.system(size: 18, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(folder.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if blocked {
                    Text("已选中，不可作为目标")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Image(systemName: AppIcon.forward.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .opacity(blocked ? 0.45 : 1)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 64)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityIdentifier("library.picker.folder.\(folder.id)")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: AppIcon.folder.name)
                    .font(.system(size: 13, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.accent)
                Text("目标位置：")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                Text(pathText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.picker.destination")
            if alreadyHere {
                DesignNotice(text: "所选项目已经在这个文件夹里了，请换一个位置。", warning: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(SecondaryActionStyle())
                    .frame(width: 112)
                Button("\(mode.verb)到此处") {
                    let destination = current
                    let chosen = mode
                    dismiss()
                    onConfirm(chosen, destination)
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(!canConfirm)
                .accessibilityIdentifier("library.picker.confirm")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    // MARK: 加载与新建

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

// MARK: - 文件信息

struct FileInfoSheet: View {
    let file: P115File
    let client: Direct115Client?
    let inLibrary: Bool
    let onPlay: (() -> Void)?
    let onRename: () -> Void
    let onDownload: (() -> Void)?
    var preloaded: Direct115FileInfo?

    @State private var info: Direct115FileInfo?
    @State private var loading = true
    @State private var error = ""
    @State private var copied = ""
    @Environment(\.dismiss) private var dismiss

    init(file: P115File, client: Direct115Client?, inLibrary: Bool, onPlay: (() -> Void)?,
         onRename: @escaping () -> Void, onDownload: (() -> Void)?, preloaded: Direct115FileInfo? = nil) {
        self.file = file
        self.client = client
        self.inLibrary = inLibrary
        self.onPlay = onPlay
        self.onRename = onRename
        self.onDownload = onDownload
        self.preloaded = preloaded
        _info = State(initialValue: preloaded)
        _loading = State(initialValue: preloaded == nil)
    }

    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                titleBlock
                detailCard
                actionRow
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("文件信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("library.info.done")
            }
        }
        .task {
            guard preloaded == nil else { return }
            await load()
        }
        .designScreen("file-info")
    }

    // MARK: 版面

    private var placeholderIcon: some View {
        Image(systemName: file.isDir ? AppIcon.folder.name : (file.isVideo ? AppIcon.video.name : AppIcon.file.name))
            .font(.system(size: 34, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textSecondary)
    }

    private var hero: some View {
        Theme.surfaceRaised
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .overlay {
                if file.isDir {
                    FolderGlyph().frame(width: 76, height: 60)
                } else if let url = URL(string: file.thumbUrl), !file.thumbUrl.isEmpty {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholderIcon
                        }
                    }
                } else {
                    placeholderIcon
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.name)
                .font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.info.name")
            HStack(spacing: 6) {
                if inLibrary { badge("已入库", highlighted: true) }
                if file.isDir { badge("文件夹") }
                if !file.extensionLabel.isEmpty { badge(file.extensionLabel) }
                if !file.isDir, file.size > 0 { badge(DownloadFormat.bytes(Int64(file.size))) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func badge(_ text: String, highlighted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(highlighted ? Theme.tileTint : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private struct Row: Identifiable {
        let id: String
        let label: String
        let value: String
        var detail = ""
        var mono = false
        var copyable = false
    }

    private func timeText(_ date: Date?) -> String {
        date.map { Self.timeFormatter.string(from: $0) } ?? "—"
    }

    private var rows: [Row] {
        var result: [Row] = []
        if let info, !info.location.isEmpty {
            result.append(Row(id: "location", label: "位置", value: info.location.joined(separator: " › ")))
        }
        let sizeValue: String
        if let info, !info.sizeText.isEmpty {
            sizeValue = info.sizeText
        } else {
            sizeValue = file.size > 0 ? DownloadFormat.bytes(Int64(file.size)) : "—"
        }
        var sizeDetail = ""
        if !file.isDir, file.size > 0 {
            let grouped = Self.groupedFormatter.string(from: NSNumber(value: file.size)) ?? "\(file.size)"
            sizeDetail = "\(grouped) 字节"
        }
        result.append(Row(id: "size", label: "大小", value: sizeValue, detail: sizeDetail))
        if let info, file.isDir {
            result.append(Row(id: "content", label: "包含", value: "\(info.fileCount) 个文件，\(info.folderCount) 个文件夹"))
        }
        if let info {
            result.append(Row(id: "modified", label: "修改时间", value: timeText(info.modifiedAt)))
            result.append(Row(id: "created", label: file.isDir ? "创建时间" : "上传时间", value: timeText(info.createdAt)))
        }
        let code = info?.pickCode.isEmpty == false ? (info?.pickCode ?? "") : file.pickCode
        if !file.isDir, !code.isEmpty {
            result.append(Row(id: "pickcode", label: "提取码", value: code, mono: true, copyable: true))
        }
        let hash = info?.sha1.isEmpty == false ? (info?.sha1 ?? "") : file.sha1
        if !file.isDir, !hash.isEmpty {
            result.append(Row(id: "sha1", label: "SHA1", value: hash.uppercased(), mono: true, copyable: true))
        }
        return result
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            let list = rows
            ForEach(list) { row in
                detailRow(row)
                if row.id != list.last?.id {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取详细信息").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            if !error.isEmpty {
                DesignNotice(symbol: AppIcon.alert.name, text: error, warning: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func detailRow(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.value)
                    .font(row.mono ? .system(size: 12, design: .monospaced) : .system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if row.copyable { copyButton(row.value) }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.info.\(row.id)")
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.success()
            copied = value
        } label: {
            Image(systemName: copied == value ? AppIcon.check.name : AppIcon.copy.name)
                .font(.system(size: 14, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel("复制")
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if let onPlay {
                Button {
                    onPlay()
                } label: {
                    Label("播放", systemImage: AppIcon.play.name)
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("library.info.play")
            }
            Button {
                onRename()
            } label: {
                Label("重命名", systemImage: AppIcon.rename.name)
            }
            .buttonStyle(SecondaryActionStyle())
            .accessibilityIdentifier("library.info.rename")
            if let onDownload {
                Button {
                    onDownload()
                } label: {
                    Label("下载", systemImage: AppIcon.download.name)
                }
                .buttonStyle(SecondaryActionStyle())
                .accessibilityIdentifier("library.info.download")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: 加载

    private func load() async {
        guard let client else {
            loading = false
            error = "请先登录 115"
            return
        }
        do {
            let result = try await client.fileInfo(id: file.id)
            guard !Task.isCancelled else { return }
            info = result
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }
}
