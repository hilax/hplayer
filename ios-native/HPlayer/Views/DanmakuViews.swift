import SwiftUI

// MARK: - 弹幕叠层

/// 画在视频上面的弹幕。每帧用 Canvas 画，播放时钟在两次 currentTime 更新之间插值。
struct DanmakuOverlay: View {
    @ObservedObject var store: DanmakuStore
    /// 传进来只是为了暂停时拖动进度也能重画
    let time: Double
    let playing: Bool
    let rate: Double

    @AppStorage(DanmakuPrefs.area) private var area = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var opacity = 0.9
    @AppStorage(DanmakuPrefs.scale) private var scale = 1.0
    @AppStorage(DanmakuPrefs.speed) private var speed = 1.0

    var body: some View {
        if store.enabled && !store.placed.isEmpty {
            TimelineView(.animation(minimumInterval: nil, paused: !playing)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size, now: store.clock(at: timeline.date, playing: playing, rate: rate))
                }
            }
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Double) {
        let fontSize = DanmakuPrefs.baseFontSize * CGFloat(max(scale, 0.5)) * (size.width < 500 ? 0.82 : 1)
        let laneHeight = fontSize * 1.45
        let top: CGFloat = size.width < 500 ? 6 : 14
        let lanes = max(1, min(DanmakuPrefs.laneSlots, Int((size.height * CGFloat(area) - top) / laneHeight)))
        let pointsPerSecond = Double(DanmakuPrefs.baseSpeed) * max(speed, 0.3)
        // 最长的弹幕从右边进到左边出去需要的时间（按 600 点宽估算）
        let lifetime = (Double(size.width) + 600) / pointsPerSecond
        let items = store.placed
        var index = Self.lowerBound(items, time: now - lifetime)
        let font = Font.system(size: fontSize, weight: .semibold)
        while index < items.count {
            let entry = items[index]
            index += 1
            if entry.time > now { break }
            guard entry.lane < lanes else { continue }
            let x = Double(size.width) - (now - entry.time) * pointsPerSecond
            let y = top + CGFloat(entry.lane) * laneHeight + laneHeight / 2
            let text = context.resolve(Text(entry.item.text).font(font).foregroundColor(Self.color(entry.item.color)))
            let width = text.measure(in: CGSize(width: 2000, height: laneHeight)).width
            guard x + Double(width) > 0 else { continue }
            let shadow = context.resolve(Text(entry.item.text).font(font).foregroundColor(.black.opacity(0.75)))
            context.draw(shadow, at: CGPoint(x: x + 1, y: Double(y) + 1), anchor: .leading)
            context.draw(text, at: CGPoint(x: x, y: Double(y)), anchor: .leading)
        }
    }

    private static func lowerBound(_ items: [PlacedDanmaku], time: Double) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 接口给的是 ARGB 整数；有的只给 RGB（透明度位是 0），一律按不透明处理。
    static func color(_ argb: UInt32?) -> Color {
        guard let argb else { return .white }
        let red = Double((argb >> 16) & 0xFF) / 255
        let green = Double((argb >> 8) & 0xFF) / 255
        let blue = Double(argb & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - 开关按钮

/// 「弹」字开关：开着是实心胶囊，关着是描边加斜杠。
struct DanmakuGlyph: View {
    let enabled: Bool
    var size: CGFloat = 13
    var tint: Color = .white

    var body: some View {
        Text("弹")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(enabled ? Color.black : tint)
            .frame(width: size * 1.75, height: size * 1.55)
            .background {
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .fill(enabled ? tint : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .stroke(tint, lineWidth: 1.4)
            }
            .overlay {
                if !enabled {
                    Rectangle()
                        .fill(tint)
                        .frame(width: 1.6, height: size * 2)
                        .rotationEffect(.degrees(-45))
                }
            }
    }
}

// MARK: - 弹幕设置

struct DanmakuSettingsSheet: View {
    @ObservedObject var store: DanmakuStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DanmakuPrefs.area) private var area = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var opacity = 0.9
    @AppStorage(DanmakuPrefs.scale) private var scale = 1.0
    @AppStorage(DanmakuPrefs.speed) private var speed = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示弹幕", isOn: $store.enabled)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("danmaku.settings.enabled")
                } footer: {
                    Text(store.loadedCount > 0 ? "本集已加载 \(store.loadedCount) 条弹幕" : "弹幕按播放进度分段加载")
                }
                Section("显示区域") {
                    Picker("显示区域", selection: $area) {
                        Text("1/4").tag(0.25)
                        Text("半屏").tag(0.5)
                        Text("3/4").tag(0.75)
                        Text("全屏").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("danmaku.settings.area")
                }
                Section("外观") {
                    sliderRow("不透明度", value: $opacity, range: 0.2...1, text: "\(Int(opacity * 100))%")
                    sliderRow("字号", value: $scale, range: 0.7...1.5, text: String(format: "%.1f×", scale))
                    sliderRow("速度", value: $speed, range: 0.6...1.6, text: String(format: "%.1f×", speed))
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onChange(of: speed) { _ in store.relayout() }
        .onChange(of: scale) { _ in store.relayout() }
        .presentationDetents([.medium, .large])
        .designScreen("danmaku-settings")
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
                .tint(Theme.accent)
        }
    }
}

// MARK: - 竖屏信息区：简介 | 评论

enum PlayerInfoTab: String, CaseIterable, Identifiable {
    case intro, comments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .intro: return "简介"
        case .comments: return "评论"
        }
    }
}

