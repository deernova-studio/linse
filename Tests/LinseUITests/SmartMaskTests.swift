import CoreImage
@testable import LinseCore
@testable import LinseUI
import Metal
import XCTest

final class SmartMaskTests: XCTestCase {
    @MainActor
    func testFileImportRefreshesExistingSmartMaskAfterImportFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recognized = expectation(description: "新文件导入后重新识别")
        let service = SmartMaskService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, image, _ in
            XCTAssertEqual(image.extent.width, 32)
            recognized.fulfill()
            return MaskBitmap(id: "new", width: 2, height: 2, data: [255, 0, 0, 255])
        }
        let state = AppState(luts: LutStore(dir: directory), maskService: service)
        state.load(source(width: 16), name: "old", into: .source)
        state.params.masks = [Mask(type: .sky, index: 1)]
        state.smartMasks.set(.sky, bitmap("old"))
        let data = try XCTUnwrap(CIContext().pngRepresentation(of: source(width: 32), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let loaded = await state.load(data: data, name: "new.png", into: .source)
        XCTAssertTrue(loaded)
        await state.maskTask?.value
        await fulfillment(of: [recognized], timeout: 3)
        XCTAssertEqual(state.smartMasks.maskBitmap(.sky)?.id, "new")
        XCTAssertNil(state.busy)
        XCTAssertEqual(state.params.masks.count, 1)
    }

    @MainActor
    func testOldRecognitionCannotOverwriteNewImageOrClearNewRequest() async throws {
        let oldEntered = expectation(description: "旧照片识别开始")
        let newEntered = expectation(description: "新照片识别开始")
        let oldGate = MaskGate(), newGate = MaskGate()
        let service = SmartMaskService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, image, _ in
            if image.extent.width == 16 { return await oldGate.wait { oldEntered.fulfill() } }
            return await newGate.wait { newEntered.fulfill() }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory), maskService: service)
        state.load(source(width: 16), name: "old", into: .source)
        state.addMask(.sky)
        let oldTask = try XCTUnwrap(state.maskTask)
        await fulfillment(of: [oldEntered], timeout: 5)
        state.load(source(width: 24), name: "new", into: .source)
        state.addMask(.sky)
        let newTask = try XCTUnwrap(state.maskTask)
        await fulfillment(of: [newEntered], timeout: 5)
        await oldGate.release(bitmap("old"))
        await oldTask.value
        XCTAssertNotNil(state.busy, "旧任务完成不能清除新任务的忙碌状态")
        XCTAssertTrue(state.params.masks.isEmpty)
        XCTAssertNil(state.smartMasks.maskBitmap(.sky))
        await newGate.release(bitmap("new"))
        await newTask.value
        XCTAssertNil(state.busy)
        XCTAssertNil(state.maskTask)
        XCTAssertEqual(state.smartMasks.maskBitmap(.sky)?.id, "new")
        XCTAssertEqual(state.params.masks.map(\.type), [.sky])
    }

    @MainActor
    func testRecognitionFailurePreservesEditsAndAllowsRetry() async throws {
        let attempts = MaskAttempts()
        let service = SmartMaskService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())) { _, _, _ in
            try await attempts.next()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory), maskService: service)
        state.load(source(width: 16), name: "source", into: .source)
        state.params.exposure = 1
        state.addMask(.sky)
        await state.maskTask?.value
        XCTAssertNil(state.busy)
        XCTAssertTrue(state.params.masks.isEmpty)
        XCTAssertEqual(state.params.exposure, 1)
        XCTAssertTrue(state.toast?.contains("模拟识别失败") == true)
        state.addMask(.sky)
        await state.maskTask?.value
        XCTAssertNil(state.busy)
        XCTAssertEqual(state.params.masks.map(\.type), [.sky])
        XCTAssertEqual(state.params.exposure, 1)
    }

    private func source(width: Int) -> CIImage {
        CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: width, height: 16))
    }

    private func bitmap(_ id: String) -> MaskBitmap {
        MaskBitmap(id: id, width: 2, height: 2, data: [255, 255, 0, 0])
    }
}

private actor MaskGate {
    private var continuation: CheckedContinuation<MaskBitmap, Never>?
    func wait(started: @Sendable () -> Void) async -> MaskBitmap {
        await withCheckedContinuation {
            continuation = $0
            started()
        }
    }
    func release(_ bitmap: MaskBitmap) {
        continuation?.resume(returning: bitmap)
        continuation = nil
    }
}

private actor MaskAttempts {
    private var count = 0
    func next() throws -> MaskBitmap {
        count += 1
        if count == 1 { throw SmartMask.Failure.failed("模拟识别失败") }
        return MaskBitmap(id: "retry", width: 2, height: 2, data: [255, 255, 0, 0])
    }
}
