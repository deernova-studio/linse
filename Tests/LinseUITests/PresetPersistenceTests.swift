import CoreImage
import LinseCore
@testable import LinseUI
import XCTest

@MainActor
final class PresetPersistenceTests: XCTestCase {
    func testFailedSaveAndDeleteKeepPublishedPresets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("file-not-directory")
        try Data([1]).write(to: blocked)
        let state = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")),
                             presetStore: PresetStore(url: blocked.appendingPathComponent("presets.json")))
        state.saveCurrentAsPreset(name: "must-fail")
        XCTAssertTrue(state.userPresets.isEmpty)
        XCTAssertTrue(state.toast?.contains("失败") == true)
        let existing = Preset(id: "existing", name: "existing", params: Params())
        state.userPresets = [existing]
        state.deletePreset(existing)
        XCTAssertEqual(state.userPresets, [existing])
        XCTAssertTrue(state.toast?.contains("失败") == true)
        XCTAssertEqual(try Data(contentsOf: blocked), Data([1]))
    }

    func testUnreadablePresetsAreReportedAndNotOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presets.json")
        let damaged = Data("not-json".utf8)
        try damaged.write(to: url)
        let state = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")), presetStore: PresetStore(url: url))
        state.loadPresets()
        XCTAssertTrue(state.toast?.contains("失败") == true)
        state.saveCurrentAsPreset(name: "must-not-replace")
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertTrue(state.userPresets.isEmpty)
        try PresetStore(url: url).save([])
        state.loadPresets()
        state.saveCurrentAsPreset(name: "recovered")
        XCTAssertEqual(try PresetStore(url: url).load().map(\.name), ["recovered"])
    }

    func testSavedPresetProtectsLUTAndDeletionInvalidatesUndoReferences() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let luts = LutStore(dir: directory.appendingPathComponent("luts"))
        let store = PresetStore(url: directory.appendingPathComponent("presets.json"))
        let state = AppState(luts: luts, presetStore: store)
        let lutURL = directory.appendingPathComponent("red.cube")
        try ("LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8)).write(to: lutURL, atomically: true, encoding: .utf8)
        state.importLUTs([lutURL])
        state.commitUndo()
        let id = try XCTUnwrap(state.params.lut?.id)
        state.saveCurrentAsPreset(name: "red")
        let saved = try XCTUnwrap(state.userPresets.first)
        XCTAssertEqual(try store.load(), [saved])
        state.deleteLUT(id)
        XCTAssertNotNil(luts.lut(id: id))
        XCTAssertEqual(state.params.lut?.id, id)
        XCTAssertTrue(state.toast?.contains("预设") == true)
        state.deletePreset(saved)
        XCTAssertTrue(try store.load().isEmpty)
        state.deleteLUT(id)
        XCTAssertNil(luts.lut(id: id))
        XCTAssertTrue(LutStore(dir: luts.dir).list.isEmpty)
        state.undoAction()
        state.redoAction()
        XCTAssertNil(state.params.lut, "历史不能恢复已删除的 LUT")
    }

    func testPresetWithMissingLUTDoesNotChangeEdits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        state.load(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), name: "source", into: .source)
        state.params.exposure = 1
        let before = state.params
        var missing = Params()
        missing.lut = LutRef(id: "missing", name: "missing")
        state.applyPreset(Preset(id: "missing", name: "missing", params: missing))
        XCTAssertEqual(state.params, before)
        XCTAssertTrue(state.toast?.contains("缺少 LUT") == true)
        XCTAssertNil(state.thumbnail(for: Preset(id: "missing", name: "missing", params: missing)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
