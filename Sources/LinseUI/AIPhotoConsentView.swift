import SwiftUI

struct AIPhotoConsentView: View {
    @ObservedObject var state: AppState
    let request: AIPhotoConsentRequest
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("允许 AI 分析这两张照片？").font(.headline)
            Text("将原图和目标图的缩小预览及色彩统计发送至：")
            Text(request.recipient)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("不发送原始文件或照片中的位置、相机等元数据。服务提供方将按其隐私政策处理图片，可能产生 API 费用。")
                .font(.callout).foregroundStyle(.secondary)
            Text("取消后仍可使用离线的「计算匹配」。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("隐私说明") { showPrivacy = true }
                Spacer()
                Button("取消") { state.aiPhotoConsent = nil }
                    .keyboardShortcut(.cancelAction)
                Button("同意并分析") { state.confirmAIPhotoConsent(request.id) }
            }
            .buttonStyle(NeutralButtonStyle(outlined: true))
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
    }
}
