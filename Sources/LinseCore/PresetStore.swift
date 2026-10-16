import Foundation

/// 只负责持久化；调用者在写入成功后再发布新的预设列表。
public struct PresetStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [Preset] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return try JSONDecoder().decode([Preset].self, from: data)
    }

    public func save(_ presets: [Preset]) throws {
        let data = try JSONEncoder().encode(presets)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
