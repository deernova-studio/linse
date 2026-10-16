import CoreImage
import Metal
import simd

/// 原图和各级 mip 都按块读取；空间滤镜仍按全图网格采样，输入纹理不超过设备上限。
final class TiledImageSource {
    let width: Int, height: Int
    private let source: CIImage
    private let renderer: Renderer
    private let sharpEnabled: Bool
    private var sharpPixels: MappedRaster?
    private var blur: MTLTexture?
    private let blurBaseLevel: Int

    init(_ source: CIImage, renderer: Renderer, params: Params) throws {
        (width, height) = try Renderer.imageDimensions(source)
        self.source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        self.renderer = renderer
        sharpEnabled = params.effects.sharpen > 0
        blurBaseLevel = max(0, Int(floor(log2(Double(max(width, height)) / 48))))
        let needsBlur = params.effects.clarity != 0 || params.effects.dehaze > 0
        let maxLevel = Int(floor(log2(Double(max(width, height)))))
        if needsBlur {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: max(1, width >> blurBaseLevel), height: max(1, height >> blurBaseLevel), mipmapped: true)
            descriptor.mipmapLevelCount = min(3, maxLevel - blurBaseLevel + 1)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw RenderError.texture("导出低频图") }
            blur = texture
            if blurBaseLevel == 0 {
                let original = try sourceTexture(CGRect(x: 0, y: 0, width: width, height: height))
                guard let command = renderer.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                    throw RenderError.texture("低频图命令")
                }
                blit.copy(from: original, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
                blit.endEncoding(); try Self.finish(command)
            }
        }
        let lastLevel = min(maxLevel, needsBlur ? blurBaseLevel + 2 : sharpEnabled ? 1 : 0)
        if lastLevel > 0 {
            var previous: MappedRaster?
            for level in 1...lastLevel {
                let next = try downsample(previous)
                if level == 1 && sharpEnabled { sharpPixels = next }
                if let blur, level >= blurBaseLevel {
                    blur.replace(region: MTLRegionMake2D(0, 0, next.width, next.height), mipmapLevel: level - blurBaseLevel,
                                 withBytes: next.pointer, bytesPerRow: next.width * 8)
                }
                previous = next
            }
        }
    }

    func load(_ rect: CGRect) throws {
        try Task.checkCancellation()
        let area = rect.insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try sourceTexture(area)
        var sharp: MTLTexture?
        var sharpRegion = SIMD4<Float>(0, 0, 1, 1)
        if let pixels = sharpPixels {
            let mw = CGFloat(pixels.width), mh = CGFloat(pixels.height)
            let mipArea = CGRect(x: rect.minX / CGFloat(width) * mw, y: rect.minY / CGFloat(height) * mh,
                                 width: rect.width / CGFloat(width) * mw, height: rect.height / CGFloat(height) * mh)
                .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: mw, height: mh))
            sharp = try texture(pixels, area: mipArea)
            sharpRegion = Self.region(mipArea, width: mw, height: mh)
        } else if sharpEnabled { sharp = image }
        renderer.setTile(texture: image, input: TiledRenderInput(size: CGSize(width: width, height: height),
            region: Self.region(area, width: CGFloat(width), height: CGFloat(height)), sharpRegion: sharpRegion,
            sharp: sharp, blur: blur, blurBaseLevel: blurBaseLevel))
    }

    private func downsample(_ previous: MappedRaster?) throws -> MappedRaster {
        let sw = previous?.width ?? width, sh = previous?.height ?? height
        let dw = max(1, sw / 2), dh = max(1, sh / 2)
        let output = try MappedRaster(width: dw, height: dh, bytesPerPixel: 8)
        for y in stride(from: 0, to: dh, by: 2048) { for x in stride(from: 0, to: dw, by: 2048) {
            try autoreleasepool {
                try Task.checkCancellation()
                let w = min(2048, dw - x), h = min(2048, dh - y)
                let area = CGRect(x: Double(x) * Double(sw) / Double(dw), y: Double(y) * Double(sh) / Double(dh),
                                  width: Double(w) * Double(sw) / Double(dw), height: Double(h) * Double(sh) / Double(dh))
                    .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: sw, height: sh))
                let input = try previous.map { try texture($0, area: area) } ?? sourceTexture(area)
                let target = try renderer.offscreen(.rgba16Float, w, h)
                guard let command = renderer.makeCommandBuffer() else {
                    throw RenderError.texture("分块降采样命令")
                }
                try renderer.encodeDownsample(input, into: target, sourceSize: CGSize(width: sw, height: sh), inputArea: area,
                    outputOrigin: CGPoint(x: x, y: y), outputSize: CGSize(width: dw, height: dh), command: command)
                try Self.finish(command)
                target.getBytes(output.pixel(x, y), bytesPerRow: dw * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        } }
        return output
    }

    private static func region(_ area: CGRect, width: CGFloat, height: CGFloat) -> SIMD4<Float> {
        SIMD4(Float(area.minX / width), Float(area.minY / height), Float(area.width / width), Float(area.height / height))
    }

    private func texture(_ pixels: MappedRaster, area: CGRect) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: Int(area.width), height: Int(area.height), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw RenderError.texture("导出 mip 输入块") }
        texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                        withBytes: pixels.pixel(Int(area.minX), Int(area.minY)), bytesPerRow: pixels.width * 8)
        return texture
    }

    private func sourceTexture(_ topArea: CGRect) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: Int(topArea.width), height: Int(topArea.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: descriptor), let command = renderer.makeCommandBuffer() else {
            throw RenderError.texture("导出输入块")
        }
        // 先使用固定的全图变换，再指定读取范围，避免每块重建翻转变换造成长边采样误差。
        let image = source.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        renderer.ciContext.render(image, to: texture, commandBuffer: command,
            bounds: topArea, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try Self.finish(command)
        return texture
    }

    private static func finish(_ command: MTLCommandBuffer) throws {
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }
}
