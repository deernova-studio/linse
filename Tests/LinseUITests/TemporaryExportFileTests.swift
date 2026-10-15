import Foundation
@testable import LinseUI
import XCTest

final class TemporaryExportFileTests: XCTestCase {
    func testSameNameExportsKeepIndependentFilesUntilReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linse-file-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: TemporaryExportFile? = try TemporaryExportFile(name: "照片.jpg", root: root)
        let firstURL = try XCTUnwrap(first?.url)
        let second = try TemporaryExportFile(name: "照片.jpg", root: root)
        try Data([1, 2, 3]).write(to: firstURL)
        try Data([4, 5, 6]).write(to: second.url)

        XCTAssertNotEqual(firstURL, second.url)
        XCTAssertEqual(second.url.lastPathComponent, "照片.jpg")
        XCTAssertEqual(try Data(contentsOf: firstURL), Data([1, 2, 3]))
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: second.url), Data([4, 5, 6]))
        withExtendedLifetime(second) {}
    }
}
