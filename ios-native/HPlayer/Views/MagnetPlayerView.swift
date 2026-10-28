import AVKit
import SwiftUI
import UIKit

struct MagnetPlayerView: View {
    var initialMagnet = ""
    @StateObject private var controller = MagnetController()
    @State private var magnet = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                TextEditor(text: $magnet)
                    .focused($inputFocused)
                    .frame(minHeight: 75)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("粘贴磁力链接") { magnet = UIPasteboard.general.string ?? "" }
                    Spacer()
                    Button("解析并播放") { inputFocused = false; controller.start(magnet) }
                        .disabled(controller.working || magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: { Text("磁力链接") }
            footer: { Text("无需 115 账号或电脑。播放时使用 BT 节点并占用手机网络和缓存。") }

            if let player = controller.player {
                Section {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                    if !controller.peerInfo.isEmpty { Text(controller.peerInfo).font(.caption).foregroundStyle(.secondary) }
                }
            }

            if controller.working || !controller.status.isEmpty {
                Section {
                    HStack {
                        if controller.working { ProgressView() }
                        Text(controller.status).font(.subheadline)
                    }
                }
            }
            if !controller.error.isEmpty {
                Section { Label(controller.error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            }
            if !controller.files.isEmpty {
                Section {
                    ForEach(controller.files, id: \.index) { file in
                        Button { controller.select(file) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: controller.selectedIndex == file.index ? "play.circle.fill" : "play.circle")
                                    .foregroundStyle(MagnetController.supported(file) ? Theme.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.path).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text("\(formatSize(Int(clamping: file.size)))\(MagnetController.supported(file) ? "" : " · 暂不支持此格式")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }.buttonStyle(.plain).disabled(controller.working)
                    }
                } header: { Text("视频文件") }
                footer: { Text("目前支持 MP4、MOV、M4V；具体编码仍需 iPhone 支持。") }
            }
            if controller.working || controller.player != nil || !controller.files.isEmpty {
                Section { Button("结束当前磁力任务", role: .destructive) { controller.close() } }
            }
        }
        .navigationTitle("磁力在线播放")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { inputFocused = false } }
            if !initialMagnet.isEmpty { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task {
            guard magnet.isEmpty, !initialMagnet.isEmpty else { return }
            magnet = initialMagnet
            controller.start(initialMagnet)
        }
        .onDisappear { controller.close() }
    }
}
