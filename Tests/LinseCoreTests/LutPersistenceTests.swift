import Foundation
@testable import LinseCore
import XCTest

final class LutPersistenceTests: XCTestCase {
    func testDeleteFailurePreservesInMemoryLUTAndCanRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-lut-storage-\(UUID().uuidString)")
        let store = LutStore(dir: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let input = directory.appendingPathComponent("input.cube")
        try ("LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8)).write(to: input, atomically: true, encoding: .utf8)
        let lut = try store.importFile(input)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.delete(lut.id))
        XCTAssertNotNil(store.lut(id: lut.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(lut.id + ".cube").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try store.delete(lut.id)
        XCTAssertNil(store.lut(id: lut.id))
        try store.delete(lut.id) // 外部/先前已删除的文件可安全清理。
    }
}
