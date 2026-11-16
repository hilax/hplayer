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

/// 解析自系统键盘通知的时长与曲线。iOS 键盘私有 curve == 7 为过阻尼弹簧，
/// 用相同参数才能让输入框贴着键盘同步推起和落下，不会慢半拍。
struct KeyboardMotion: Equatable {
    let duration: Double
    let curve: Int?

    static let `default` = KeyboardMotion(duration: 0.25, curve: 7)

    var animation: Animation? {
        guard duration > 0 else { return nil }
        if curve == nil || curve == 7 {
            return .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
        }
        switch curve {
        case 0: return .easeInOut(duration: duration)
        case 1: return .easeIn(duration: duration)
        case 2: return .easeOut(duration: duration)
        case 3: return .linear(duration: duration)
        default: return .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
        }
    }
}

/// 跟踪输入栏对应的键盘位置与显示状态：
/// - 弹幕浮层（autoCloseOnHide = true）：键盘一收起就跟着滑下并关闭，同时保护「发送中」与「失败叫回键盘」过渡。
/// - 评论常驻底栏（autoCloseOnHide = false）：键盘弹出同步顶起底栏，键盘收起同步退回页面底部并通知清理临时状态。
@MainActor
final class SocialComposerKeyboardTracker: ObservableObject {
    @Published private(set) var overlap: CGFloat = 0
    @Published private(set) var isSending = false
    @Published private(set) var isDismissing = false
    @Published private(set) var hideCount = 0
    private(set) var keyboardSeen = false
    private(set) var keyboardVisible = false
    private(set) var isClosing = false

    let autoCloseOnHide: Bool
    var onAutoClose: (() -> Void)?
    var onFinishDismiss: (() -> Void)?
    var onKeyboardHidden: (() -> Void)?

    /// 记录出现过的最大软键盘高度，用于兜底识别只发 frame 归零、未发 willHide 的场景，
    /// 同时避开仅 ~44pt 的外接硬件键盘快捷栏。
    private var maxOverlapSeen: CGFloat = 0
    private var keyboardDidHideSinceShow = false
    private var isHoldingOpen = false
    private var pendingHide = false
    private var holdGeneration = 0
    private var hideCheckTask: Task<Void, Never>?
    private var holdExpiryTask: Task<Void, Never>?
    private var dismissFinishTask: Task<Void, Never>?

    private let hideConfirmDelayNs: UInt64
    private let frameHideConfirmDelayNs: UInt64
    private let holdOpenDurationNs: UInt64
    private let dismissFinishTimeoutNs: UInt64

    init(
        autoCloseOnHide: Bool = true,
        hideConfirmDelayNs: UInt64 = 80_000_000,
        frameHideConfirmDelayNs: UInt64 = 160_000_000,
        holdOpenDurationNs: UInt64 = 600_000_000,
        dismissFinishTimeoutNs: UInt64 = 280_000_000
    ) {
        self.autoCloseOnHide = autoCloseOnHide
        self.hideConfirmDelayNs = hideConfirmDelayNs
        self.frameHideConfirmDelayNs = frameHideConfirmDelayNs
        self.holdOpenDurationNs = holdOpenDurationNs
        self.dismissFinishTimeoutNs = dismissFinishTimeoutNs
    }

    static func geometry(from note: Notification) -> (frame: CGRect?, motion: KeyboardMotion) {
        let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        let rawDuration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let duration = max(0, rawDuration ?? 0.25)
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        return (frame, KeyboardMotion(duration: duration, curve: curve))
    }

    func handleKeyboardWillShow(
        endFrame: CGRect? = nil,
        containerBottom: CGFloat? = nil,
        motion: KeyboardMotion = .default
    ) {
        keyboardSeen = true
        keyboardVisible = true
        keyboardDidHideSinceShow = false
        pendingHide = false
        hideCheckTask?.cancel()
        hideCheckTask = nil
        if let endFrame, let containerBottom {
            let next = max(0, containerBottom - endFrame.minY)
            maxOverlapSeen = max(maxOverlapSeen, next)
            setOverlap(next, motion: motion)
        }
    }

