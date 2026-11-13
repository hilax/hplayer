import SwiftUI

/// One credential editor shared by the source list and manual matching.
struct MetadataCredentialsView: View {
    private enum Field: Hashable { case tmdb, api, affiliate }
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @State private var tmdb = TMDBClient.storedKey
    @State private var apiID = DMMClient.storedCredentials()?.apiID ?? ""
    @State private var affiliateID = DMMClient.storedCredentials()?.affiliateID ?? ""
    @State private var deleting = false

    private var valid: Bool {
        apiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == affiliateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsSection(title: "TMDB", footnote: "用于获取影片资料与中文海报。留空时继续使用番组计划和 IMDb。") {
                    DesignField(label: "API Key / API 读访问令牌", placeholder: "输入 TMDB 凭证", text: $tmdb, secure: true)
                        .focused($focusedField, equals: .tmdb)
                        .accessibilityIdentifier("credentials.tmdb")
                        .padding(Theme.Space.lg)
                }
                SettingsSection(title: "FANZA（DMM）", footnote: "从 affiliate.dmm.com 申请。仅向 api.dmm.com 发送番号，两个字段需要同时填写。") {
                    VStack(spacing: Theme.Space.lg) {
                        DesignField(label: "API ID", placeholder: "DMM Web API ID", text: $apiID, secure: true)
                            .focused($focusedField, equals: .api)
                            .accessibilityIdentifier("credentials.dmm.api")
                        DesignField(label: "Affiliate ID", placeholder: "以 990–999 结尾", text: $affiliateID)
                            .focused($focusedField, equals: .affiliate)
                            .accessibilityIdentifier("credentials.dmm.affiliate")
                    }
                    .padding(Theme.Space.lg)
                }
                VStack(spacing: Theme.Space.md) {
                    Button("保存凭证") {
                        TMDBClient.saveKey(tmdb.trimmingCharacters(in: .whitespacesAndNewlines))
                        DMMClient.saveCredentials(apiID: apiID, affiliateID: affiliateID)
                        dismiss()
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(!valid)
                    .accessibilityIdentifier("credentials.save")
                    Button("删除已保存的凭证") { deleting = true }
                        .buttonStyle(ActionButtonStyle(kind: .secondaryDestructive, minHeight: 46))
                        .accessibilityIdentifier("credentials.delete")
                }
                DesignNotice(symbol: AppIcon.privacy.name, text: "凭证只保存在本机钥匙串，不上传到 HPlayer 或 115。")
                    .padding(.horizontal, Theme.Space.xs)
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("资料接口凭证")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
        }
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
