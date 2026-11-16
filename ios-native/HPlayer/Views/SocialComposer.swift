import SwiftUI
import UIKit

/// 输入层要发什么：弹幕，或者一条评论（可能是回复某条）
enum SocialComposerTarget: Identifiable, Equatable {
    case danmaku
    case comment(vid: Int, replyTo: AnimeComment?)

    var id: String {
        switch self {
        case .danmaku: return "danmaku"
        case .comment(let vid, let reply): return "comment-\(vid)-\(reply?.id ?? "")"
        }
    }
}

/// 跟踪输入层对应键盘的弹起与收起，保证键盘一旦收起输入栏也随之关闭，
/// 同时保护「发送中」以及「字数不足 / 发送失败叫回键盘」等短暂过渡，避免误关或漏关。
@MainActor
final class SocialComposerKeyboardTracker: ObservableObject {
    @Published private(set) var overlap: CGFloat = 0
    @Published private(set) var isSending = false
    private(set) var keyboardSeen = false
    private(set) var keyboardVisible = false
    private(set) var isClosing = false

    var onAutoClose: (() -> Void)?

    /// 记录出现过的最大软键盘高度，用于兜底识别只发 frame 归零、未发 willHide 的场景，
    /// 同时避开仅 ~44pt 的外接硬件键盘快捷栏。
    private var maxOverlapSeen: CGFloat = 0
    private var isHoldingOpen = false
    private var pendingHide = false
    private var holdGeneration = 0
    private var hideCheckTask: Task<Void, Never>?
    private var holdExpiryTask: Task<Void, Never>?

    private let hideConfirmDelayNs: UInt64
    private let frameHideConfirmDelayNs: UInt64
    private let holdOpenDurationNs: UInt64

    init(
        hideConfirmDelayNs: UInt64 = 80_000_000,
        frameHideConfirmDelayNs: UInt64 = 160_000_000,
        holdOpenDurationNs: UInt64 = 600_000_000
    ) {
        self.hideConfirmDelayNs = hideConfirmDelayNs
        self.frameHideConfirmDelayNs = frameHideConfirmDelayNs
        self.holdOpenDurationNs = holdOpenDurationNs
    }

    func handleKeyboardWillShow(endFrame: CGRect? = nil, containerBottom: CGFloat? = nil, duration: Double = 0.25) {
        keyboardSeen = true
        keyboardVisible = true
        pendingHide = false
        hideCheckTask?.cancel()
        hideCheckTask = nil
        if let endFrame, let containerBottom {
            let next = max(0, containerBottom - endFrame.minY)
            maxOverlapSeen = max(maxOverlapSeen, next)
            setOverlap(next, duration: duration)
        }
    }

    func handleKeyboardDidShow() {
        keyboardSeen = true
        keyboardVisible = true
        pendingHide = false
        hideCheckTask?.cancel()
        hideCheckTask = nil
        clearHoldOpen()
    }

    func handleKeyboardWillChangeFrame(endFrame: CGRect, containerBottom: CGFloat, duration: Double = 0.25) {
        handleKeyboardOverlapChanged(max(0, containerBottom - endFrame.minY), duration: duration)
    }

    func handleKeyboardOverlapChanged(_ next: CGFloat, duration: Double = 0.25) {
        let clamped = max(0, next)
        setOverlap(clamped, duration: duration)
        if clamped > 0 {
            maxOverlapSeen = max(maxOverlapSeen, clamped)
            keyboardSeen = true
            keyboardVisible = true
            pendingHide = false
            hideCheckTask?.cancel()
            hideCheckTask = nil
        } else if maxOverlapSeen > 80 && keyboardVisible {
            keyboardVisible = false
            pendingHide = true
            scheduleHideCheck(delayNs: frameHideConfirmDelayNs)
        }
    }

    func handleKeyboardWillHide(duration: Double = 0.25) {
        keyboardVisible = false
        setOverlap(0, duration: duration)
        guard keyboardSeen else { return }
        pendingHide = true
        scheduleHideCheck(delayNs: hideConfirmDelayNs)
    }

    func handleKeyboardDidHide() {
        keyboardVisible = false
        overlap = 0
        guard keyboardSeen else { return }
        pendingHide = true
        triggerCloseIfNeeded()
    }

