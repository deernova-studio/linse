import CoreImage
import ImageIO
import LinseCore
@testable import LinseUI
import UniformTypeIdentifiers
import XCTest

final class ImageInspectionTests: XCTestCase {
    func testImageDetailsReadFileAndPhotoDataConsistently() throws {
        let data = try sampleJPEG()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linse-details-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let metadata = ImageMetadata.read(from: data)
        XCTAssertEqual(metadata, ImageMetadata.read(from: url))
        XCTAssertEqual(metadata.format, "JPEG")
        XCTAssertEqual(metadata.byteCount, Int64(data.count))
        XCTAssertEqual(metadata.bitDepth, 8)
        XCTAssertEqual(metadata.camera, "Test Camera 1")
        XCTAssertEqual(metadata.lens, "Test 35 mm")
        XCTAssertEqual(metadata.capturedAt, "2026-10-19 12:30:45")
    }

    func testLargePreviewIsBoundedAndSmallPreviewIsNotUpscaled() async throws {
        let service = ImagePreviewService()
        let large = CIImage(color: .red).cropped(to: CGRect(x: 30, y: 50, width: 20000, height: 10000))
        let preview = try await service.preview(large, maxDimension: 1024)
        XCTAssertEqual(preview.width, 1024)
        XCTAssertEqual(preview.height, 512)
        let small = CIImage(color: .blue).cropped(to: CGRect(x: 10, y: 20, width: 40, height: 80))
        let original = try await service.preview(small)
        XCTAssertEqual(original.width, 40)
        XCTAssertEqual(original.height, 80)
    }

    @MainActor
    func testInspectionPreservesEditsAndReplacementUpdatesOnlyItsSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-inspection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(luts: LutStore(dir: directory), aiKeyProvider: { "" })
        let data = try sampleJPEG()
        await state.load(data: data, name: "source.jpg", into: .source)
        await state.load(data: data, name: "target.jpg", into: .target)
        state.params.exposure = 0.5
        let source = try XCTUnwrap(state.source)
        let targetID = state.target?.id
        let before = state.params
        XCTAssertEqual(source.size, CGSize(width: 8, height: 16), "详情尺寸应与旋转后的预览一致")

        state.inspectOrImport(.source)
        XCTAssertEqual(state.inspectedSlot, .source)
        XCTAssertEqual(state.source?.id, source.id)
        XCTAssertEqual(state.params, before)
        await state.load(data: Data("not an image".utf8), name: "broken.jpg", into: .source)
        XCTAssertEqual(state.source?.id, source.id, "选择无效文件不能清空已有图片")

        await state.load(data: data, name: "replacement.jpg", into: .source)
        XCTAssertNotEqual(state.source?.id, source.id)
        XCTAssertEqual(state.slot(for: .source)?.name, "replacement.jpg")
        XCTAssertEqual(state.source?.metadata.byteCount, Int64(data.count))
        XCTAssertEqual(state.target?.id, targetID)
        XCTAssertEqual(state.params, before)
        XCTAssertEqual(state.inspectedSlot, .source)
    }

    private func sampleJPEG() throws -> Data {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test", kCGImagePropertyTIFFModel: "Test Camera 1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test 35 mm", kCGImagePropertyExifDateTimeOriginal: "2026:10:19 12:30:45"],
        ]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
