import SwiftUI

/// 填写 DMM Web API 的 API ID 和 Affiliate ID（免费申请，可选），存在钥匙串里。
struct DMMKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiID = DMMClient.storedCredentials()?.apiID ?? ""
    @State private var affiliateID = DMMClient.storedCredentials()?.affiliateID ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("API ID", text: $apiID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Affiliate ID（以 990 到 999 结尾）", text: $affiliateID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("到 affiliate.dmm.com 注册 DMM アフィリエイト，在「Webサービス」里免费申请。填了之后，番号会先用官方接口查片名、演员和封面；不填也能用，只会按番号找封面图。Key 只保存在这台手机的钥匙串里，只发送给 api.dmm.com，请求里只有番号。")
                }
                Section {
                    Text("Powered by DMM.com Webサービス").font(.footnote).foregroundStyle(.secondary)
                }
                if DMMClient.storedCredentials() != nil {
                    Section {
                        Button("删除 Key", role: .destructive) {
                            DMMClient.saveCredentials(apiID: "", affiliateID: "")
                            dismiss()
                        }
                    }
                }
            }
            .libraryFormStyle()
        .navigationTitle("FANZA（DMM）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        DMMClient.saveCredentials(apiID: apiID, affiliateID: affiliateID)
                        dismiss()
                    }
                }
            }
        }
    }
}