    func handleKeyboardWillShow(endFrame: CGRect? = nil, containerBottom: CGFloat? = nil, duration: Double) {
        handleKeyboardWillShow(
            endFrame: endFrame,
            containerBottom: containerBottom,
            motion: KeyboardMotion(duration: duration, curve: nil)
        )
    }

    func handleKeyboardDidShow() {
        keyboardSeen = true
        keyboardVisible = true
        keyboardDidHideSinceShow = false
        pendingHide = false
        hideCheckTask?.cancel()
        hideCheckTask = nil
        clearHoldOpen()
    }

    func handleKeyboardWillChangeFrame(
        endFrame: CGRect,
        containerBottom: CGFloat,
        motion: KeyboardMotion = .default
    ) {
        handleKeyboardOverlapChanged(max(0, containerBottom - endFrame.minY), motion: motion)
    }

    func handleKeyboardWillChangeFrame(endFrame: CGRect, containerBottom: CGFloat, duration: Double) {
        handleKeyboardWillChangeFrame(
            endFrame: endFrame,
            containerBottom: containerBottom,
            motion: KeyboardMotion(duration: duration, curve: nil)
        )
    }

    func handleKeyboardOverlapChanged(_ next: CGFloat, motion: KeyboardMotion = .default) {
        let clamped = max(0, next)
        setOverlap(clamped, motion: motion)
        if clamped > 0 {
            maxOverlapSeen = max(maxOverlapSeen, clamped)
            keyboardSeen = true
            keyboardVisible = true
            keyboardDidHideSinceShow = false
            pendingHide = false
            hideCheckTask?.cancel()
            hideCheckTask = nil
        } else if maxOverlapSeen > 80 && keyboardVisible {
            keyboardVisible = false
            pendingHide = true
            scheduleHideCheck(delayNs: frameHideConfirmDelayNs)
        }
    }

    func handleKeyboardOverlapChanged(_ next: CGFloat, duration: Double) {
        handleKeyboardOverlapChanged(next, motion: KeyboardMotion(duration: duration, curve: nil))
    }

    func handleKeyboardWillHide(motion: KeyboardMotion = .default) {
        keyboardVisible = false
        setOverlap(0, motion: motion)
        guard keyboardSeen else { return }
        pendingHide = true
        scheduleHideCheck(delayNs: hideConfirmDelayNs)
    }

    func handleKeyboardWillHide(duration: Double) {
        handleKeyboardWillHide(motion: KeyboardMotion(duration: duration, curve: nil))
    }

    func handleKeyboardDidHide() {
        keyboardVisible = false
        keyboardDidHideSinceShow = true
        overlap = 0
        if isDismissing {
            finishDismissIfNeeded()
            return
        }
        guard keyboardSeen else { return }
        pendingHide = true
        triggerHideResolutionIfNeeded()
    }

    func beginSending() {
        isSending = true
    }

    func endSending(succeeded: Bool) {
        isSending = false
        if succeeded {
            if autoCloseOnHide { _ = beginClosing() }
            return
        }
        if !isHoldingOpen {
            triggerHideResolutionIfNeeded()
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
            // 若在保护期内用户主动收起了键盘且未再弹回，保护期一结束就顺势完成收起
            self.triggerHideResolutionIfNeeded()
        }
    }

    func beginClosing() -> Bool {
        guard !isClosing else { return false }
        isClosing = true
        pendingHide = false
        isHoldingOpen = false
        cancelPendingChecks()
        if autoCloseOnHide && keyboardSeen && !keyboardDidHideSinceShow {
            isDismissing = true
            dismissFinishTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.dismissFinishTimeoutNs ?? 280_000_000)
                guard let self, !Task.isCancelled else { return }
                self.finishDismissIfNeeded()
            }
        }
        return true
    }

    func cancel() {
        cancelPendingChecks()
        dismissFinishTask?.cancel()
        dismissFinishTask = nil
    }

    private func cancelPendingChecks() {
        hideCheckTask?.cancel()
        hideCheckTask = nil
        holdExpiryTask?.cancel()
        holdExpiryTask = nil
    }

    private func setOverlap(_ value: CGFloat, motion: KeyboardMotion) {
        guard abs(overlap - value) > 0.5 else { return }
        if let animation = motion.animation {
            withAnimation(animation) { overlap = value }
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
            self.triggerHideResolutionIfNeeded()
        }
    }

    private func finishDismissIfNeeded() {
        guard isDismissing else { return }
        isDismissing = false
        dismissFinishTask?.cancel()
        dismissFinishTask = nil
        onFinishDismiss?()
    }

    private func triggerHideResolutionIfNeeded() {
        guard pendingHide,
              keyboardSeen,
              !isClosing,
              !isSending,
              !isHoldingOpen,
              !keyboardVisible else { return }
        if autoCloseOnHide {
            guard beginClosing() else { return }
            onAutoClose?()
        } else {
            pendingHide = false
            hideCount += 1
            onKeyboardHidden?()
        }
    }
}

