import Foundation
import LinseCore

struct WorkspaceImage: Codable {
    var id: UUID
    var name: String
    var typeIdentifierHint: String?
}

struct WorkspaceRecord: Codable {
    var version = 1
    var source: WorkspaceImage?
    var target: WorkspaceImage?
    var edit: EditorSnapshot
    var history: EditHistory
    var masks: [MaskType: MaskBitmap]
    var viewMode: String
    var split: Double
}

/// 图片只写入一次，最后原子替换小型状态文件；写入失败时上一份现场仍然可恢复。
/// 仅用于本机自动恢复，不是跨设备的项目交换格式。
actor WorkspaceStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func save(_ record: WorkspaceRecord, images: [UUID: Data]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (id, data) in images {
            let url = imageURL(id)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }
        for image in [record.source, record.target].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: imageURL(image.id).path) else { throw Failure.missingImage }
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(record).write(to: directory.appendingPathComponent("session.plist"), options: .atomic)
        // 提交新状态后才回收上一张图片；只清理本存储器创建的 UUID 文件。
        let kept = Set([record.source?.id, record.target?.id].compactMap { $0 })
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if file.pathExtension == "image", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func load() throws -> (WorkspaceRecord, [UUID: Data])? {
        let url = directory.appendingPathComponent("session.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try PropertyListDecoder().decode(WorkspaceRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, record.history.isValid, record.split.isFinite,
              record.edit.strength.isFinite, (0...150).contains(record.edit.strength),
              record.masks.allSatisfy({ kind, bitmap in
                  kind.isSmart && (1...1024).contains(bitmap.width) && (1...1024).contains(bitmap.height)
                      && bitmap.data.count == bitmap.width * bitmap.height
              }) else { throw Failure.invalidRecord }
        var images: [UUID: Data] = [:]
        for image in [record.source, record.target].compactMap({ $0 }) {
            images[image.id] = try Data(contentsOf: imageURL(image.id))
        }
        return (record, images)
    }

    func archive() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let backup = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-backup-" + UUID().uuidString)
        try FileManager.default.moveItem(at: directory, to: backup)
    }

    private func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".image") }

    enum Failure: LocalizedError {
        case missingImage, invalidRecord
        var errorDescription: String? {
            switch self {
            case .missingImage: return "缺少原始图片，无法保存编辑现场"
            case .invalidRecord: return "编辑现场格式不受支持或已经损坏"
            }
        }
    }
}
