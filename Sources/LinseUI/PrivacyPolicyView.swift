import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "隐私说明", closeLabel: "关闭隐私说明") { dismiss() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本地编辑").font(.headline)
                    Text("导入、调色、计算匹配、蒙版识别和导出在设备上完成。临色不需要注册账号，不包含广告或第三方行为追踪。")
                    Text("可选的 AI 分析").font(.headline)
                    Text("点击「AI 辅助匹配」后，临色会先显示接收图片的服务地址。只有你同意本次发送，才会向你配置的 AI 服务发送原图和目标图的缩小预览、色彩统计及分析指令。不发送原始文件、文件名、位置或相机元数据。")
                    Text("API Key 仅用于向你配置的服务验证身份。服务提供方可看到请求内容及连接信息，并按其隐私政策决定保存期限、处理方式和删除渠道。使用自定义服务时，请先了解该服务的隐私政策。临色开发者不经营接收这些照片的服务器。")
                    Text("你的选择").font(.headline)
                    Text("每次发送照片前都可以取消。无需 AI 服务或 API Key，也能使用本地编辑与计算匹配。已发出的请求无法撤回；如需删除服务端记录，请联系接收请求的服务提供方。")
                    Text("设备上的数据").font(.headline)
                    Text("预设、LUT、外观和 AI 设置保存在设备上。Mac 的 API Key 随本地配置保存；iPhone 和 iPad 的 API Key 保存在系统钥匙串。商店版 Mac 的配置位于应用沙盒中。临色不会主动同步这些数据到开发者的服务器。")
                    Text("图片在当前编辑会话中用于预览和处理，导出文件保存在你选择的位置。你可以在应用中删除预设和 LUT；不再需要 AI 时，可清除 API Key。操作系统的备份与诊断功能由你的系统设置控制。")
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
                .background(Color.surface)
            }
        }
        .tint(Color.brandAccent)
        .accentColor(Color.brandAccent)
        #if os(macOS)
        .frame(width: 540, height: 560)
        #endif
    }
}
