import CoreImage
import Foundation
import LinseCore
@testable import LinseUI
import XCTest

final class ExportTests: XCTestCase {
    @MainActor
    func testLUTExportRejectsBusyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-export-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        state.load(input, name: "source", into: .source)
        state.busy = "正在渲染全尺寸…"
        do {
            _ = try await state.lutText(title: "must-not-start")
            XCTFail("图片导出期间不应允许 LUT 导出进入渲染器")
        } catch {
            XCTAssertEqual(error.localizedDescription, "正在处理，请稍候")
        }
        XCTAssertEqual(state.busy, "正在渲染全尺寸…", "拒绝请求不能清除正在执行的任务状态")
    }

    @MainActor
    func testImageExportCapturesParametersAndLUTBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-export-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        state.load(input, name: "source", into: .source)
        let lutURL = directory.appendingPathComponent("red.cube")
        try ("LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8))
            .write(to: lutURL, atomically: true, encoding: .utf8)
        state.importLUTs([lutURL])
        let id = try XCTUnwrap(state.params.lut?.id)
        var result: CGImage?
        let url = directory.appendingPathComponent("result.png")
        let task = try XCTUnwrap(state.export(.png, to: url) { result = $0 })
        XCTAssertNotNil(state.busy)
        // Task 尚未获得主线程执行机会；必须已捕获可变资源库中的值。
        state.deleteLUT(id)
        state.params.exposure = -5
        await task.value
        let image = try XCTUnwrap(result)
        let pixels = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
        XCTAssertEqual(Array(pixels[0..<4]), [255, 0, 0, 255])
        XCTAssertNil(state.busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testFailedImageExportClearsBusyAndAllowsLUTExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-export-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory))
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        state.load(input, name: "source", into: .source)
        var completed = false
        let task = try XCTUnwrap(state.export(.png, to: directory.appendingPathComponent("missing/result.png")) { _ in completed = true })
        await task.value
        XCTAssertFalse(completed)
        XCTAssertNil(state.busy)
        XCTAssertTrue(state.toast?.hasPrefix("导出失败：") == true)
        let text = try await state.lutText(title: "recovered")
        XCTAssertTrue(text.contains("LUT_3D_SIZE 33"))
        XCTAssertNil(state.busy)
    }
}
