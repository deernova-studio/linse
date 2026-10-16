import CoreImage
import LinseCore
@testable import LinseUI
import XCTest

final class EditHistoryTests: XCTestCase {
    @MainActor
    func testUndoRedoRestoresStrengthAndResetBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        state.load(image, name: "source", into: .source)
        var params = Params()
        params.exposure = 2
        state.applyPreset(Preset(id: "test", name: "test", params: params))
        state.setStrength(50)
        state.undoAction()
        XCTAssertEqual(state.params.exposure, 2)
        XCTAssertEqual(state.strength, 100)
        state.redoAction()
        XCTAssertEqual(state.params.exposure, 1)
        XCTAssertEqual(state.strength, 50)
        state.reset()
        state.undoAction()
        XCTAssertEqual(state.params.exposure, 1)
        XCTAssertEqual(state.strength, 50)
        XCTAssertEqual(state.matched, params)
        XCTAssertEqual(state.summary?.source, "预设 · test")
        state.setStrength(75)
        XCTAssertEqual(state.params.exposure, 1.5)
    }

    @MainActor
    func testManualEditUndoRestoresMatchingControls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        state.load(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), name: "source", into: .source)
        var params = Params()
        params.exposure = 2
        state.applyPreset(Preset(id: "test", name: "test", params: params))
        state.params.exposure = 3
        XCTAssertNil(state.matched)
        state.undoAction()
        XCTAssertEqual(state.matched, params)
        XCTAssertEqual(state.params.exposure, 2)
        state.redoAction()
        XCTAssertNil(state.matched)
        XCTAssertEqual(state.params.exposure, 3)
        state.undoAction()
        state.params.exposure = 4
        state.commitUndo()
        state.redoAction()
        XCTAssertEqual(state.params.exposure, 4, "新编辑必须替换旧 redo 分支")
    }
}
