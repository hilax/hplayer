import SwiftUI
import UIKit

/// 磁力 Tab 的输入框认出磁力链接 / 哈希 / 迅雷链接时，在下面出现的解析面板：
/// 一处就能选「115 播放」（进度显示在面板上）、「磁力播放」（手机直接边下边播），或者复制整理后的链接。
struct MagnetLinkPanel: View {
    let link: MagnetLink
    let onPlay: (MagnetPlaybackRequest.Mode) -> Void

    @EnvironmentObject private var appState: AppState

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

            MagnetPlayActions(magnet: link.uri, title: link.displayName ?? link.shortHash,
                              identifierPrefix: "magnet.link", onPlay: onPlay)

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
        // 认出链接就先让 BT 引擎热起来、预取种子信息
        .magnetEngineWarmup(prefetch: link.uri)
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
        appState.isAuthenticated ? nil : "登录 115 后还可以交给 115 离线下载，再用 115 原画播放。"
    }

    private var noticeColor: Color { Theme.textSecondary }
}
