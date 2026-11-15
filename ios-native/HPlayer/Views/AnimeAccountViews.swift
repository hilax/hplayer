import SwiftUI
import UIKit

// MARK: - 输入框

/// 登录 / 注册里的一个输入框：上方小标签，下方输入区，焦点时 1pt 琥珀边。右边可以放一个附件（显示密码、获取验证码）。
struct AccountField<Accessory: View>: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var content: UITextContentType?
    var identifier = ""
    @ViewBuilder var accessory: () -> Accessory
    @FocusState private var focused: Bool
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Typo.meta.weight(.medium))
                .foregroundStyle(focused ? Theme.accent : Theme.textSecondary)
            HStack(spacing: Theme.Space.sm) {
                Group {
                    if secure && !revealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .focused($focused)
                .keyboardType(keyboard)
                .textContentType(content)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .accessibilityIdentifier(identifier)
                if secure {
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? AppIcon.hidden.name : AppIcon.eye.name)
                            .font(.scaled(16, weight: Theme.iconWeight))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "隐藏密码" : "显示密码")
                }
                accessory()
            }
            .padding(.leading, Theme.Space.md + 2)
            .padding(.trailing, 4)
            .frame(minHeight: 48)
            .fieldChrome(focused: focused)
        }
        .animation(Motion.quick, value: focused)
    }
}

extension AccountField where Accessory == EmptyView {
    init(label: String, placeholder: String, text: Binding<String>, secure: Bool = false,
         keyboard: UIKeyboardType = .default, content: UITextContentType? = nil, identifier: String = "") {
        self.init(label: label, placeholder: placeholder, text: text, secure: secure, keyboard: keyboard,
                  content: content, identifier: identifier) { EmptyView() }
    }
}

/// 图片算术验证码（「6 × 9 = ?」）：左边图片（点一下换一张），右边填答案
struct CaptchaField: View {
    let captcha: AnimeCaptcha?
    let loading: Bool
    @Binding var answer: String
    let onRefresh: () -> Void
    var identifier = "account.captcha"

    var body: some View {
        AccountField(label: "验证码", placeholder: "图中算式的结果", text: $answer, keyboard: .numbersAndPunctuation,
                     identifier: identifier) {
            Button(action: onRefresh) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(Color.white)
                    if let captcha {
                        Image(uiImage: captcha.image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(2)
                    } else if loading {
                        ProgressView().controlSize(.small).tint(Color.gray)
                    } else {
                        Image(systemName: AppIcon.refresh.name)
                            .font(.scaled(14, weight: Theme.iconWeight))
                            .foregroundStyle(Color.gray)
                    }
                }
                .frame(width: 112, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.96))
            .accessibilityLabel("换一张验证码")
        }
    }
}

// MARK: - 登录 / 注册

