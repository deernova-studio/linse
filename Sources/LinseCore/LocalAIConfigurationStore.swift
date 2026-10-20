import Foundation

public struct LocalAIConfigurationStore: Sendable {
    public let url: URL
    public let legacySettingsURL: URL?

    public init(url: URL, legacySettingsURL: URL? = nil) {
        self.url = url
        self.legacySettingsURL = legacySettingsURL
    }

    public func load() throws -> LocalAIConfiguration {
        if let data = try readIfPresent(url) {
            return try JSONDecoder().decode(LocalAIConfiguration.self, from: data)
        }
        // 只迁移旧接口设置，不访问旧钥匙串，避免再次触发系统授权。
        if let legacySettingsURL, let data = try readIfPresent(legacySettingsURL) {
            return LocalAIConfiguration(ai: try JSONDecoder().decode(AISettings.self, from: data))
        }
        return LocalAIConfiguration()
    }

    /// nil 保留已保存的 Key，空字符串清除 Key。读取失败时不覆盖原文件。
    @discardableResult
    public func save(settings: AISettings, key: String?) throws -> LocalAIConfiguration {
        var configuration = try load()
        configuration.ai = settings
        if let key { configuration.apiKey = key }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        let directory = url.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return configuration
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
}
