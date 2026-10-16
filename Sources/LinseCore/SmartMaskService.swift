import CoreImage
import Metal

/// 识别任务独占上下文，不借用主界面的渲染器或图像处理资源。
public actor SmartMaskService {
    public typealias Compute = @Sendable (MaskType, CIImage, CIContext) async throws -> MaskBitmap
    private let device: MTLDevice
    private let compute: Compute

    public init(device: MTLDevice, compute: @escaping Compute = { try SmartMask.compute($0, image: $1, context: $2) }) {
        self.device = device
        self.compute = compute
    }

    public func detect(_ kind: MaskType, image: CIImage) async throws -> MaskBitmap {
        try Task.checkCancellation()
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let bitmap = try await compute(kind, image, context)
        try Task.checkCancellation()
        return bitmap
    }
}
