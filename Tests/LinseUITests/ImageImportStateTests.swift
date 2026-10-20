import CoreImage
import LinseCore
@testable import LinseUI
import XCTest

final class ImageImportStateTests: XCTestCase {
    @MainActor
    func testFailedRAWImportPreservesPhotoAndAdjustments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-import-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory), aiKeyProvider: { "" })
        state.load(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8)), name: "original", into: .source)
        state.params.exposure = 0.7
        let previousID = state.source?.id
        let previousTexture = state.display.image
        let imported = await state.load(data: Data("damaged raw".utf8), name: "broken.NEF", into: .source)
        XCTAssertFalse(imported)
        XCTAssertEqual(state.source?.id, previousID)
        XCTAssertTrue(state.display.image === previousTexture)
        XCTAssertEqual(state.params.exposure, 0.7)
        XCTAssertNil(state.busy)
        XCTAssertEqual(state.imageImportError, ImageImportError.rawDecodingFailed.localizedDescription)
    }

    @MainActor
    func testBusyImportDoesNotInterruptMatch() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-busy-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory), aiKeyProvider: { "" })
        state.busy = "正在匹配"
        let imported = await state.load(data: Data(), name: "file.dng", into: .target)
        XCTAssertFalse(imported)
        XCTAssertEqual(state.busy, "正在匹配")
        XCTAssertNil(state.target)
    }
}
