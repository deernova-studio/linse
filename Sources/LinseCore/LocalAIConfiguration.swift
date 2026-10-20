import Foundation

/// macOS 的本地 AI 配置，API Key 与接口设置一起以普通 JSON 保存。
public struct LocalAIConfiguration: Codable, Equatable, Sendable {
    public var ai: AISettings
    public var apiKey: String

    public init(ai: AISettings = AISettings(), apiKey: String = "") {
        self.ai = ai
        self.apiKey = apiKey
    }

    private enum CodingKeys: String, CodingKey { case ai, apiKey }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ai = try values.decodeIfPresent(AISettings.self, forKey: .ai) ?? AISettings()
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }
}
