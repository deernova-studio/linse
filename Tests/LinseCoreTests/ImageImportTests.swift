import CoreImage
import ImageIO
@testable import LinseCore
import UniformTypeIdentifiers
import XCTest

final class ImageImportTests: XCTestCase {
    func testContentDetectionAndOrientationIgnoreMisleadingFilename() async throws {
        let data = try jpeg(orientation: 6)
        let image = try await ImageImportService().load(data: data, name: "renamed.ARW")
        XCTAssertFalse(image.metadata.isRAW)
        XCTAssertEqual(image.metadata.format, "JPEG")
        XCTAssertEqual(image.image.extent.size, CGSize(width: 16, height: 32))
        XCTAssertEqual(image.thumbnail.width, 16)
        XCTAssertEqual(image.thumbnail.height, 32)
    }

    func testImportedImageRemainsReadableAfterOriginalFileIsRemoved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linse-import-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try jpeg().write(to: url)
        let image = try await ImageImportService().load(url)
        try FileManager.default.removeItem(at: url)
        let rendered = try await ImagePreviewService().preview(image.image)
        XCTAssertEqual(rendered.width, 32)
        XCTAssertEqual(rendered.height, 16)
    }

    func testCorruptRAWAndInvalidImageHaveActionableErrors() async throws {
        let service = ImageImportService()
        for (name, expected) in [("bad.CR3", ImageImportError.rawDecodingFailed), ("bad.txt", .invalidImage)] {
            do {
                _ = try await service.load(data: Data("invalid".utf8), name: name)
                XCTFail("Invalid input must not be accepted")
            } catch { XCTAssertEqual(error as? ImageImportError, expected) }
        }
        do {
            _ = try await service.load(URL(fileURLWithPath: "/nonexistent/linse-\(UUID()).dng"))
            XCTFail("Missing file must fail")
        } catch { XCTAssertEqual(error as? ImageImportError, .unreadableFile) }
    }

    func testTruncatedImageIsRejectedBeforeReplacingAnExistingPhoto() async throws {
        let data = try jpeg()
        do {
            _ = try await ImageImportService().load(data: data.prefix(data.count / 2), name: "truncated.jpg")
            XCTFail("Incomplete images must fail")
        } catch { XCTAssertEqual(error as? ImageImportError, .invalidImage) }
    }

    func testAppleBayerDNG() async throws { try await checkCameraFile("915.dng") }
    func testAppleProRAWDNG() async throws { try await checkCameraFile("4264.dng") }
    func testCanonCR2() async throws { try await checkCameraFile("1018.cr2") }
    func testCanonCompressedCR3() async throws { try await checkCameraFile("4659.cr3") }
    func testNikonCompressedNEF() async throws { try await checkCameraFile("1325.nef") }
    func testSonyCompressedARW() async throws { try await checkCameraFile("1581.arw") }
    func testFujifilmXTransRAF() async throws { try await checkCameraFile("2421.raf") }
    func testOlympusORF() async throws { try await checkCameraFile("1803.orf") }
    func testPanasonicRW2() async throws { try await checkCameraFile("1772.rw2") }

    func testRAWDataWithoutFileExtensionAndLaterRender() async throws {
        let url = try cameraFile("915.dng")
        let image = try await ImageImportService().load(data: Data(contentsOf: url), name: "照片")
        XCTAssertTrue(image.metadata.isRAW)
        let renderer = try Renderer()
        try renderer.setImage(ci: image.image, maxSide: 256)
        XCTAssertEqual(renderer.image?.pixelFormat, .rgba16Float, "RAW 编辑输入不能降为 8 位")
        XCTAssertNotNil(renderer.image)
    }

    func testTIFFBasedRAWIsIdentifiedWithoutAnExtension() async throws {
        for name in ["1325.nef", "1581.arw"] {
            let image = try await ImageImportService().load(data: Data(contentsOf: cameraFile(name)), name: "照片")
            XCTAssertTrue(image.metadata.isRAW, name)
            XCTAssertGreaterThan(image.image.extent.width, 4000, "不能把 TIFF 容器里的小预览当成 RAW 主图")
            XCTAssertNotEqual(image.metadata.format, "TIFF")
        }
    }

    func testOrdinary16BitTIFFIsNotMisclassifiedAsRAW() async throws {
        let ci = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let data = try XCTUnwrap(CIContext().tiffRepresentation(of: ci, format: .RGBA16, colorSpace: space))
        let image = try await ImageImportService().load(data: data, name: "photo.tiff")
        XCTAssertFalse(image.metadata.isRAW)
        XCTAssertEqual(image.metadata.bitDepth, 16)
        XCTAssertEqual(image.image.extent.size, CGSize(width: 32, height: 16))
    }

    func testTruncatedRAWIsRejected() async throws {
        let data = try Data(contentsOf: cameraFile("915.dng"))
        do {
            _ = try await ImageImportService().load(data: data.prefix(4096), name: "broken.dng")
            XCTFail("损坏 RAW 不能退回内嵌预览")
        } catch { XCTAssertEqual(error as? ImageImportError, .rawDecodingFailed) }
    }

    func testRAWExportsAtOriginalDimensionsIn16BitTIFF() async throws {
        let image = try await ImageImportService().load(try cameraFile("915.dng"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linse-raw-export-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = try Renderer()
        let service = ExportService(device: renderer.device)
        let exported = try await service.writeImage(image.image, params: Params(), assets: ExportAssets(params: Params()), format: .tiff16, to: url)
        XCTAssertEqual(exported.width, 4032)
        XCTAssertEqual(exported.height, 3024)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(bitmap.bitsPerComponent, 16)
        XCTAssertEqual(bitmap.width, exported.width)
        XCTAssertEqual(bitmap.height, exported.height)
    }

    private func checkCameraFile(_ name: String) async throws {
        let image = try await ImageImportService().load(try cameraFile(name))
        XCTAssertTrue(image.metadata.isRAW, name)
        XCTAssertNotNil(image.metadata.camera, name)
        XCTAssertGreaterThan(image.image.extent.width * image.image.extent.height, 1_000_000, "应读取主图，不能使用小缩略图")
        XCTAssertLessThanOrEqual(max(image.thumbnail.width, image.thumbnail.height), 400)
        let pixels = try XCTUnwrap(image.thumbnail.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 32, "照片预览不能是空白或纯色占位图")
    }

    private func cameraFile(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = ProcessInfo.processInfo.environment["LINSE_RAW_SAMPLES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("build/raw-samples")
        let file = directory.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "Run python3 scripts/fetch-raw-samples.py for the camera matrix")
        return file
    }

    private func jpeg(orientation: Int = 1) throws -> Data {
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
