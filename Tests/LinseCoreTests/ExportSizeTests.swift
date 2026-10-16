import CoreImage
import ImageIO
@testable import LinseCore
import XCTest

final class ExportSizeTests: XCTestCase {
    func testOversizeExportPreservesDimensionsInEveryFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try Renderer()
        let service = ExportService(device: renderer.device)
        let url = directory.appendingPathComponent("existing.png")
        let limit = renderer.maxTextureSize
        var params = Params()
        params.effects.clarity = 30; params.effects.sharpen = 50; params.effects.dehaze = 20
        let assets = ExportAssets(params: params)
        for (width, height) in [(limit + 1, 7), (7, limit + 1)] {
            let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            for format in ExportFormat.allCases {
                let result = try await service.writeImage(source, params: params, assets: assets, format: format, to: url)
                XCTAssertEqual(result.width, width)
                XCTAssertEqual(result.height, height)
                let decodedSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
                XCTAssertEqual(decoded.width, width)
                XCTAssertEqual(decoded.height, height)
                XCTAssertEqual(decoded.bitsPerComponent, format == .tiff16 ? 16 : 8)
            }
        }
        let boundary = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: limit, height: 2))
        let result = try await service.writeImage(boundary, params: params, assets: assets, format: .png, to: url)
        XCTAssertEqual(result.width, limit)
        XCTAssertEqual(result.height, 2)
    }

    func testCancelledOversizeExportLeavesExistingDestinationAndCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try Renderer(), url = directory.appendingPathComponent("existing.png")
        let service = ExportService(device: renderer.device)
        let original = Data("existing export".utf8)
        try original.write(to: url)
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: renderer.maxTextureSize + 1, height: 7))
        let task = Task {
            try await service.writeImage(image, params: Params(), assets: ExportAssets(params: Params()), format: .png, to: url) { tile, _ in
                if tile == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("导出应响应取消") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let result = try await service.writeImage(image, params: Params(), assets: ExportAssets(params: Params()), format: .png, to: url)
        XCTAssertEqual(result.width, renderer.maxTextureSize + 1)
    }

    func testPreviewCanExplicitlyDownscaleOversizeSource() throws {
        let renderer = try Renderer()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: renderer.maxTextureSize + 1, height: 100))
        try renderer.setImage(ci: image, maxSide: 320)
        XCTAssertEqual(renderer.imageSize.width, 320)
        XCTAssertGreaterThan(renderer.imageSize.height, 0)
    }

    func testOversizeBitmapPreservesEveryPixelAndOrientation() throws {
        let renderer = try Renderer()
        for (width, height) in [(renderer.maxTextureSize + 5, 17), (17, renderer.maxTextureSize + 5)] {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x % 256); pixels[i + 1] = UInt8(y % 256); pixels[i + 2] = UInt8((x + y * 11) % 256)
            } }
            let original = try XCTUnwrap(Exporter.cgImage(rgba: pixels, width: width, height: height))
            let source = CIImage(cgImage: original).transformed(by: CGAffineTransform(translationX: 13, y: -7))
            let result = try Exporter.render(source, using: renderer, params: Params(), format: .png)
            let bytes = [UInt8](try XCTUnwrap(result.dataProvider?.data) as Data)
            XCTAssertEqual(bytes.count, pixels.count)
            let maximum = zip(bytes, pixels).map { abs(Int($0) - Int($1)) }.max()
            XCTAssertLessThanOrEqual(try XCTUnwrap(maximum), 1)
        }
    }

    func testInvalidExtentAndFailedEncodingPreserveExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.jpg"), original = Data("existing export".utf8)
        try original.write(to: url)
        let renderer = try Renderer(), service = ExportService(device: renderer.device)
        for source in [CIImage(color: .red), CIImage.empty()] {
            do {
                _ = try await service.writeImage(source, params: Params(), assets: ExportAssets(params: Params()), format: .png, to: url)
                XCTFail("无限或空尺寸应报错")
            } catch { XCTAssertTrue(error is RenderError) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        // JPEG 格式本身无法编码这个宽度；失败必须发生在临时文件上。
        let tooWideForJPEG = try XCTUnwrap(Exporter.cgImage(rgba: [UInt8](repeating: 255, count: 70000 * 4), width: 70000, height: 1))
        XCTAssertThrowsError(try Exporter.write(tooWideForJPEG, to: url, format: .jpeg))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
        try Exporter.write(tooWideForJPEG, to: url, format: .png)
        XCTAssertNotEqual(try Data(contentsOf: url), original)
    }
}
