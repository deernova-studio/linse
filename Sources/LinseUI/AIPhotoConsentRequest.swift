import Foundation
import LinseCore

/// An approval is valid only for the two displayed photos and the displayed service.
struct AIPhotoConsentRequest: Identifiable {
    let id = UUID()
    let sourceID: UUID
    let targetID: UUID
    let settings: AISettings

    var recipient: String {
        let base = settings.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = base.isEmpty
            ? (settings.proto == .openai ? "https://api.openai.com/v1" : "https://api.anthropic.com")
            : base
        guard var components = URLComponents(string: address) else { return "所配置的 AI 服务" }
        // Credentials are never displayed in a confirmation.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "所配置的 AI 服务"
    }
}
