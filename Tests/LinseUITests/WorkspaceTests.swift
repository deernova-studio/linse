import CoreImage
@testable import LinseCore
@testable import LinseUI
import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testRestoreKeepsOriginalBytesStrengthAndUndoHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory.appendingPathComponent("workspace"))
        let state = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")))
        state.workspaceStore = store
        await state.restoreWorkspace()
        let data = try png()
        let loaded = await state.load(data: data, name: "original.png", into: .source)
        XCTAssertTrue(loaded)
        let targetLoaded = await state.load(data: data, name: "reference.png", into: .target)
        XCTAssertTrue(targetLoaded)
        var preset = Params()
        preset.exposure = 2
        preset.contrast = 40
        state.applyPreset(Preset(id: "test", name: "test", params: preset))
        state.params.exposure = 3
        state.commitUndo()
        state.setStrength(50)
        state.commitUndo()
        state.params.masks = [Mask(type: .sky, index: 1)]
        state.smartMasks.set(.sky, MaskBitmap(id: "saved-sky", width: 2, height: 2, data: [255, 0, 0, 255]))
        state.summary?.ai = AIAnalysis(json: ["style_summary": "暖色", "reasons": [["slider": "曝光", "why": "保持亮度"]]])
        let saved = await state.saveWorkspaceNow()
        XCTAssertTrue(saved)
        state.workspaceSaveTask?.cancel()

        let restored = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")))
        restored.workspaceStore = store
        await restored.restoreWorkspace()
        XCTAssertEqual(restored.source?.originalData, data)
        XCTAssertEqual(restored.target?.originalData, data)
        XCTAssertEqual(restored.source?.id, state.source?.id)
        XCTAssertEqual(restored.params.exposure, 3)
        XCTAssertEqual(restored.params.contrast, 20)
        XCTAssertEqual(restored.strength, 50)
        XCTAssertEqual(restored.smartMasks.maskBitmap(.sky)?.data, [255, 0, 0, 255])
        XCTAssertEqual(restored.summary?.ai?.reasons.first?.why, "保持亮度")
        restored.undoAction() // 撤销最后添加的蒙版与说明
        restored.undoAction()
        XCTAssertEqual(restored.strength, 100)
        XCTAssertEqual(restored.params.exposure, 3)
        restored.undoAction()
        XCTAssertEqual(restored.params.exposure, 2)
        restored.redoAction()
        restored.setStrength(0)
        XCTAssertEqual(restored.params.exposure, 3)
        XCTAssertEqual(restored.params.contrast, 0)
        restored.workspaceSaveTask?.cancel()
    }

    @MainActor
    func testDamagedWorkspaceIsReportedAndNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.plist")
        let damaged = Data("broken".utf8)
        try damaged.write(to: url)
        let state = AppState(luts: LutStore(dir: directory.appendingPathComponent("luts")))
        state.workspaceStore = WorkspaceStore(directory: directory)
        await state.restoreWorkspace()
        XCTAssertNotNil(state.workspaceError)
        XCTAssertFalse(state.workspaceReady)
        let saved = await state.saveWorkspaceNow()
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        await state.archiveFailedWorkspaceAndContinue()
        XCTAssertTrue(state.workspaceReady)
        XCTAssertFalse(state.workspaceRecoveryBlocked)
        XCTAssertNil(state.workspaceError)
        let siblings = try FileManager.default.contentsOfDirectory(at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(siblings.first { $0.lastPathComponent.hasPrefix(directory.lastPathComponent + "-backup-") })
        defer { try? FileManager.default.removeItem(at: backup) }
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("session.plist")), damaged)
    }

    func testFailedSaveRetainsLastCommittedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let id = UUID(), data = try png()
        var record = WorkspaceRecord(source: WorkspaceImage(id: id, name: "a.png"), edit: EditorSnapshot(),
                                     history: EditHistory(), masks: [:], viewMode: "结果", split: 0.5)
        try await store.save(record, images: [id: data])
        record.source = WorkspaceImage(id: UUID(), name: "missing.png")
        do {
            try await store.save(record, images: [:])
            XCTFail("缺失图片必须拒绝提交")
        } catch {}
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.0.source?.id, id)
        XCTAssertEqual(loaded?.1[id], data)
    }

    func testInvalidMaskBitmapIsRejectedBeforeRendering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let record = WorkspaceRecord(edit: EditorSnapshot(), history: EditHistory(),
            masks: [.sky: MaskBitmap(id: "broken", width: 2, height: 2, data: [255])],
            viewMode: "结果", split: 0.5)
        try await store.save(record, images: [:])
        do {
            _ = try await store.load()
            XCTFail("损坏的蒙版不得送入 GPU")
        } catch {}
    }

    private func png() throws -> Data {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        return try XCTUnwrap(CIContext().pngRepresentation(of: image, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    }
}