    func beginSending() {
        isSending = true
    }

    func endSending(succeeded: Bool) {
        isSending = false
        if succeeded {
            _ = beginClosing()
            return
        }
        if !isHoldingOpen {
            triggerCloseIfNeeded()
        }
    }

    func beginHoldOpen() {
        holdGeneration += 1
        let generation = holdGeneration
        isHoldingOpen = true
        pendingHide = false
        hideCheckTask?.cancel()
        hideCheckTask = nil
        holdExpiryTask?.cancel()
        holdExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.holdOpenDurationNs ?? 600_000_000)
            guard let self, !Task.isCancelled, self.holdGeneration == generation else { return }
            self.isHoldingOpen = false
            // 若在保护期内用户主动收起了键盘且未再弹回，保护期一结束就顺势收起输入栏
            self.triggerCloseIfNeeded()
        }
    }

    func beginClosing() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        pendingHide = false
        isHoldingOpen = false
        cancel()
        return true
    }

    func cancel() {
        hideCheckTask?.cancel()
        hideCheckTask = nil
        holdExpiryTask?.cancel()
        holdExpiryTask = nil
    }

    private func setOverlap(_ value: CGFloat, duration: Double) {
        guard abs(overlap - value) > 0.5 else { return }
        if duration > 0 {
            withAnimation(.easeOut(duration: duration)) { overlap = value }
        } else {
            overlap = value
        }
    }

    private func clearHoldOpen() {
        holdGeneration += 1
        isHoldingOpen = false
        holdExpiryTask?.cancel()
        holdExpiryTask = nil
    }

    private func scheduleHideCheck(delayNs: UInt64) {
        hideCheckTask?.cancel()
        hideCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self, !Task.isCancelled else { return }
            self.triggerCloseIfNeeded()
        }
    }

    private func triggerCloseIfNeeded() {
        guard pendingHide,
              keyboardSeen,
              !isClosing,
              !isSending,
              !isHoldingOpen,
              !keyboardVisible,
              beginClosing() else { return }
        onAutoClose?()
    }
}

/// 盖在页面上的输入层：半透明遮罩（点一下收起）+ 贴在键盘上方的一条输入栏。
/// 弹幕多一个「Aa」：点开选颜色。发得太频繁时服务端要验证码，输入栏上面会多一行算术题。
/// 宿主要把它放在会避让键盘的容器里（外层不要 ignoresSafeArea），键盘弹起时输入栏才会跟着上去。
struct SocialComposer: View {
    let target: SocialComposerTarget
    var danmaku: DanmakuStore?
    /// 发弹幕时读当前播放进度
    var currentTime: () -> Double = { 0 }
    /// 播放器窗口固定深色，竖屏浅色模式下要显式给浅色；nil 跟随环境
    var scheme: ColorScheme? = nil
    let onClose: () -> Void

    @ObservedObject private var account = AnimeAccount.shared
    @AppStorage(DanmakuPrefs.sendColor) private var colorIndex = 0
    @StateObject private var tracker = SocialComposerKeyboardTracker()
    @State private var text = ""
    @State private var error = ""
    @State private var showStyle = false
    @State private var captcha: AnimeCaptcha?
    @State private var captchaLoading = false
    @State private var answer = ""
    @FocusState private var focused: Bool

