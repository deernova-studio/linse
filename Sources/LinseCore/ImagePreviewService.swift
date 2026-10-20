import CoreImage
import Foundation

/// 详情预览在独立任务中缩小原图，避免为超大照片分配原尺寸位图或阻塞主界面。
public actor ImagePreviewService {
    private let context = CIContext(options: [.cacheIntermediates: false])
    public init() {}

    public func preview(_ image: CIImage, maxDimension: Int = 2560) throws -> CGImage {
        try Task.checkCancellation()
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, extent.width.isFinite, extent.height.isFinite, maxDimension > 0 else {
            throw PreviewError.invalidImage
        }
        let scale = min(1, CGFloat(maxDimension) / max(extent.width, extent.height))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let reduced = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: max(1, floor(extent.width * scale)), height: max(1, floor(extent.height * scale)))
        guard let preview = context.createCGImage(reduced, from: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PreviewError.renderingFailed
        }
        try Task.checkCancellation()
        return preview
    }

    private enum PreviewError: LocalizedError {
        case invalidImage, renderingFailed
        var errorDescription: String? { "无法生成图片预览，请重新选择图片。" }
    }
}