/// 登录和注册：从底部弹出，顶部切换。登录、注册、发验证码前都要答一道图片算术题。
/// 账号默认用邮箱，下面一行文字可以换成手机号。
struct AnimeSignInSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var title: String { self == .signIn ? "登录" : "注册" }
    }

    @ObservedObject private var account = AnimeAccount.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var kind: AnimeAccountKind = .email
    @State private var login = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var code = ""
    @State private var answer = ""
    @State private var captcha: AnimeCaptcha?
    @State private var captchaLoading = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""
    @State private var codeCountdown = 0
    @State private var countdownTask: Task<Void, Never>?

    init(startWith mode: Mode = .signIn) {
        _mode = State(initialValue: mode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack {
                    Text(mode.title)
                        .font(Theme.Typo.detailTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    SheetCloseButton()
                }
                .padding(.top, Theme.Space.lg)

                Picker("登录或注册", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("account.mode")

                VStack(alignment: .leading, spacing: Theme.Space.md + 2) {
                    if mode == .signUp {
                        AccountField(label: "昵称", placeholder: "评论和弹幕里显示的名字", text: $nickname,
                                     content: .nickname, identifier: "account.nickname")
                    }
                    AccountField(label: kind.title, placeholder: kind == .email ? "name@example.com" : "11 位手机号",
                                 text: $login, keyboard: kind == .email ? .emailAddress : .phonePad,
                                 content: kind == .email ? .emailAddress : .telephoneNumber, identifier: "account.login")
                    CaptchaField(captcha: captcha, loading: captchaLoading, answer: $answer) { loadCaptcha() }
                    if mode == .signUp {
                        AccountField(label: kind == .email ? "邮件验证码" : "短信验证码", placeholder: "收到的验证码",
                                     text: $code, keyboard: .numberPad, content: .oneTimeCode, identifier: "account.code") {
                            Button(action: sendCode) {
                                Text(codeCountdown > 0 ? "\(codeCountdown) 秒" : "获取验证码")
                                    .font(Theme.Typo.meta.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(codeCountdown > 0 ? Theme.textMuted : Theme.textPrimary)
                                    .padding(.horizontal, Theme.Space.md)
                                    .frame(height: 36)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay { Capsule().strokeBorder(Theme.rule, lineWidth: 1) }
                            }
                            .buttonStyle(.pressable(scale: 0.95))
                            .disabled(codeCountdown > 0 || working)
                            .accessibilityIdentifier("account.sendCode")
                        }
                    }
                    AccountField(label: "密码", placeholder: mode == .signUp ? "不少于 6 位" : "输入密码", text: $password,
                                 secure: true, content: mode == .signUp ? .newPassword : .password, identifier: "account.password")
                }

                if !error.isEmpty {
                    DesignNotice(symbol: AppIcon.alert.name, text: error, warning: true)
                        .transition(.opacity)
                }
                if !notice.isEmpty {
                    DesignNotice(symbol: AppIcon.success.name, text: notice)
                        .transition(.opacity)
                }

                Button(action: submit) {
                    HStack(spacing: Theme.Space.sm) {
                        if working { ProgressView().controlSize(.small).tint(Theme.onPrimary) }
                        Text(mode == .signIn ? "登录" : "注册")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(!canSubmit || working)
                .accessibilityIdentifier("account.submit")

                HStack(spacing: 4) {
                    Spacer()
                    Text(kind == .email ? "没有邮箱？" : "想用邮箱？")
                        .foregroundStyle(Theme.textTertiary)
                    Button(kind == .email ? "改用手机号" : "改用邮箱") {
                        kind = kind == .email ? .phone : .email
                        login = ""
                    }
                    .font(Theme.Typo.meta.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("account.switchKind")
                    Spacer()
                }
                .font(Theme.Typo.meta)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, Theme.Space.xl)
            .animation(Motion.smooth, value: mode)
            .animation(Motion.smooth, value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .designSheet()
        .designScreen("account-sign-in")
        .task { if captcha == nil { loadCaptcha() } }
        .onChange(of: mode) { _ in
            error = ""
            answer = ""
            loadCaptcha()
        }
        .onDisappear { countdownTask?.cancel() }
    }

    private var trimmedLogin: String { login.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var loginValid: Bool {
        switch kind {
        case .email: return trimmedLogin.contains("@") && trimmedLogin.contains(".")
        case .phone: return trimmedLogin.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil
        }
    }

    private var canSubmit: Bool {
        guard loginValid, !password.isEmpty else { return false }
        if captcha != nil && answer.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if mode == .signUp {
            return password.count >= 6 && !nickname.trimmingCharacters(in: .whitespaces).isEmpty
                && !code.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func loadCaptcha() {
        captchaLoading = true
        captcha = nil
        let scene = mode == .signIn ? "login" : "register"
        Task {
            defer { captchaLoading = false }
            captcha = try? await account.captcha(scene: scene)
        }
    }

    private func sendCode() {
        error = ""
        guard loginValid else { error = kind == .email ? "先填一个正确的邮箱" : "先填一个正确的手机号"; return }
        guard let captcha, !answer.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "先填上图中算式的结果"
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                try await account.sendCode(kind: kind, account: trimmedLogin, captcha: captcha, answer: answer)
                notice = kind == .email ? "验证码已发到邮箱" : "验证码已发到手机"
                startCountdown()
            } catch {
                self.error = error.localizedDescription
            }
            // 验证码只能用一次，用过就换一张
            answer = ""
            loadCaptcha()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        codeCountdown = 60
        countdownTask = Task {
            while codeCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                codeCountdown -= 1
            }
        }
    }

    private func submit() {
        error = ""
        notice = ""
        working = true
        Task {
            defer { working = false }
            do {
                switch mode {
                case .signIn:
                    try await account.signIn(kind: kind, account: trimmedLogin, password: password,
                                             captcha: captcha, answer: answer)
                    dismiss()
                    return
                case .signUp:
                    try await account.register(kind: kind, account: trimmedLogin, nickname: nickname,
                                               code: code, password: password)
                    notice = "注册成功，用刚才的账号登录"
                    code = ""
                    mode = .signIn
                }
            } catch {
                self.error = error.localizedDescription
                Haptics.warning()
                answer = ""
                loadCaptcha()
            }
        }
    }
}

extension View {
    /// 需要登录的操作（评论、点赞、发弹幕）没登录时弹出登录面板
    func animeSignInSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { AnimeSignInSheet() }
    }
}

// MARK: - 任务中心

/// 任务中心：金币余额 → 每日签到（7 天格子 + 签到按钮）→ 其余任务（只显示进度和奖励）。
struct AnimeTasksView: View {
    @ObservedObject private var account = AnimeAccount.shared
    @State private var signing = false
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                coinCard.reveal(0)
                signCard.reveal(1)
                if !otherTasks.isEmpty {
                    SettingsSection(title: "其他任务") {
                        ForEach(Array(otherTasks.enumerated()), id: \.element.id) { index, task in
                            if index > 0 { RowDivider(leading: Theme.Space.lg) }
                            taskRow(task)
                        }
                    }
                    .reveal(2)
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("任务中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("anime-tasks")
        .refreshable { await account.refresh() }
        .task { await account.loadTasks() }
    }

    private var otherTasks: [AnimeTask] { account.tasks.filter { !$0.isSign } }

    private var coinCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("我的金币")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.textSecondary)
                Text("\(account.user?.coin ?? 0)")
                    .font(.display(40))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .rollingNumber()
            }
            Spacer()
            Image(icon: .coin)
                .font(.scaled(36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.lg)
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }

    /// 连续签到天数映射到 7 天格子：已签的打勾，今天没签的是琥珀描边
    private var signCard: some View {
        let streak = account.user?.signDays ?? 0
        let signed = account.signedToday
        let filled = signed ? ((streak - 1) % 7 + 1) : streak % 7
        let today = signed ? filled - 1 : filled
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("每日签到")
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(streak > 0 ? "已连续 \(streak) 天" : "每天 +\(account.signCoin) 金币")
                    .font(Theme.Typo.meta.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    dayCell(index, done: index < filled, isToday: index == today)
                        .frame(maxWidth: .infinity)
                }
            }
            if !error.isEmpty {
                DesignNotice(symbol: AppIcon.alert.name, text: error, warning: true)
            }
            Button(action: sign) {
                HStack(spacing: Theme.Space.sm) {
                    if signing { ProgressView().controlSize(.small).tint(Theme.onPrimary) }
                    Text(signed ? "今天已签到" : "签到 +\(account.signCoin) 金币")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(signed || signing)
            .accessibilityIdentifier("tasks.sign")
        }
        .padding(Theme.Space.lg)
        .surfaceCard()
    }

    private func dayCell(_ index: Int, done: Bool, isToday: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if done {
                    Circle().fill(Theme.primaryAction)
                    Image(icon: .check)
                        .font(.scaled(14, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                } else if isToday {
                    Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                    Text("今")
                        .font(Theme.Typo.meta.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Circle().fill(Theme.surfaceRaised)
                    Text("\(index + 1)")
                        .font(Theme.Typo.meta.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 36, height: 36)
            Text("第 \(index + 1) 天")
                .font(Theme.Typo.badge)
                .foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(index + 1) 天，\(done ? "已签到" : (isToday ? "今天" : "未到"))")
    }

    private func taskRow(_ task: AnimeTask) -> some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    if let done = task.done, let total = task.total, total > 0 {
                        Text("\(min(done, total)) / \(total)")
                            .monospacedDigit()
                    } else if !task.memo.isEmpty {
                        Text(task.memo).lineLimit(1)
                    }
                    if task.coin > 0 {
                        Text("+\(task.coin) 金币").monospacedDigit()
                    }
                }
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.textTertiary)
                if let done = task.done, let total = task.total, total > 0, !task.finished {
                    ThinProgressBar(fraction: Double(done) / Double(total))
                        .frame(width: 120)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if task.finished {
                Label("已完成", systemImage: AppIcon.success.name)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }

    private func sign() {
        error = ""
        signing = true
        Task {
            defer { signing = false }
            do { try await account.signToday() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - 消息通知

/// 消息通知：回复 / 系统 / 影片反馈 / 求片反馈，分页加载。点带影片的消息进动漫详情。
struct AnimeMessagesView: View {
    @ObservedObject private var account = AnimeAccount.shared
    @State private var kind: AnimeMessageKind = .reply
    @State private var items: [AnimeMessage] = []
    @State private var page = 0
    @State private var exhausted = false
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                Picker("消息类型", selection: $kind) {
                    ForEach(AnimeMessageKind.allCases) { kind in
                        let count = account.unread[kind] ?? 0
                        Text(count > 0 ? "\(kind.title) \(count)" : kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("messages.kind")

                content
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("消息通知")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("anime-messages")
        .refreshable { await reload() }
        .task(id: kind) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            Group {
                if loading {
                    ProgressView().tint(Theme.textSecondary)
                } else if !error.isEmpty {
                    EmptyStateView(icon: AppIcon.alert.name, title: "消息没有加载出来", message: error,
                                   actionTitle: "重新加载") { Task { await reload() } }
                } else {
                    EmptyStateView(icon: AppIcon.bell.name, title: "暂时没有消息", message: "有人回复你的评论时会出现在这里。")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, message in
                    row(message)
                        .onAppear { if index == items.count - 1 { Task { await loadMore() } } }
                }
            }
            .padding(.vertical, Theme.Space.xs)
            .surfaceCard()
        }
    }

    @ViewBuilder
    private func row(_ message: AnimeMessage) -> some View {
        if let vid = message.videoID, vid > 0 {
            NavigationLink(value: AnimeDetailRoute(animeId: vid)) { messageBody(message) }
                .buttonStyle(.pressable(scale: 0.985))
        } else {
            messageBody(message)
        }
    }

    private func messageBody(_ message: AnimeMessage) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Text(String((message.sender.isEmpty ? (kind == .sys ? "系" : "?") : message.sender).prefix(1)))
                .font(Theme.Typo.row.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceHigh, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                if !message.sender.isEmpty || !message.title.isEmpty {
                    HStack(spacing: 4) {
                        if !message.sender.isEmpty {
                            Text(message.sender).font(Theme.Typo.row.weight(.semibold))
                        }
                        if !message.title.isEmpty {
                            Text(message.title).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.quote.isEmpty {
                    Text(message.quote)
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
                Text([message.videoName, message.time].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if message.unread {
                Circle().fill(Theme.accent).frame(width: 8, height: 8).padding(.top, 6)
                    .accessibilityLabel("未读")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md + 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        page = 0
        exhausted = false
        error = ""
        items = []
        await loadMore()
        account.markRead(kind)
    }

    private func loadMore() async {
        guard !loading, !exhausted, !InterfacePreview.active else { return }
        loading = true
        defer { loading = false }
        let requested = kind
        do {
            let next = try await account.messages(requested, page: page + 1)
            guard requested == kind else { return }
            let known = Set(items.map(\.id))
            items += next.filter { !known.contains($0.id) }
            page += 1
            exhausted = next.count < 20
        } catch {
            guard requested == kind else { return }
            self.error = error.localizedDescription
            exhausted = true
        }
    }
}

// MARK: - 接口诊断（「关于」里长按版本号进入）

/// 登录后把账号相关接口的解密原文列出来，方便对字段。不改任何数据：只有 GET。
struct AnimeDiagnosticsView: View {
    private struct Probe: Identifiable {
        let path: String
        var id: String { path }
    }

    private let probes = ["/app/users/info", "/app/task", "/app/task/sign_rule", "/app/messagebox",
                          "/app/messagebox/reply?limit=5&page=1", "/app/messagebox/sys?limit=5&page=1",
                          "/app/vod_comment/captcha", "/app/config"].map(Probe.init)
    @State private var results: [String: String] = [:]
    @State private var running = false

    var body: some View {
        List {
            Section {
                Button(running ? "正在请求…" : "全部请求一遍") { runAll() }
                    .disabled(running)
                Button("复制全部结果") {
                    UIPasteboard.general.string = probes.map { "## \($0.path)\n\(results[$0.path] ?? "")" }.joined(separator: "\n\n")
                    Haptics.success()
                }
                .disabled(results.isEmpty)
            } footer: {
                Text(AnimeSigner.shared.hasUserToken ? "当前带着登录令牌请求" : "当前没有登录，需要登录的接口会返回 50008")
            }
            ForEach(probes) { probe in
                Section(probe.path) {
                    Text(results[probe.path] ?? "还没请求")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(40)
                }
            }
        }
        .navigationTitle("接口诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("anime-diagnostics")
    }

    private func runAll() {
        running = true
        Task {
            defer { running = false }
            for probe in probes {
                do {
                    let envelope = try await AnimeClient.shared.call(probe.path)
                    results[probe.path] = Self.pretty(envelope.raw)
                } catch {
                    results[probe.path] = "请求失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static func pretty(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        // 验证码图片的 base64 太长，截掉
        return text.replacingOccurrences(of: #"data:image/[^"]{60,}"#, with: "data:image/…", options: .regularExpression)
    }
}