/// 给视图绑定系统键盘通知到 `SocialComposerKeyboardTracker`。
private struct KeyboardTrackingModifier: ViewModifier {
    @ObservedObject var tracker: SocialComposerKeyboardTracker
    let containerBottom: CGFloat

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let info = SocialComposerKeyboardTracker.geometry(from: note)
                tracker.handleKeyboardWillShow(endFrame: info.frame,
                                               containerBottom: containerBottom,
                                               motion: info.motion)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                tracker.handleKeyboardDidShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let info = SocialComposerKeyboardTracker.geometry(from: note)
                guard let end = info.frame else { return }
                // 键盘位置是屏幕坐标；用容器下沿减去键盘上沿即可算出被盖住的精确高度
                tracker.handleKeyboardWillChangeFrame(endFrame: end,
                                                      containerBottom: containerBottom,
                                                      motion: info.motion)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                let info = SocialComposerKeyboardTracker.geometry(from: note)
                tracker.handleKeyboardWillHide(motion: info.motion)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                tracker.handleKeyboardDidHide()
            }
    }
}

extension View {
    func trackKeyboard(_ tracker: SocialComposerKeyboardTracker, containerBottom: CGFloat) -> some View {
        modifier(KeyboardTrackingModifier(tracker: tracker, containerBottom: containerBottom))
    }
}

/// 弹幕和评论共用的输入条：胶囊输入框、字数提示、弹幕颜色选择、回复提示、验证码和发送按钮。
struct SocialInputBar: View {
    let target: SocialComposerTarget
    var danmaku: DanmakuStore? = nil
    var currentTime: () -> Double = { 0 }
    @ObservedObject var tracker: SocialComposerKeyboardTracker
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var requiresSignIn = false
    var onRequireSignIn: () -> Void = {}
    var onCancelReply: (() -> Void)? = nil
    var onDidSend: () -> Void = {}
    var onEmptySubmit: () -> Void = {}

    @ObservedObject private var account = AnimeAccount.shared
    @AppStorage(DanmakuPrefs.sendColor) private var colorIndex = 0
    @State private var error = ""
    @State private var showStyle = false
    @State private var captcha: AnimeCaptcha?
    @State private var captchaLoading = false
    @State private var answer = ""

    private var isDanmaku: Bool { target == .danmaku }
    private var limit: Int { isDanmaku ? 50 : 300 }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var replyUserName: String? {
        if case .comment(_, let reply) = target { return reply?.userName }
        return nil
    }

