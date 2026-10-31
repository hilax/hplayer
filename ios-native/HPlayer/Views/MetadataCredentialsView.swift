import SwiftUI

/// One credential editor shared by the source list and manual matching.
struct MetadataCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tmdb = TMDBClient.storedKey
    @State private var apiID = DMMClient.storedCredentials()?.apiID ?? ""
    @State private var affiliateID = DMMClient.storedCredentials()?.affiliateID ?? ""
    @State private var deleting = false

    private var valid: Bool {
        apiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == affiliateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DesignPage(eyebrow: "Optional credentials", title: "资料接口凭证", subtitle: "按需开启更丰富的影片资料。") {
            VStack(alignment: .leading, spacing: 17) {
                Label("TMDB", systemImage: "key").font(.headline)
                DesignField(label: "API Key / API 读访问令牌", placeholder: "输入 TMDB 凭证", text: $tmdb, secure: true)
                    .accessibilityIdentifier("credentials.tmdb")
                DesignNotice(text: "用于获取影片资料与中文海报。留空时继续使用番组计划和 IMDb。")
            }.padding(18).surfaceCard()
            VStack(alignment: .leading, spacing: 17) {
                Label("FANZA（DMM）", systemImage: "key").font(.headline)
                DesignField(label: "API ID", placeholder: "DMM Web API ID", text: $apiID, secure: true)
                    .accessibilityIdentifier("credentials.dmm.api")
                DesignField(label: "Affiliate ID", placeholder: "以 990–999 结尾", text: $affiliateID)
                    .accessibilityIdentifier("credentials.dmm.affiliate")
                DesignNotice(text: "从 affiliate.dmm.com 申请。仅向 api.dmm.com 发送番号，两个字段需同时填写。")
            }.padding(18).surfaceCard()
            Button("保存凭证") {
                TMDBClient.saveKey(tmdb.trimmingCharacters(in: .whitespacesAndNewlines))
                DMMClient.saveCredentials(apiID: apiID, affiliateID: affiliateID)
                dismiss()
            }
            .buttonStyle(PrimaryActionStyle()).disabled(!valid)
            .accessibilityIdentifier("credentials.save")
            Button("删除已保存的凭证", role: .destructive) { deleting = true }
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
            DesignNotice(symbol: "lock.shield", text: "凭证仅保存在本机钥匙串，不上传到 HPlayer 或 115。")
        }
        .navigationTitle("接口凭证")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .confirmationDialog("删除这台设备上的资料接口凭证？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除凭证", role: .destructive) {
                TMDBClient.saveKey("")
                DMMClient.saveCredentials(apiID: "", affiliateID: "")
                dismiss()
            }
        }
        .designScreen("credentials")
    }
}
