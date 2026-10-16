import CoreImage
import Foundation
import Metal

/// 在主线程创建导出任务时捕获依赖的值；之后删除 LUT、重置蒙版库都不会改变该任务。
public struct ExportAssets: Sendable {
    fileprivate let lut: CubeLut?
    fileprivate let masks: [MaskType: MaskBitmap]

    public init(params: Params, luts: LutProvider? = nil, maskBitmaps: MaskBitmapProvider? = nil) {
        lut = params.lut.flatMap { luts?.lut(id: $0.id) }
        var masks: [MaskType: MaskBitmap] = [:]
        for mask in params.masks where mask.type.isSmart {
            masks[mask.type] = maskBitmaps?.maskBitmap(mask.type)
        }
        self.masks = masks
    }
}

private final class ExportAssetProvider: LutProvider, MaskBitmapProvider {
    let assets: ExportAssets
    init(_ assets: ExportAssets) { self.assets = assets }
    func lut(id: String) -> CubeLut? { assets.lut.flatMap { $0.id == id ? $0 : nil } }
    func maskBitmap(_ kind: MaskType) -> MaskBitmap? { assets.masks[kind] }
}

/// 图片与 LUT 导出共用一个串行执行者。渲染器不离开 actor；每项操作内没有 await，
/// 因而从设置输入、逐块绘制直到写出完成，都不会被另一项导出插入。
public actor ExportService {
    private let device: MTLDevice
    private var renderer: Renderer?

    public init(device: MTLDevice) { self.device = device }

    public func writeImage(_ source: CIImage, params: Params, assets: ExportAssets, format: ExportFormat, to url: URL,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> CGImage {
        try Task.checkCancellation()
        return try withRenderer(assets: assets) { renderer in
            let image = try Exporter.render(source, using: renderer, params: params, format: format, progress: progress)
            try Task.checkCancellation()
            try Exporter.write(image, to: url, format: format)
            return image
        }
    }

    public func lutText(params: Params, assets: ExportAssets, title: String, size: Int = 33) throws -> String {
        try Task.checkCancellation()
        return try withRenderer(assets: assets) { renderer in
            let text = try CubeLut.bake(renderer, params, title: title, size: size)
            try Task.checkCancellation()
            return text
        }
    }

    private func withRenderer<T>(assets: ExportAssets, _ body: (Renderer) throws -> T) throws -> T {
        let renderer = try self.renderer ?? Renderer(device: device)
        self.renderer = renderer
        let provider = ExportAssetProvider(assets)
        renderer.luts = provider
        renderer.maskBitmaps = provider
        defer {
            renderer.releaseImage()
            renderer.offscreenCache.removeAll()
            renderer.maskTexCache.removeAll()
            renderer.luts = nil
            renderer.maskBitmaps = nil
        }
        // Renderer 的 provider 为 weak，必须覆盖整个导出操作的生命周期。
        return try withExtendedLifetime(provider) { try body(renderer) }
    }
}