    /// 服务端要求评论、弹幕都至少 3 个字
    private var canSend: Bool {
        !requiresSignIn && trimmed.count >= 3 && trimmed.count <= limit && !tracker.isSending
            && (captcha == nil || !answer.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var placeholder: String {
        if requiresSignIn { return "登录后参与评论" }
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
        VStack(alignment: .leading, spacing: 10) {
            if isDanmaku && showStyle { colorRow.transition(.opacity) }
            if let replyUserName {
                HStack(spacing: 6) {
                    Text("回复 \(replyUserName)")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if let onCancelReply {
                        Button(action: onCancelReply) {
                            Image(icon: .close)
                                .font(.scaled(11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消回复")
                    }
                }
                .transition(.opacity)
            }
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
                        .disabled(requiresSignIn)
                        .focused(focused)
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
                        .strokeBorder(focused.wrappedValue ? Theme.accent : Theme.hairline,
                                      lineWidth: focused.wrappedValue ? 1 : Theme.Stroke.hairline)
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
            .overlay {
                if requiresSignIn {
                    Button(action: onRequireSignIn) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("登录后参与评论")
                    .accessibilityIdentifier("player.comments.compose")
                }
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .animation(Motion.smooth, value: error)
        .animation(Motion.smooth, value: captcha)
        .onChange(of: target.id) { _ in error = "" }
        .onChange(of: tracker.hideCount) { _ in
            error = ""
            if trimmed.isEmpty {
                captcha = nil
                answer = ""
            }
        }
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
            onEmptySubmit()
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
            guard !tracker.keyboardVisible || !focused.wrappedValue else { return }
            if focused.wrappedValue {
                // 系统刚收起键盘时 @FocusState 可能仍滞留在 true，先清再置才能真正重新拉起键盘
                focused.wrappedValue = false
                DispatchQueue.main.async {
                    guard !tracker.isClosing else { return }
                    focused.wrappedValue = true
                }
            } else {
                focused.wrappedValue = true
            }
        }
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
                captcha = nil
                answer = ""
                onDidSend()
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

/// 盖在页面上的输入层（用于竖屏/横屏发弹幕）：半透明遮罩 + 贴着键盘同步推起和滑落的输入栏。
struct SocialComposer: View {
    let target: SocialComposerTarget
    var danmaku: DanmakuStore? = nil
    /// 发弹幕时读当前播放进度
    var currentTime: () -> Double = { 0 }
    /// 播放器窗口固定深色，竖屏浅色模式下要显式给浅色；nil 跟随环境
    var scheme: ColorScheme? = nil
    let onClose: () -> Void

    @StateObject private var tracker = SocialComposerKeyboardTracker(autoCloseOnHide: true)
    @State private var text = ""
    @State private var maskShown = false
    @FocusState private var focused: Bool

    var body: some View {
        // 自己读安全区（含键盘）：播放器在独立窗口里、外层又铺满了整块屏幕，不能指望宿主替它避让键盘
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let bottomPad = max(insets.bottom, tracker.overlap)
            ZStack(alignment: .bottom) {
                // 遮罩随开启柔和变暗，关闭退场时立即放开点击并同步淡出
                Color.black.opacity(maskShown && !tracker.isDismissing ? Theme.Opacity.soft : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12).onEnded { value in
                            if value.translation.height > 24 { close() }
                        }
                    )
                    .animation(.easeOut(duration: 0.18), value: maskShown)
                    .animation(.easeOut(duration: 0.2), value: tracker.isDismissing)
                    .accessibilityLabel("收起输入框")
                    .accessibilityAddTraits(.isButton)

                VStack(spacing: 0) {
                    SocialInputBar(
                        target: target,
                        danmaku: danmaku,
                        currentTime: currentTime,
                        tracker: tracker,
                        text: $text,
                        focused: $focused,
                        onDidSend: close,
                        onEmptySubmit: close
                    )
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    Color.clear.frame(height: bottomPad)
                }
                .background(Theme.surface)
                .overlay(alignment: .top) { Theme.rule.frame(height: Theme.Stroke.hairline) }
                .offset(y: tracker.isDismissing ? 32 : 0)
                .opacity(tracker.isDismissing ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: tracker.isDismissing)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .trackKeyboard(tracker, containerBottom: proxy.frame(in: .global).maxY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(!tracker.isDismissing)
        .accessibilityHidden(tracker.isDismissing)
        .modifier(ComposerScheme(scheme: scheme))
        .onAppear {
            tracker.onAutoClose = { performClose() }
            tracker.onFinishDismiss = { DispatchQueue.main.async { onClose() } }
            focused = true
            DispatchQueue.main.async {
                guard !tracker.isClosing else { return }
                if !focused { focused = true }
            }
            withAnimation(.easeOut(duration: 0.18)) { maskShown = true }
        }
        .onDisappear {
            tracker.onAutoClose = nil
            tracker.onFinishDismiss = nil
            tracker.cancel()
        }
    }

    private func close() {
        guard tracker.beginClosing() else { return }
        performClose()
    }

    private func performClose() {
        focused = false
        // 先让键盘真正收起，再拿掉这一层。输入框还在焦点上就被整层移除时，
        // 键盘可能留在屏幕上、没有任何东西能再收起它（横屏播放器在独立窗口里尤其容易遇到）
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if !tracker.isDismissing {
            DispatchQueue.main.async { onClose() }
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
