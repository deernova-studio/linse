import CoreImage
import Foundation
@testable import LinseCore
import XCTest

final class ExportServiceTests: XCTestCase {
    func testConcurrentImageAndLUTRequestsKeepTheirOwnInputs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = try Renderer()
        let service = ExportService(device: reference.device)
        let firstSource = source(red: 0.3, green: 0.4, blue: 0.5)
        let secondSource = source(red: 0.7, green: 0.2, blue: 0.1)
        var firstParams = Params(), secondParams = Params()
        firstParams.curves.rgb = [[0, 50], [255, 255]]
        secondParams.curves.rgb = [[0, 0], [255, 160]]
        secondParams.setHSL(.red, HSLValue(sat: -40))
        let assets = ExportAssets(params: Params())
        try reference.setImage(ci: firstSource)
        let expectedFirst = try reference.renderRGBA8(firstParams, width: 32, height: 24)
        try reference.setImage(ci: secondSource)
        let expectedSecond = try Exporter.render(reference, secondParams, format: .tiff16)
        let expectedLUT = try CubeLut.bake(reference, secondParams, title: "parallel", size: 5)

        let started = expectation(description: "图片导出已经进入渲染阶段")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await service.writeImage(firstSource, params: firstParams, assets: assets, format: .png,
                                         to: directory.appendingPathComponent("first.png")) { _, _ in
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let lut = Task { try await service.lutText(params: secondParams, assets: assets, title: "parallel", size: 5) }
        let second = Task {
            try await service.writeImage(secondSource, params: secondParams, assets: assets, format: .tiff16,
                                         to: directory.appendingPathComponent("second.tif"))
        }
        release.signal()
        let firstResult = try await first.value
        let secondResult = try await second.value
        let lutResult = try await lut.value
        XCTAssertEqual(try bytes(firstResult), expectedFirst)
        XCTAssertEqual(try bytes(secondResult), try bytes(expectedSecond))
        XCTAssertEqual(secondResult.bitsPerComponent, 16)
        XCTAssertEqual(lutResult, expectedLUT)
    }

    func testImageExportKeepsLUTAndMaskSnapshotsAcrossTiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lutURL = directory.appendingPathComponent("look.cube")
        try ("LUT_3D_SIZE 2\n" + String(repeating: "0.25 0.1 0.2\n", count: 8))
            .write(to: lutURL, atomically: true, encoding: .utf8)
        let luts = LutStore(dir: directory.appendingPathComponent("luts"))
        let lut = try luts.importFile(lutURL)
        let masks = SmartMaskStore()
        masks.set(.sky, MaskBitmap(id: "test-sky", width: 4, height: 2, data: [UInt8](repeating: 255, count: 8)))
        var params = Params()
        params.lut = LutRef(id: lut.id, name: lut.name)
        var mask = Mask(type: .sky, index: 1)
        mask.adjust.exposure = 1
        params.masks = [mask]
        let assets = ExportAssets(params: params, luts: luts, maskBitmaps: masks)
        let input = source(red: 0.3, green: 0.4, blue: 0.5, width: 2050, height: 8)
        let reference = try Renderer()
        reference.luts = luts
        reference.maskBitmaps = masks
        try reference.setImage(ci: input)
        let expected = try reference.renderRGBA8(params, width: 2050, height: 8)

        let service = ExportService(device: reference.device)
        let betweenTiles = expectation(description: "第一块完成，第二块尚未开始")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let export = Task {
            try await service.writeImage(input, params: params, assets: assets, format: .png,
                                         to: directory.appendingPathComponent("snapshot.png")) { tile, _ in
                if tile == 2 {
                    betweenTiles.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
            }
        }
        await fulfillment(of: [betweenTiles], timeout: 5)
        try luts.delete(lut.id)
        masks.reset()
        release.signal()
        let result = try await export.value
        XCTAssertEqual(try bytes(result), expected, "后续分块必须继续使用导出开始时的 LUT 和蒙版")
    }

    func testFailedWriteDoesNotPoisonFollowingExports() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = try Renderer()
        let service = ExportService(device: reference.device)
        let input = source(red: 0.3, green: 0.4, blue: 0.5)
        var params = Params()
        params.curves.rgb = [[0, 50], [255, 255]]
        let assets = ExportAssets(params: params)
        do {
            _ = try await service.writeImage(input, params: params, assets: assets, format: .png,
                                             to: directory.appendingPathComponent("missing/output.png"))
            XCTFail("不存在的目录应导致导出失败")
        } catch {}
        let expectedLUT = try CubeLut.bake(reference, Params(), title: "recovered", size: 3)
        let actualLUT = try await service.lutText(params: Params(), assets: assets, title: "recovered", size: 3)
        XCTAssertEqual(actualLUT, expectedLUT)
        let result = try await service.writeImage(input, params: Params(), assets: assets, format: .jpeg,
                                                 to: directory.appendingPathComponent("recovered.jpg"))
        try reference.setImage(ci: input)
        XCTAssertEqual(try bytes(result), try reference.renderRGBA8(Params(), width: 32, height: 24))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovered.jpg").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-export-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func source(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 32, height: Int = 24) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
    }
}
