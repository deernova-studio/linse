import Foundation

/// 每次导出独占目录；分享或相册仍持有此对象时，文件不会被下一次导出覆盖或删除。
final class TemporaryExportFile: Identifiable, Sendable {
    let url: URL
    private let directory: URL
    var id: URL { url }

    init(name: String, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("linse-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
