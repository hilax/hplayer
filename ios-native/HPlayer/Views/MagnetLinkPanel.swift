import SwiftUI
import UIKit

/// 把一批磁力 / 链接存进 115 离线下载（和「离线下载」页用同一个保存目录设置）。
enum Offline115Saver {
    static let folderKey = "hplayer.offline.saveFolderID"

    @MainActor
    static func save(_ links: [String], appState: AppState) async throws -> Direct115OfflineAddSummary {
        guard let client = appState.directClient() else {
            throw Direct115OfflineError.server("请先在「网盘」登录 115 账号")
        }
        let status = try await client.user()
        guard let userID = status.userId, userID > 0 else {
            throw Direct115OfflineError.server("没能确认 115 账号，请重新登录后再试")
        }
        let saved = UserDefaults.standard.string(forKey: folderKey) ?? ""
        let summary = try await client.addOfflineTasks(links, userID: userID, folderID: saved.isEmpty ? nil : saved)
        if summary.succeeded == 0, let failure = summary.failures.first { throw failure.error }
        return summary
    }
}

/// 「存到 115」按钮的状态
enum Offline115SaveState: Equatable {
    case idle, saving, saved
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "存到 115"
        case .saving: return "正在提交…"
        case .saved: return "已存到 115"
        case .failed: return "重新提交"
        }
    }
}

/// 磁力 Tab 的输入框认出磁力链接 / 哈希 / 迅雷链接时，在下面出现的解析面板：
/// 一处就能决定在线播放、存到 115 离线下载，或者复制整理后的链接。
struct MagnetLinkPanel: View {
    let link: MagnetLink
    let onPlay: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var saveState: Offline115SaveState = .idle
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: AppIcon.magnet.name)
                    .font(.scaled(18, weight: .semibold))
                    .foregroundStyle(Theme.Source.magnet)
                    .frame(width: 40, height: 40)
                    .background(Theme.Source.magnet.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别到磁力链接")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Source.magnet)
                    Text(link.displayName ?? "未命名资源")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(detailLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button(action: onPlay) {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.play.name)
                            .font(.scaled(12))
                        Text("在线播放")
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: true))
                .accessibilityIdentifier("magnet.link.play")

                Button(action: save) {
                    HStack(spacing: 6) {
                        if saveState == .saving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: saveState == .saved ? AppIcon.check.name : AppIcon.cloudDownload.name)
                                .font(.scaled(13))
                        }
                        Text(saveState.title)
                    }
                    .foregroundStyle(saveState == .saved ? Theme.success : Color.primary)
                }
                .buttonStyle(MagnetActionStyle(prominent: false))
                .disabled(saveState == .saving || saveState == .saved)
                .successPop(saveState == .saved, particle: .check, tint: Theme.success)
                .failureShake(saveFailed)
                .accessibilityIdentifier("magnet.link.save115")

                Button(action: copy) {
                    Image(systemName: copied ? AppIcon.check.name : AppIcon.copy.name)
                        .font(.scaled(14))
                        .foregroundStyle(copied ? Theme.accent : Color.primary)
                }
                .buttonStyle(MagnetActionStyle(prominent: false))
                .frame(width: 52)
                .successPop(copied)
                .accessibilityLabel(copied ? "已复制" : "复制链接")
                .accessibilityIdentifier("magnet.link.copy")
            }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(noticeColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Source.magnet.opacity(0.45), lineWidth: 1)
        }
        .animation(Motion.smooth, value: saveState)
        .onChange(of: link) { _ in saveState = .idle; copied = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magnet.link.panel")
    }

    private var detailLine: String {
        var parts = [link.shortHash]
        if link.isV2Only { parts.append("BT v2") }
        if !link.trackers.isEmpty { parts.append("\(link.trackers.count) 个 Tracker") }
        return parts.joined(separator: " · ")
    }

    private var notice: String? {
        switch saveState {
        case .saved: return "已提交到 115 离线下载，热门资源通常几秒内完成，可在「网盘 › 离线下载」查看。"
        case .failed(let message): return message
        default:
            return appState.isAuthenticated ? nil : "登录 115 后可以把资源存进网盘，之后用 115 原画播放。"
        }
    }

    private var noticeColor: Color {
        if case .failed = saveState { return Theme.danger }
        return Theme.textSecondary
    }

    private var saveFailed: Bool {
        if case .failed = saveState { return true }
        return false
    }

    private func save() {
        Haptics.tap()
        saveState = .saving
        let uri = link.uri
        Task { @MainActor in
            do {
                _ = try await Offline115Saver.save([uri], appState: appState)
                Haptics.success()
                saveState = .saved
            } catch {
                Haptics.warning()
                saveState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = link.uri
        Haptics.success()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
