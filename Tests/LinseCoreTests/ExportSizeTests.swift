import CoreImage
@testable import LinseCore
import XCTest

final class ExportSizeTests: XCTestCase {
    func testOversizeExportFailsWithoutOverwritingDestinationAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try Renderer()
        let service = ExportService(device: renderer.device)
        let url = directory.appendingPathComponent("existing.png")
        let original = Data("existing export".utf8)
        try original.write(to: url)
        let limit = renderer.maxTextureSize
        let params = Params(), assets = ExportAssets(params: Params())
        let tooLarge = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: limit + 1, height: 2))
        do {
            _ = try await service.writeImage(tooLarge, params: params, assets: assets, format: .png, to: url)
            XCTFail("超限全尺寸导出必须报错，不能静默缩小")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\(limit)"))
            XCTAssertTrue(error.localizedDescription.contains("尺寸"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let boundary = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: limit, height: 2))
        let result = try await service.writeImage(boundary, params: params, assets: assets, format: .png, to: url)
        XCTAssertEqual(result.width, limit)
        XCTAssertEqual(result.height, 2)
    }

    func testPreviewCanExplicitlyDownscaleOversizeSource() throws {
        let renderer = try Renderer()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: renderer.maxTextureSize + 1, height: 100))
        try renderer.setImage(ci: image, maxSide: 320)
        XCTAssertEqual(renderer.imageSize.width, 320)
        XCTAssertGreaterThan(renderer.imageSize.height, 0)
    }
}