    private var isDanmaku: Bool { target == .danmaku }
    private var limit: Int { isDanmaku ? 50 : 300 }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 服务端要求评论、弹幕都至少 3 个字
    private var canSend: Bool {
        trimmed.count >= 3 && trimmed.count <= limit && !tracker.isSending
            && (captcha == nil || !answer.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var placeholder: String {
        switch target {
        case .danmaku: return "发个弹幕见证当下"
        case .comment(_, let reply):
            if let reply { return "回复 \(reply.userName)" }
            return "说点什么…"
        }
    }

    private var selectedColor: UInt32 {
        DanmakuPrefs.sendColors.indices.contains(colorIndex) ? DanmakuPrefs.sendColors[colorIndex] : DanmakuPrefs.sendColors[0]
    }

    var body: some View {
        // 自己读安全区（含键盘）：播放器在独立窗口里、外层又铺满了整块屏幕，不能指望宿主替它避让键盘
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .bottom) {
                // 点一下或往下一划都收起；contentShape 保证整块遮罩都接得到手势
                Color.black.opacity(Theme.Opacity.soft)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12).onEnded { value in
                            if value.translation.height > 24 { close() }
                        }
                    )
                    .accessibilityLabel("收起输入框")
                    .accessibilityAddTraits(.isButton)
                bar(insets: EdgeInsets(top: insets.top, leading: insets.leading,
                                       bottom: max(insets.bottom, tracker.overlap), trailing: insets.trailing))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let info = Self.keyboardGeometry(from: note)
                tracker.handleKeyboardWillShow(endFrame: info.frame,
                                               containerBottom: proxy.frame(in: .global).maxY,
                                               duration: info.duration)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                tracker.handleKeyboardDidShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let info = Self.keyboardGeometry(from: note)
                guard let end = info.frame else { return }
                // 键盘的位置是屏幕坐标；这一层铺满整个窗口，用自己在屏幕上的下沿减去键盘上沿就是被盖住的高度
                tracker.handleKeyboardWillChangeFrame(endFrame: end,
                                                      containerBottom: proxy.frame(in: .global).maxY,
                                                      duration: info.duration)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                let info = Self.keyboardGeometry(from: note)
                tracker.handleKeyboardWillHide(duration: info.duration)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                tracker.handleKeyboardDidHide()
            }
        }
        .ignoresSafeArea()
        .modifier(ComposerScheme(scheme: scheme))
        .onAppear {
            tracker.onAutoClose = { performClose() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !tracker.isClosing else { return }
                focused = true
            }
        }
        .onDisappear {
            tracker.onAutoClose = nil
            tracker.cancel()
        }
    }

    private func bar(insets: EdgeInsets) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDanmaku && showStyle { colorRow.transition(.opacity) }
            if captcha != nil || captchaLoading {
                CaptchaField(captcha: captcha, loading: captchaLoading, answer: $answer, onRefresh: loadCaptcha,
                             identifier: "composer.captcha")
                    .transition(.opacity)
            }
            if !error.isEmpty {
                Text(error)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                if isDanmaku {
                    Button {
                        withAnimation(Motion.snappy) { showStyle.toggle() }
                    } label: {
                        Image(icon: .textStyle)
                            .font(.scaled(17, weight: Theme.iconWeight))
                            .foregroundStyle(showStyle ? Theme.accent : Theme.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(Theme.tileTint, in: Circle())
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .accessibilityLabel("弹幕颜色")
                    .accessibilityIdentifier("composer.style")
                }
                HStack(alignment: .bottom, spacing: 6) {
                    textField
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("composer.text")
                    if isDanmaku || trimmed.count > limit - 40 {
                        Text("\(trimmed.count)/\(limit)")
                            .font(Theme.Typo.caption.monospacedDigit())
                            .foregroundStyle(trimmed.count > limit ? Theme.warning : Theme.textTertiary)
                            .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(Theme.inputFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 1 : Theme.Stroke.hairline)
                }
                Button(action: send) {
                    Group {
                        if tracker.isSending {
                            ProgressView().controlSize(.small).tint(Theme.onPrimary)
                        } else {
                            Text("发送")
                        }
                    }
                    .font(Theme.Typo.meta.weight(.semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 60, height: 40)
                    .background(canSend ? Theme.primaryAction : Theme.textMuted, in: Capsule())
                }
                .buttonStyle(.pressable(scale: 0.95))
                .disabled(!canSend)
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .padding(.bottom, insets.bottom)
        .background(Theme.surface)
        .overlay(alignment: .top) { Theme.rule.frame(height: Theme.Stroke.hairline) }
        .animation(Motion.smooth, value: error)
        .animation(Motion.smooth, value: captcha)
    }

    private var colorRow: some View {
        HStack(spacing: 12) {
            Text("颜色")
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.textSecondary)
            ForEach(DanmakuPrefs.sendColors.indices, id: \.self) { index in
                let selected = index == colorIndex
                Button {
                    Haptics.select()
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(DanmakuOverlay.color(DanmakuPrefs.sendColors[index]))
                        .frame(width: 26, height: 26)
                        .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline) }
                        .padding(3)
                        .overlay { Circle().strokeBorder(selected ? Theme.textPrimary : Color.clear, lineWidth: 2) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.colorNames[index])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private static let colorNames = ["白色", "粉色", "橙色", "绿色", "蓝色", "紫色"]

    private static func keyboardGeometry(from note: Notification) -> (frame: CGRect?, duration: Double) {
        let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        let rawDuration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let duration = max(0, rawDuration ?? 0.25)
        return (frame, duration)
    }

    /// 弹幕只有一行：用单行输入框，键盘上的「发送」才是真的发送（多行输入框按回车只会插一个换行，
    /// 一行高的框里看起来就是字没了、框也收不掉）。评论可以写几行，回车同样当发送，见下面的 onChange。
    @ViewBuilder
    private var textField: some View {
        if isDanmaku {
            TextField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: text) { value in
                    guard value.contains("\n") else { return }
                    text = value.replacingOccurrences(of: "\n", with: "")
                    submit()
                }
        }
    }

    /// 键盘上的「发送」：能发就发；什么都没写就收起；字数不够提示一下，键盘留着继续写
    private func submit() {
        if canSend {
            send()
        } else if trimmed.isEmpty {
            close()
        } else {
            if trimmed.count < 3 { error = "至少写 3 个字" }
            keepEditing(forceHold: isDanmaku || !tracker.keyboardVisible)
        }
    }

    /// 让键盘留着（或弹回来）。按键盘「发送」时系统会先把键盘收掉，这里稍等并重新把焦点要回来
    private func keepEditing(forceHold: Bool) {
        if forceHold { tracker.beginHoldOpen() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !tracker.isClosing else { return }
            guard !tracker.keyboardVisible || !focused else { return }
            if focused {
                // 系统刚收起键盘时 @FocusState 可能仍滞留在 true，先清再置才能真正重新拉起键盘
                focused = false
                DispatchQueue.main.async {
                    guard !tracker.isClosing else { return }
                    focused = true
                }
            } else {
                focused = true
            }
        }
    }

    private func close() {
        guard tracker.beginClosing() else { return }
        performClose()
    }

    private func performClose() {
        focused = false
        // 先让键盘真正收起，下一轮再拿掉这一层。输入框还在焦点上就被整层移除时，
        // 键盘可能留在屏幕上、没有任何东西能再收起它（横屏播放器在独立窗口里尤其容易遇到）
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.async { onClose() }
    }

    private func loadCaptcha() {
        captchaLoading = true
        captcha = nil
        Task {
            defer { captchaLoading = false }
            captcha = try? await account.commentCaptcha()
        }
    }

    private func send() {
        guard canSend else { return }
        error = ""
        tracker.beginSending()
        let content = trimmed
        Task {
            var succeeded = false
            defer { tracker.endSending(succeeded: succeeded) }
            do {
                switch target {
                case .danmaku:
                    try await danmaku?.send(text: content, color: selectedColor, at: currentTime(),
                                            captcha: captcha, answer: answer)
                case .comment(let vid, let reply):
                    try await AnimeSocial.postComment(vid: vid, text: content, replyTo: reply, captcha: captcha, answer: answer)
                    let mine = AnimeComment(localID: 0, userName: account.user?.displayName ?? "我",
                                            content: content, replyTo: reply?.userName ?? "")
                    AnimeSocial.announce(mine, vid: vid)
                }
                succeeded = true
                Haptics.success()
                text = ""
                close()
            } catch {
                Haptics.warning()
                if AnimeSocial.needsCaptcha(error) && captcha == nil {
                    self.error = "发得有点快，先答一下验证码"
                } else {
                    self.error = error.localizedDescription
                }
                answer = ""
                if captcha != nil || AnimeSocial.needsCaptcha(error) { loadCaptcha() }
                // 键盘可能在发送时收起了：叫回来，失败原因显示在输入栏上面，改一改或点空白处收起
                keepEditing(forceHold: !tracker.keyboardVisible)
            }
        }
    }
}

/// 播放器里的输入层按播放页的外观给定；别处跟随 App 外观
private struct ComposerScheme: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}
