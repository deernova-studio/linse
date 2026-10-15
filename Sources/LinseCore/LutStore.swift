// 导入的 3D LUT：文件复制到应用数据目录，解析后按 id 缓存。渲染器可能在后台线程读，所以加锁。
import Foundation

public final class LutStore: LutProvider, @unchecked Sendable {
    private var items: [String: CubeLut] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { (Self.created($0) ?? .distantPast) < (Self.created($1) ?? .distantPast) }
        for f in files {
            // 文件名是 id；显示名优先取文件里的 TITLE，没有就用导入时的原文件名（存在同名 .name 文件里）
            let id = f.deletingPathExtension().lastPathComponent
            let name = (try? String(contentsOf: f.deletingPathExtension().appendingPathExtension("name"), encoding: .utf8)) ?? id
            if let text = try? String(contentsOf: f, encoding: .utf8), let l = try? CubeLut(id: id, name: name, text: text) { put(l) }
        }
    }

    static func created(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.creationDateKey]).creationDate }

    public func lut(id: String) -> CubeLut? { lock.lock(); defer { lock.unlock() }; return items[id] }

    public var list: [CubeLut] { lock.lock(); defer { lock.unlock() }; return order.compactMap { items[$0] } }

    func put(_ l: CubeLut) {
        lock.lock(); defer { lock.unlock() }
        if items[l.id] == nil { order.append(l.id) }
        items[l.id] = l
    }

    /// 导入一个 .cube 文件：先解析，成功才复制进数据目录
    public func importFile(_ url: URL) throws -> CubeLut {
        let text = try String(contentsOf: url, encoding: .utf8)
        let id = UUID().uuidString
        let l = try CubeLut(id: id, name: url.deletingPathExtension().lastPathComponent, text: text)
        try text.write(to: dir.appendingPathComponent("\(id).cube"), atomically: true, encoding: .utf8)
        try? l.name.write(to: dir.appendingPathComponent("\(id).name"), atomically: true, encoding: .utf8)
        put(l)
        return l
    }

    public func delete(_ id: String) {
        lock.lock()
        items[id] = nil
        order.removeAll { $0 == id }
        lock.unlock()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).cube"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).name"))
    }
}