struct PlayerInfoTabBar: View {
    @Binding var selection: PlayerInfoTab
    var danmaku: DanmakuStore?
    var onDanmakuSettings: () -> Void = {}
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 22) {
            ForEach(PlayerInfoTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    Haptics.select()
                    withAnimation(Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 5) {
                        Text(tab.title)
                            .font(.system(size: 15, weight: selection == tab ? .bold : .medium))
                            .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.textSecondary)
                        ZStack {
                            Capsule().fill(Color.clear).frame(width: 18, height: 3)
                            if selection == tab {
                                Capsule()
                                    .fill(Theme.prismGradient)
                                    .frame(width: 18, height: 3)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("player.info.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
            if let danmaku {
                DanmakuTabControls(store: danmaku, onSettings: onDanmakuSettings)
            }
        }
        .padding(.horizontal, 16)
        .background(alignment: .bottom) {
            Theme.hairline.frame(height: 0.5)
        }
    }
}

private struct DanmakuTabControls: View {
    @ObservedObject var store: DanmakuStore
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Haptics.tap()
                store.enabled.toggle()
            } label: {
                DanmakuGlyph(enabled: store.enabled, size: 12, tint: Theme.textPrimary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.enabled ? "关闭弹幕" : "打开弹幕")
            .accessibilityIdentifier("player.danmaku.toggle")
            Button(action: onSettings) {
                Image(systemName: AppIcon.tune.name)
                    .font(.system(size: 16, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("弹幕设置")
            .accessibilityIdentifier("player.danmaku.settings")
        }
    }
}

// MARK: - 评论

@MainActor
struct AnimeCommentsView: View {
    let vid: Int
    var bottomInset: CGFloat = 0

    private enum Sort: String, CaseIterable, Identifiable {
        case hot, latest
        var id: String { rawValue }
        var title: String { self == .hot ? "最热" : "最新" }
    }

    @State private var sort: Sort = .hot
    @State private var pinned: [AnimeComment] = []
    @State private var hot: [AnimeComment] = []
    @State private var latest: [AnimeComment] = []
    @State private var page = 0
    @State private var exhausted = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error = ""
    @State private var unsupported = false
    @State private var loadedVid: Int?

    private var visible: [AnimeComment] {
        let body = sort == .hot ? (hot.isEmpty ? latest : hot) : latest
        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + body.filter { !pinnedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset + 28)
        }
        .scrollIndicators(.hidden)
        .task(id: vid) { await loadFirst() }
        .accessibilityIdentifier("player.comments")
    }

    private var header: some View {
        HStack {
            Text(visible.isEmpty ? "评论" : "评论 · \(visible.count)\(exhausted ? "" : "+")")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(Sort.allCases) { option in
                    Button {
                        Haptics.select()
                        sort = option
                    } label: {
                        Text(option.title)
                            .font(.system(size: 12, weight: sort == option ? .bold : .medium))
                            .foregroundStyle(sort == option ? Theme.onPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(sort == option ? Theme.primaryAction : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.comments.sort.\(option.rawValue)")
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.surfaceRaised))
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if loading && visible.isEmpty {
            HStack {
                Spacer()
                ProgressView().tint(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 40)
        } else if visible.isEmpty {
            stateMessage
        } else {
            ForEach(visible) { comment in
                AnimeCommentRow(comment: comment)
                    .onAppear {
                        if sort == .latest, comment.id == latest.last?.id { Task { await loadMore() } }
                    }
            }
            footer
        }
    }

    private var stateMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: AppIcon.comment.name)
                .font(.system(size: 26, weight: Theme.iconWeight))
                .foregroundStyle(Theme.textTertiary)
            Text(stateTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(stateDetail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if !error.isEmpty {
                Button("重试") { Task { await loadFirst(force: true) } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                    .accessibilityIdentifier("player.comments.retry")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var stateTitle: String {
        if !error.isEmpty { return "评论加载失败" }
        if unsupported { return "评论格式暂不支持" }
        return "还没有评论"
    }

    private var stateDetail: String {
        if !error.isEmpty { return error }
        if unsupported { return "接口返回了评论，但字段和预期不一致，后续版本会适配" }
        return "发表评论功能即将开放"
    }

    @ViewBuilder
    private var footer: some View {
        if sort == .latest {
            HStack {
                Spacer()
                if loadingMore {
                    ProgressView().tint(Theme.textSecondary)
                } else if exhausted {
                    Text("没有更多评论了")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .frame(height: 48)
        }
    }

    private func loadFirst(force: Bool = false) async {
        guard force || loadedVid != vid else { return }
        loadedVid = vid
        pinned = []; hot = []; latest = []; page = 0; exhausted = false; error = ""; unsupported = false
        guard !InterfacePreview.active else { exhausted = true; return }
        loading = true
        defer { loading = false }
        async let topPage = try? AnimeClient.shared.fetchComments(.top, vid: vid)
        async let hotPage = try? AnimeClient.shared.fetchComments(.hot, vid: vid)
        let first: AnimeCommentPage
        do {
            first = try await AnimeClient.shared.fetchComments(.list, vid: vid, page: 1)
        } catch {
            _ = await (topPage, hotPage)
            self.error = error.localizedDescription
            return
        }
        let (top, hotList) = await (topPage, hotPage)
        guard loadedVid == vid else { return }
        pinned = top?.items ?? []
        hot = hotList?.items ?? []
        latest = first.items
        page = 1
        exhausted = first.rawCount < 20
        let raw = first.rawCount + (top?.rawCount ?? 0) + (hotList?.rawCount ?? 0)
        unsupported = raw > 0 && visible.isEmpty
    }

    private func loadMore() async {
        guard !loading, !loadingMore, !exhausted, page > 0 else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        guard let result = try? await AnimeClient.shared.fetchComments(.list, vid: vid, page: next) else { return }
        let known = Set(latest.map(\.id))
        latest += result.items.filter { !known.contains($0.id) }
        page = next
        exhausted = result.rawCount < 20
    }
}

private struct AnimeCommentRow: View {
    let comment: AnimeComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(comment.userName.prefix(1)))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(avatarColor))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.userName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if comment.pinned { badge("置顶", color: Theme.accent) }
                    if comment.hot { badge("热评", color: Theme.rating) }
                    Spacer(minLength: 0)
                    if !comment.time.isEmpty {
                        Text(comment.time)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(comment.content)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    Label("\(comment.likes)", systemImage: AppIcon.like.name)
                    if comment.replies > 0 {
                        Label("\(comment.replies) 条回复", systemImage: AppIcon.comment.name)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Theme.hairline.frame(height: 0.5).padding(.leading, 42)
        }
        .accessibilityElement(children: .combine)
    }

    private var avatarColor: Color {
        let colors = Theme.prismColors
        let hash = comment.userName.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[hash % colors.count].opacity(0.85)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 0.8))
    }
}

// MARK: - 横屏控制条上的弹幕开关

struct PlayerDanmakuButton: View {
    @ObservedObject var store: DanmakuStore

    var body: some View {
        Button {
            Haptics.tap()
            store.enabled.toggle()
        } label: {
            DanmakuGlyph(enabled: store.enabled, size: 12)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.enabled ? "关闭弹幕" : "打开弹幕")
        .accessibilityIdentifier("playback.danmaku")
    }
}
