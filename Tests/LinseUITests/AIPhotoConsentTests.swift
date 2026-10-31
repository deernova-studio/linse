import CoreImage
import ImageIO
import LinseCore
import Metal
@testable import LinseUI
import XCTest

@MainActor
final class AIPhotoConsentTests: XCTestCase {
    func testNoRequestBeforeApprovalAndCancelledApprovalCannotBeReused() throws {
        let (state, directory) = try makeState { _, _, _ in
            XCTFail("未同意不能发送照片")
            throw AIError("unexpected")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        state.runMatch(useAI: true)
        let request = try XCTUnwrap(state.aiPhotoConsent)
        XCTAssertNil(state.aiTask)
        XCTAssertNil(state.busy)
        XCTAssertEqual(request.recipient, "https://api.openai.com/v1")
        state.aiPhotoConsent = nil
        state.confirmAIPhotoConsent(request.id)
        XCTAssertNil(state.aiTask)
    }

    func testChangedImageOrServiceInvalidatesApproval() throws {
        let (state, directory) = try makeState { _, _, _ in
            XCTFail("换图或换服务后不能沿用旧授权")
            throw AIError("unexpected")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        state.runMatch(useAI: true)
        let imageRequest = try XCTUnwrap(state.aiPhotoConsent)
        state.load(CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)),
                   name: "changed", into: .target)
        state.confirmAIPhotoConsent(imageRequest.id)
        XCTAssertNil(state.aiTask)

        state.runMatch(useAI: true)
        let serviceRequest = try XCTUnwrap(state.aiPhotoConsent)
        state.aiSettings.baseUrl = "https://another.example/v1"
        state.confirmAIPhotoConsent(serviceRequest.id)
        XCTAssertNil(state.aiTask)
        XCTAssertTrue(state.toast?.contains("已更改") == true)
    }

    func testApprovedPhotosStripLocationAndCameraMetadata() async throws {
        let called = expectation(description: "同意后才发送缩小图")
        let (state, directory) = try makeState { _, key, images in
            XCTAssertEqual(key, "consent-test")
            for encoded in [images.source, images.target] {
                let data = try XCTUnwrap(Data(base64Encoded: encoded))
                let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
                XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
                // 编码器可生成尺寸和色彩空间字段；原照片的私人 EXIF 不得保留。
                let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
                XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
                XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber as String])
                XCTAssertNil(exif?[kCGImagePropertyExifLensSerialNumber as String])
                let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
                XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String])
                XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth as String] as? Int ?? .max, 1024)
                XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight as String] as? Int ?? .max, 1024)
            }
            called.fulfill()
            throw AIError("test-stop")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 800))
            .settingProperties([
                kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 30.0],
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "private camera"],
                kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:01:01 00:00:00",
                    kCGImagePropertyExifBodySerialNumber as String: "private-body",
                    kCGImagePropertyExifLensSerialNumber as String: "private-lens"],
            ])
        state.load(image, name: "private-name.jpg", into: .source)
        state.runMatch(useAI: true)
        let request = try XCTUnwrap(state.aiPhotoConsent)
        state.confirmAIPhotoConsent(UUID())
        XCTAssertNil(state.aiTask)
        state.confirmAIPhotoConsent(request.id)
        await state.aiTask?.value
        await fulfillment(of: [called], timeout: 5)
        XCTAssertNil(state.aiPhotoConsent)
        XCTAssertNil(state.busy)
        state.runMatch(useAI: true)
        XCTAssertNotNil(state.aiPhotoConsent, "下一次上传需要独立授权")
    }

    private func makeState(_ analyze: @escaping MatchService.Analyze) throws -> (AppState, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linse-consent-\(UUID().uuidString)")
        let service = MatchService(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), analyze: analyze)
        let state = AppState(luts: LutStore(dir: directory), matchService: service, aiKeyProvider: { "consent-test" })
        for kind in [AppState.SlotKind.source, .target] {
            state.load(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)),
                       name: kind.title, into: kind)
        }
        state.aiHasKey = true
        return (state, directory)
    }
}
