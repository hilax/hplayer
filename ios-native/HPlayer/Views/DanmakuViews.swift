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
            let shadow = context.resolve(Text(entry.item.text).font(font).foregroundColor(.black.opacity(Theme.Opacity.heavy)))
            if entry.item.mine {
                // 自己发的那条：一圈琥珀描边
                let box = CGRect(x: x - 6, y: Double(y) - Double(laneHeight) / 2 + 2, width: Double(width) + 12,
                                 height: Double(laneHeight) - 4)
                context.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.danmakuMine), lineWidth: 1)
            }
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
    /// 打开时的填充色。不传就用 tint 填、黑字（画面上的白色款）；
    /// 信息区的深色字款要传主题色，否则浅色下会填成一块黑底黑字
    var enabledFill: Color? = nil
    /// 打开时「弹」字的颜色（压在 enabledFill 上）
    var enabledTextColor: Color = .white

    private var fill: Color { enabledFill ?? tint }
    private var enabledText: Color { enabledFill == nil ? .black : enabledTextColor }

    var body: some View {
        Text("弹")
            .font(.scaled(size, weight: .bold))
            .foregroundStyle(enabled ? enabledText : tint)
            .frame(width: size * 1.75, height: size * 1.55)
            .background {
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .fill(enabled ? fill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .stroke(enabled ? fill : tint, lineWidth: 1.4)
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

/// 弹幕设置：竖屏播放页自己的底部面板（盖在信息区上，上面的画面露着，改了马上能看到效果）。
///
/// 以前用系统弹出页：iOS 26 的半高弹出页是悬空的玻璃卡片，在播放页的独立窗口里底色发灰透明，
/// 下面还露出一截信息页；拖动时整页变成半透明的灰。现在由播放页自己画，背景不透明、贴底。
struct DanmakuSettingsPanel: View {
    @ObservedObject var store: DanmakuStore
    var bottomInset: CGFloat = 0
    let onClose: () -> Void
    @AppStorage(DanmakuPrefs.area) private var area = 0.5
    @AppStorage(DanmakuPrefs.opacity) private var opacity = 0.9
    @AppStorage(DanmakuPrefs.scale) private var scale = 1.0
    @AppStorage(DanmakuPrefs.speed) private var speed = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var areaSelection

    private static let areas: [(String, Double)] = [("1/4", 0.25), ("半屏", 0.5), ("3/4", 0.75), ("全屏", 1.0)]
    private var isDefault: Bool { area == 0.5 && opacity == 0.9 && scale == 1.0 && speed == 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            enabledCard
            VStack(alignment: .leading, spacing: 18) {
                section("显示区域") { areaPicker }
                section("外观") {
                    VStack(spacing: 18) {
                        DanmakuSliderRow(title: "不透明度", value: $opacity, range: 0.2...1, step: 0.05,
                                         text: "\(Int((opacity * 100).rounded()))%", id: "danmaku.settings.opacity")
                        DanmakuSliderRow(title: "字号", value: $scale, range: 0.7...1.5, step: 0.1,
                                         text: String(format: "%.1f×", scale), id: "danmaku.settings.scale")
                        DanmakuSliderRow(title: "速度", value: $speed, range: 0.6...1.6, step: 0.1,
                                         text: String(format: "%.1f×", speed), id: "danmaku.settings.speed")
                    }
                    .padding(16)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                }
            }
            // 弹幕关着时下面的设置变淡、不能改，一眼看出它们暂时不起作用
            .opacity(store.enabled ? 1 : 0.4)
            .disabled(!store.enabled)
            .animation(reduceMotion ? nil : Motion.snappy, value: store.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, bottomInset + 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 只要上面两个圆角：底边往下多伸出一截，下面的圆角落在屏幕外
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.pageBackground)
                .padding(.bottom, -40)
                .shadow(color: .black.opacity(0.18), radius: 24, y: -4)
        }
        .onChange(of: speed) { _ in store.relayout() }
        .onChange(of: scale) { _ in store.relayout() }
        .designScreen("danmaku-settings")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Theme.ruleStrong)
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("弹幕设置")
                        .font(.scaled(18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(store.loadedCount > 0 ? "本集已加载 \(store.loadedCount) 条弹幕" : "弹幕按播放进度分段加载")
                        .font(.scaled(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                if !isDefault {
                    Button("恢复默认") {
                        Haptics.select()
                        withAnimation(reduceMotion ? nil : Motion.snappy) {
                            area = 0.5; opacity = 0.9; scale = 1.0; speed = 1.0
                        }
                    }
                    .font(.scaled(13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.pressable(scale: 0.95))
                    .accessibilityIdentifier("danmaku.settings.reset")
                    .transition(.opacity)
                }
                Button(action: onClose) {
                    Image(icon: .close)
                        .font(.scaled(13, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceRaised, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable(scale: 0.92))
                .accessibilityLabel("关闭弹幕设置")
                .accessibilityIdentifier("danmaku.settings.close")
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: isDefault)
        }
    }

    private var enabledCard: some View {
        HStack(spacing: 12) {
            DanmakuGlyph(enabled: store.enabled, size: 13, tint: Theme.textPrimary,
                         enabledFill: Theme.primaryAction, enabledTextColor: Theme.onPrimary)
                .accessibilityHidden(true)
            Toggle("显示弹幕", isOn: $store.enabled)
                .font(.scaled(16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accentFill)
                .accessibilityIdentifier("danmaku.settings.enabled")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            content()
        }
    }

    /// 四档等宽分段：选中的一档主操作色（深色下白、浅色下墨黑），在档位之间滑过去
    private var areaPicker: some View {
        HStack(spacing: 0) {
            ForEach(Self.areas, id: \.1) { title, value in
                let selected = abs(area - value) < 0.01
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : Motion.snappy) { area = value }
                } label: {
                    Text(title)
                        .font(.scaled(14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.primaryAction)
                                    .matchedGeometryEffect(id: "area", in: areaSelection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("danmaku.settings.area.\(title)")
            }
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("显示区域")
        .accessibilityIdentifier("danmaku.settings.area")
    }
}

/// 弹幕设置里的一条滑杆：标题和数值一行，下面一条细轨道，已选部分用主文字色（不用琥珀色）
private struct DanmakuSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.scaled(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(text)
                    .font(.scaled(14).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            GeometryReader { proxy in
                let thumb: CGFloat = 22
                let span = max(1, proxy.size.width - thumb)
                let fraction = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                                       / (range.upperBound - range.lowerBound))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 4)
                    Capsule().fill(Theme.textPrimary).frame(width: thumb / 2 + span * fraction, height: 4)
                    Circle()
                        .fill(Theme.surface)
                        .overlay { Circle().strokeBorder(Theme.ruleStrong, lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .frame(width: thumb, height: thumb)
                        .offset(x: span * fraction)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let ratio = Double(min(max((drag.location.x - thumb / 2) / span, 0), 1))
                    let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    let snapped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
                    let clamped = min(max(snapped, range.lowerBound), range.upperBound)
                    if abs(clamped - value) > step / 10 {
                        value = clamped
                        Haptics.select()
                    }
                })
            }
            .frame(height: 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(id)
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
    var onComposeDanmaku: () -> Void = {}
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
                            .font(.scaled(15, weight: selection == tab ? .bold : .medium))
                            .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.textSecondary)
                        ZStack {
                            Capsule().fill(Color.clear).frame(width: 18, height: 3)
                            if selection == tab {
                                // 选中的下划线用主文字色，和标签栏、频道的选中规则一致
                                Capsule()
                                    .fill(Theme.textPrimary)
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
                DanmakuTabControls(store: danmaku, onCompose: onComposeDanmaku, onSettings: onDanmakuSettings)
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
    let onCompose: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onCompose) {
                HStack(spacing: 6) {
                    Image(icon: .danmaku)
                        .font(.scaled(13, weight: Theme.iconWeight))
                    Text("发条弹幕")
                        .font(.scaled(13))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Theme.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.96))
            .accessibilityLabel("发弹幕")
            .accessibilityIdentifier("player.danmaku.compose")
            Button {
                Haptics.tap()
                store.enabled.toggle()
            } label: {
                // 弹幕开着：主操作色（深色下白、浅色下墨黑），不用琥珀色
                DanmakuGlyph(enabled: store.enabled, size: 12, tint: Theme.textPrimary, enabledFill: Theme.primaryAction, enabledTextColor: Theme.onPrimary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.enabled ? "关闭弹幕" : "打开弹幕")
            .accessibilityIdentifier("player.danmaku.toggle")
            Button(action: onSettings) {
                Image(appIconNamed: AppIcon.tune.name)
                    .font(.scaled(16, weight: Theme.iconWeight))
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
    var allowsCompose: Bool = true
    /// 不为空时是「一条评论的全部回复」：上面是这条评论，下面是回复，输入框默认回复它
    var root: AnimeComment? = nil
    /// 打开回复页时直接弹出输入框（点了「回复」进来的）
    var startsReplying = false

    private enum Sort: String, CaseIterable, Identifiable {
        case hot, latest
        var id: String { rawValue }
        var title: String { self == .hot ? "最热" : "最新" }
    }

    @ObservedObject private var account = AnimeAccount.shared
    @ObservedObject private var replyStore = AnimeCommentReplyStore.shared
    @StateObject private var tracker = SocialComposerKeyboardTracker(autoCloseOnHide: false)
    @State private var sort: Sort = .hot
    @State private var pinned: [AnimeComment] = []
    @State private var hot: [AnimeComment] = []
    @State private var latest: [AnimeComment] = []
    /// 自己刚发的，排在最前面
    @State private var mine: [AnimeComment] = []
    @State private var page = 0
    @State private var totalCount: Int?
    @State private var nextMarker: Int?
    @State private var exhausted = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error = ""
    @State private var unsupported = false
    @State private var loadedVid: Int?
    @State private var showSignIn = false
    @State private var draft = ""
    @State private var replyTo: AnimeComment?
    @State private var repliesRequest: AnimeRepliesRequest?
    /// 回复页没拿到完整接口列表时，回退显示内嵌回复并提示
    @State private var repliesPartial = false
    @FocusState private var composerFocused: Bool

    /// 实际回复目标：回复页里没点具体楼中楼时默认回复根评论本身
    private var replyTarget: AnimeComment? { replyTo ?? root }

    /// 发出的回复归属的根评论 ID（供跨列表即时同步预览与计数）
    private var composerRootID: Int? {
        if let root, root.numericID > 0 { return root.numericID }
        if let replyTo, replyTo.numericID > 0 { return replyTo.numericID }
        return nil
    }

    private var visible: [AnimeComment] {
        if let root {
            return replyStore.mergedSubComments(for: root.numericID, fetched: latest)
        }
        let body = sort == .hot ? (hot.isEmpty ? latest : hot) : latest
        let pinnedIDs = Set(pinned.map(\.id))
        return mine + pinned + body.filter { !pinnedIDs.contains($0.id) }
    }

    var body: some View {
        GeometryReader { proxy in
            let active = composerFocused || tracker.keyboardVisible || tracker.overlap > 0
            let restingPad = max(bottomInset - 10, 0)
            let bottomPad = max(restingPad, tracker.overlap)
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, allowsCompose ? (76 + bottomInset) : 28)
                }
                .scrollIndicators(.hidden)

                if allowsCompose {
                    Group {
                        if active {
                            Color.black.opacity(Theme.Opacity.soft)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture(perform: dismissComposer)
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 12).onEnded { value in
                                        if value.translation.height > 24 { dismissComposer() }
                                    }
                                )
                                .transition(.opacity)
                                .accessibilityLabel("收起输入框")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .allowsHitTesting(active)
                    .animation(.easeOut(duration: 0.2), value: active)

                    VStack(spacing: 0) {
                        SocialInputBar(
                            target: .comment(vid: vid, replyTo: replyTarget, rootID: composerRootID),
                            tracker: tracker,
                            text: $draft,
                            focused: $composerFocused,
                            requiresSignIn: needsSignIn,
                            onRequireSignIn: { showSignIn = true },
                            onCancelReply: (replyTo == nil || replyTo?.id == root?.id) ? nil : { replyTo = nil },
                            onDidSend: {
                                replyTo = nil
                                dismissComposer()
                            },
                            onEmptySubmit: dismissComposer
                        )
                        Color.clear.frame(height: bottomPad)
                    }
                    .background {
                        Theme.surface.ignoresSafeArea(edges: .bottom)
                    }
                    .overlay(alignment: .top) { Theme.rule.frame(height: Theme.Stroke.hairline) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .trackKeyboard(tracker, containerBottom: proxy.frame(in: .global).maxY)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 评论区是播放页里的面板：提示贴在面板顶部（底部会被键盘挡住）
        .hudHost(.sheet)
        .task(id: vid) { await loadFirst() }
        .onReceive(NotificationCenter.default.publisher(for: .animeCommentPosted)) { note in
            guard (note.userInfo?["vid"] as? Int) == vid,
                  (note.userInfo?["rootID"] as? Int) == nil,
                  root == nil,
                  let comment = note.userInfo?["comment"] as? AnimeComment else { return }
            if !mine.contains(where: { $0.id == comment.id }) {
                mine.insert(comment, at: 0)
            }
        }
        .onAppear {
            tracker.onKeyboardHidden = {
                composerFocused = false
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    replyTo = nil
                }
            }
        }
        .onDisappear {
            tracker.onKeyboardHidden = nil
            tracker.cancel()
            if composerFocused || tracker.keyboardVisible {
                composerFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .animeSignInSheet(isPresented: $showSignIn)
        .sheet(item: $repliesRequest) { request in
            AnimeRepliesSheet(vid: vid, request: request)
        }
        .task {
            guard startsReplying, root != nil else { return }
            // 等弹出页动画落稳、输入栏就位后再聚焦
            try? await Task.sleep(nanoseconds: 450_000_000)
            compose(nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(root == nil ? "player.comments" : "comments.replies")
    }

    private func openReplies(_ comment: AnimeComment, reply: Bool) {
        guard root == nil else { compose(comment); return }
        repliesRequest = AnimeRepliesRequest(root: comment, startsReplying: reply)
    }

    private var needsSignIn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_COMPOSER_TEST"] == "1" { return false }
        #endif
        return !account.isSignedIn
    }

    private func compose(_ reply: AnimeComment?) {
        guard !needsSignIn else { showSignIn = true; return }
        replyTo = reply ?? root
        composerFocused = true
    }

    private func dismissComposer() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replyTo = nil
        }
    }

    private func like(_ comment: AnimeComment) {
        guard account.isSignedIn else { showSignIn = true; return }
        Task {
            do {
                try await AnimeLikeStore.shared.toggle(comment, vid: vid)
            } catch {
                HUD.show(error.userMessage, .error)
            }
        }
    }

    private var listHeaderTitle: String {
        if let totalCount, totalCount > 0 {
            return "评论 · \(compactCount(totalCount + mine.count))"
        }
        if visible.isEmpty { return "评论" }
        return "评论 · \(visible.count)\(exhausted ? "" : "+")"
    }

    @ViewBuilder
    private var header: some View {
        if let root {
            AnimeCommentRow(comment: root, showsReplies: false,
                            onReply: allowsCompose ? { _ in compose(nil) } : nil,
                            onLike: { like($0) })
            let displayCount = max(totalCount ?? replyStore.totalReplies(for: root), visible.count)
            HStack {
                Text(displayCount > 0 ? "全部回复 · \(compactCount(displayCount))" : "全部回复")
                    .font(.scaled(15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Theme.rule.frame(height: Theme.Stroke.hairline) }
        } else {
            listHeader
        }
    }

    private var listHeader: some View {
        HStack {
            Text(listHeaderTitle)
                .font(.scaled(15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(Sort.allCases) { option in
                    Button {
                        Haptics.select()
                        sort = option
                    } label: {
                        Text(option.title)
                            .font(.scaled(12, weight: sort == option ? .bold : .medium))
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
                AnimeCommentRow(comment: comment,
                                rootCommentID: root?.numericID,
                                onReply: allowsCompose ? { compose($0) } : nil,
                                onLike: { like($0) },
                                onOpenReplies: root == nil ? { openReplies($0, reply: false) } : nil)
                    .onAppear {
                        if (root != nil || sort == .latest), comment.id == latest.last?.id { Task { await loadMore() } }
                    }
            }
            footer
        }
    }

    private var stateMessage: some View {
        VStack(spacing: 10) {
            Image(appIconNamed: AppIcon.comment.name)
                .font(.scaled(26, weight: Theme.iconWeight))
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
        if root != nil { return error.isEmpty ? "还没有回复" : "回复加载失败" }
        if !error.isEmpty { return "评论加载失败" }
        if unsupported { return "评论格式暂不支持" }
        return "还没有评论"
    }

    private var stateDetail: String {
        if !error.isEmpty { return error }
        if root != nil { return allowsCompose ? "点下面的输入框，回复这条评论" : "" }
        if unsupported { return "接口返回了评论，但字段和预期不一致，后续版本会适配" }
        return allowsCompose ? "点下面的输入框，来抢第一条评论" : "来抢第一条评论吧"
    }

    @ViewBuilder
    private var footer: some View {
        if root != nil && repliesPartial {
            Text("暂时只能看到这几条回复")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        } else if sort == .latest || root != nil {
            HStack {
                Spacer()
                if loadingMore {
                    ProgressView().tint(Theme.textSecondary)
                } else if exhausted {
                    Text(root == nil ? "没有更多评论了" : "没有更多回复了")
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
        pinned = []; hot = []; latest = []; mine = []; page = 0; totalCount = nil; nextMarker = nil; exhausted = false; error = ""; unsupported = false; repliesPartial = false
        guard !InterfacePreview.active else { exhausted = true; return }
        if let root {
            totalCount = root.replies > 0 ? root.replies : nil
            loading = true
            defer { loading = false }
            do {
                let first = try await AnimeClient.shared.fetchSubComments(themeCommentID: root.numericID, marker: nil, limit: 20)
                guard loadedVid == vid else { return }
                latest = first.items
                totalCount = first.total ?? totalCount
                nextMarker = first.items.last?.numericID
                exhausted = first.rawCount < 20 || first.items.isEmpty || (first.total != nil && first.items.count >= first.total!)
            } catch {
                guard loadedVid == vid else { return }
                if !root.children.isEmpty {
                    latest = root.children
                    exhausted = true
                    repliesPartial = root.replies > root.children.count
                } else {
                    self.error = error.userMessage
                }
            }
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["HPLAYER_COMPOSER_TEST"] == "1" {
            latest = (1...15).map { index in
                AnimeComment(localID: index, userName: "测试用户\(index)",
                             content: "测试评论第 \(index) 条内容，用于验证评论列表滚动与键盘联动。", replyTo: "")
            }
            exhausted = true
            return
        }
        #endif
        loading = true
        defer { loading = false }
        async let topPage = try? AnimeClient.shared.fetchComments(.top, vid: vid)
        async let hotPage = try? AnimeClient.shared.fetchComments(.hot, vid: vid)
        let first: AnimeCommentPage
        do {
            first = try await AnimeClient.shared.fetchComments(.list, vid: vid, page: 1)
        } catch {
            _ = await (topPage, hotPage)
            self.error = error.userMessage
            return
        }
        let (top, hotList) = await (topPage, hotPage)
        guard loadedVid == vid else { return }
        pinned = top?.items ?? []
        hot = hotList?.items ?? []
        latest = first.items
        page = 1
        totalCount = first.total
        exhausted = first.rawCount < 20 || (first.total != nil && first.items.count >= first.total!)
        let raw = first.rawCount + (top?.rawCount ?? 0) + (hotList?.rawCount ?? 0)
        unsupported = raw > 0 && visible.isEmpty
    }

    private func loadMore() async {
        guard !loading, !loadingMore, !exhausted else { return }
        if let root {
            guard let marker = nextMarker, marker > 0 else { return }
            loadingMore = true
            defer { loadingMore = false }
            guard let result = try? await AnimeClient.shared.fetchSubComments(themeCommentID: root.numericID, marker: marker, limit: 20),
                  loadedVid == vid else { return }
            let known = Set(latest.map(\.id))
            let added = result.items.filter { !known.contains($0.id) && $0.numericID != marker }
            latest += added
            totalCount = result.total ?? totalCount
            let newMarker = result.items.last?.numericID
            if added.isEmpty || newMarker == nil || newMarker == marker || result.rawCount < 20
                || (totalCount != nil && latest.count >= totalCount!) {
                exhausted = true
            } else {
                nextMarker = newMarker
            }
            return
        }
        guard page > 0 else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        guard let result = try? await AnimeClient.shared.fetchComments(.list, vid: vid, page: next),
              loadedVid == vid else { return }
        let known = Set(latest.map(\.id))
        latest += result.items.filter { !known.contains($0.id) }
        page = next
        totalCount = result.total ?? totalCount
        exhausted = result.rawCount < 20 || (totalCount != nil && latest.count >= totalCount!)
    }
}

/// 一条评论：头像、名字和标签、正文；置顶和热评带前几条回复；下面「回复」和点赞。
struct AnimeCommentRow: View {
    let comment: AnimeComment
    /// 回复页顶上的根评论不再重复展示楼内回复预览
    var showsReplies = true
    /// 回复页上下文里的根评论 ID（直回楼主时不重复写「回复 楼主：」）
    var rootCommentID: Int? = nil
    var onReply: ((AnimeComment) -> Void)? = nil
    var onLike: ((AnimeComment) -> Void)? = nil
    /// 点回复预览 / 「N 条回复」打开全部回复
    var onOpenReplies: ((AnimeComment) -> Void)? = nil
    @ObservedObject private var likes = AnimeLikeStore.shared
    @ObservedObject private var replyStore = AnimeCommentReplyStore.shared

    var body: some View {
        let previewItems = showsReplies ? replyStore.mergedPreview(for: comment) : []
        let replyCount = replyStore.totalReplies(for: comment)
        let replyTargetName = comment.displayedReplyTarget(under: rootCommentID)
        let openable = onOpenReplies != nil && comment.numericID > 0

        HStack(alignment: .top, spacing: 10) {
            Text(String(comment.userName.prefix(1)))
                .font(.scaled(13, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceHigh))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.userName)
                        .font(.scaled(13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if !comment.role.isEmpty { badge(comment.role, color: Theme.textSecondary) }
                    if comment.pinned { badge("置顶", color: Theme.accent) }
                    if comment.hot { badge("热评", color: Theme.rating) }
                    Spacer(minLength: 0)
                }
                Group {
                    if replyTargetName.isEmpty {
                        Text(comment.content)
                    } else {
                        Text("回复 ").foregroundColor(Theme.textTertiary)
                            + Text(replyTargetName).foregroundColor(Theme.textSecondary)
                            + Text("：\(comment.content)")
                    }
                }
                .font(.scaled(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                if showsReplies && !previewItems.isEmpty {
                    if openable, let onOpenReplies {
                        Button { onOpenReplies(comment) } label: {
                            repliesPreview(items: previewItems, totalCount: replyCount, openable: true)
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                        .accessibilityHint("查看全部回复")
                        .accessibilityIdentifier("comment.replies.\(comment.id)")
                    } else {
                        repliesPreview(items: previewItems, totalCount: replyCount, openable: false)
                    }
                }
                actions(replyCount: replyCount, hasPreview: !previewItems.isEmpty, openable: openable)
            }
        }
        .padding(.vertical, 12)
    }

    private func repliesPreview(items: [AnimeComment], totalCount: Int, openable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { reply in
                let targetName = reply.displayedReplyTarget(under: comment.numericID)
                Group {
                    if targetName.isEmpty {
                        Text(reply.userName).foregroundColor(Theme.textPrimary).fontWeight(.semibold)
                            + Text("：\(reply.content)").foregroundColor(Theme.textSecondary)
                    } else {
                        Text(reply.userName).foregroundColor(Theme.textPrimary).fontWeight(.semibold)
                            + Text(" 回复 ").foregroundColor(Theme.textTertiary)
                            + Text(targetName).foregroundColor(Theme.textPrimary).fontWeight(.semibold)
                            + Text("：\(reply.content)").foregroundColor(Theme.textSecondary)
                    }
                }
                .font(.scaled(13))
                .lineLimit(2)
            }
            if totalCount > items.count || openable {
                HStack(spacing: 2) {
                    Text(totalCount > items.count ? "共 \(totalCount) 条回复" : "查看回复")
                    if openable { Image(icon: .forward).font(.scaled(10, weight: .semibold)) }
                }
                .font(.scaled(12, weight: .medium))
                .foregroundStyle(openable ? Theme.textSecondary : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }

    private func actions(replyCount: Int, hasPreview: Bool, openable: Bool) -> some View {
        let liked = likes.liked(comment)
        let count = likes.count(comment)
        return HStack(spacing: 16) {
            if !comment.time.isEmpty {
                Text(comment.time)
                    .font(.scaled(12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            if let onReply, comment.numericID > 0 {
                Button("回复") { onReply(comment) }
                    .font(.scaled(12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("comment.reply.\(comment.id)")
            }
            if showsReplies && replyCount > 0 && !hasPreview {
                if openable, let onOpenReplies {
                    Button {
                        onOpenReplies(comment)
                    } label: {
                        HStack(spacing: 2) {
                            Text("\(replyCount) 条回复")
                            Image(icon: .forward).font(.scaled(10, weight: .semibold))
                        }
                    }
                    .font(.scaled(12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("comment.replyCount.\(comment.id)")
                } else {
                    Text("\(replyCount) 条回复")
                        .font(.scaled(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if let onLike, comment.numericID > 0 {
                Button { onLike(comment) } label: {
                    HStack(spacing: 4) {
                        Image(icon: liked ? .likeFill : .like)
                        Text(compactCount(count)).monospacedDigit()
                    }
                    .font(.scaled(13, weight: liked ? .semibold : .regular))
                    .foregroundStyle(liked ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 44, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .bounceSymbol(on: liked)
                .accessibilityLabel(liked ? "取消点赞，\(count) 个赞" : "点赞，\(count) 个赞")
                .accessibilityIdentifier("comment.like.\(comment.id)")
            } else {
                Label(compactCount(count), image: AppIcon.like.name)
                    .font(.scaled(12))
                    .foregroundStyle(Theme.textTertiary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.scaled(10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 0.8))
    }
}

/// 打开一条评论的全部回复；`startsReplying` 是点「回复」进来的，直接弹出输入框
struct AnimeRepliesRequest: Identifiable {
    let root: AnimeComment
    var startsReplying = false
    var id: String { root.id + (startsReplying ? "#reply" : "") }
}

/// 一条评论的全部回复（从评论区、详情页弹出）：游标分页加载全部回复、直接回复楼主或楼中楼、点赞
struct AnimeRepliesSheet: View {
    let vid: Int
    let request: AnimeRepliesRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AnimeCommentsView(vid: vid, root: request.root, startsReplying: request.startsReplying)
                .background(Theme.pageBackground.ignoresSafeArea())
                .navigationTitle("回复")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .accessibilityIdentifier("comments.replies.close")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 横屏控制条上的弹幕开关

/// 横屏底栏倍速旁边的小输入框「发弹幕…」。点它弹出贴着键盘的输入栏；窄屏只放一个图标。
struct DanmakuInputPill: View {
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(icon: .send)
                        .font(.scaled(17, weight: Theme.iconWeight))
                        .frame(width: 44, height: 44)
                } else {
                    Text("发弹幕…")
                        .font(.scaled(13))
                        .foregroundStyle(Color.white.opacity(Theme.Opacity.heavy))
                        .padding(.horizontal, 12)
                        .frame(width: 124, height: 32, alignment: .leading)
                        .background(Color.white.opacity(Theme.Opacity.faint), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.white.opacity(Theme.Opacity.soft), lineWidth: 0.5) }
                        .frame(height: 44)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityLabel("发弹幕")
        .accessibilityIdentifier("playback.danmaku.compose")
    }
}

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
