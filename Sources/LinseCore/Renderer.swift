// Metal 渲染器：唯一的"参数 → 像素"实现。预览（MTKView）、估计器（读回小图）、导出（分块读回）都用它。
import CoreGraphics
import CoreImage
import Foundation
import Metal
import MetalKit
import simd

public enum RenderError: Error, LocalizedError {
    case noDevice, shader(String), texture(String)
    public var errorDescription: String? {
        switch self {
        case .noDevice: return "这台设备不支持 Metal"
        case .shader(let s): return "着色器编译失败：\(s)"
        case .texture(let s): return "纹理创建失败：\(s)"
        }
    }
}

struct Uniforms {
    var wb0 = SIMD4<Float>(), wb1 = SIMD4<Float>(), wb2 = SIMD4<Float>()
    var p0 = SIMD4<Float>(), p1 = SIMD4<Float>(), p2 = SIMD4<Float>(), p3 = SIMD4<Float>()
    var p4 = SIMD4<Float>(), p5 = SIMD4<Float>(), p6 = SIMD4<Float>(), p7 = SIMD4<Float>()
    var region = SIMD4<Float>(0, 0, 1, 1)
    var gradeSh = SIMD4<Float>(), gradeMid = SIMD4<Float>(), gradeHi = SIMD4<Float>(), gradeLum = SIMD4<Float>()
}

struct MaskU {
    var A = SIMD4<Float>(), B = SIMD4<Float>(), C = SIMD4<Float>(), D = SIMD4<Float>(), E = SIMD4<Float>()
    var wb0 = SIMD4<Float>(1, 0, 0, 0), wb1 = SIMD4<Float>(0, 1, 0, 0), wb2 = SIMD4<Float>(0, 0, 1, 0)
}

public struct RenderOptions {
    public var region = SIMD4<Float>(0, 0, 1, 1) // 原图中的区域（左上原点，归一化）
    public var showMask = -1
    public var bypass = false
    public init(region: SIMD4<Float> = SIMD4(0, 0, 1, 1), showMask: Int = -1, bypass: Bool = false) {
        self.region = region; self.showMask = showMask; self.bypass = bypass
    }
}

/// 导入的 3D LUT（.cube 解析后的数据），按 id 查找
public protocol LutProvider: AnyObject { func lut(id: String) -> CubeLut? }

public final class Renderer {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    let curveTex: MTLTexture, hslTex: MTLTexture
    var lutTex: MTLTexture
    var lutTexId: String?
    public private(set) var image: MTLTexture?
    public var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    public weak var luts: LutProvider?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError.noDevice }
        self.device = device
        queue = device.makeCommandQueue()!
        do { library = try device.makeLibrary(source: shaderSource, options: nil) } catch { throw RenderError.shader(error.localizedDescription) }
        func tex1D(_ w: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: 1, mipmapped: false)
            d.usage = .shaderRead
            return device.makeTexture(descriptor: d)!
        }
        curveTex = tex1D(256)
        hslTex = tex1D(360)
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D; d3.pixelFormat = .rgba32Float; d3.width = 2; d3.height = 2; d3.depth = 2; d3.usage = .shaderRead
        lutTex = device.makeTexture(descriptor: d3)!
    }

    func pipeline(_ fmt: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = pipelines[fmt] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vmain")
        d.fragmentFunction = library.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = fmt
        let p = try device.makeRenderPipelineState(descriptor: d)
        pipelines[fmt] = p
        return p
    }

    // MARK: 图片

    /// 载入图片为带 mipmap 的纹理（清晰度、去雾、锐化要用 mipmap 取低频）。像素按 sRGB 编码值存放，不做自动解码。
    public func setImage(_ cg: CGImage) throws {
        let loader = MTKTextureLoader(device: device)
        image = try loader.newTexture(cgImage: cg, options: [
            .SRGB: false, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue, .origin: MTKTextureLoader.Origin.topLeft,
        ])
    }

    /// 直接用 RGBA8 像素建图（估计器测目标图、烘焙 LUT 网格用）
    public func setImage(rgba: [UInt8], width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let cb = queue.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
        bl.generateMipmaps(for: t); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        image = t
    }

    public func setImage(texture: MTLTexture) { image = texture }

    public lazy var ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])

    /// 用 Core Image 载入（HEIC、RAW 都走这里），存成 16 位浮点纹理：保留相机 RAW 超过 8 位的精度。
    /// maxSide 限制长边（显卡纹理上限、或估计器用的小图）。
    public func setImage(ci: CIImage, maxSide: Int? = nil) throws {
        var img = ci
        let ext = img.extent.integral
        var w = Int(ext.width), h = Int(ext.height)
        let limit = min(maxSide ?? maxTextureSize, maxTextureSize)
        if max(w, h) > limit {
            let s = Double(limit) / Double(max(w, h))
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(img, forKey: kCIInputImageKey); f.setValue(s, forKey: kCIInputScaleKey); f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            img = f.outputImage!
            w = max(1, Int((Double(w) * s).rounded())); h = max(1, Int((Double(h) * s).rounded()))
        }
        // 移到原点，并上下翻转：Core Image 原点在左下，纹理第 0 行在上
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h)))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { throw RenderError.texture("\(w)×\(h)") }
        // 按 sRGB 编码值写入（着色器里自己做线性化），和 Electron 版的输入一致
        ciContext.render(img, to: t, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let bl = cb.makeBlitCommandEncoder()!
        bl.generateMipmaps(for: t); bl.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        image = t
    }
    public func releaseImage() { image = nil }

    // MARK: 渲染

    func uniforms(_ p: Params, outWidth: Int, opts: RenderOptions) -> (Uniforms, [MaskU]) {
        guard let img = image else { return (Uniforms(), []) }
        let W = Float(img.width), H = Float(img.height)
        var u = Uniforms()
        let wb = WhiteBalance.matrix(temperature: p.temperature, tint: p.tint)
        u.wb0 = SIMD4(wb[0], wb[1], wb[2], 0); u.wb1 = SIMD4(wb[3], wb[4], wb[5], 0); u.wb2 = SIMD4(wb[6], wb[7], wb[8], 0)
        u.p0 = SIMD4(Float(p.exposure), Float(p.contrast / 100), Float(p.highlights / 100), Float(p.shadows / 100))
        u.p1 = SIMD4(Float(p.whites / 100), Float(p.blacks / 100), Float(p.vibrance / 100), Float(p.saturation / 100))
        let e = p.effects
        u.p2 = SIMD4(Float(e.clarity / 100), Float(e.dehaze / 100), Float(e.vignette / 100), Float(e.grain / 100))
        let lod = max(0, log2(max(W, H) / 48))
        let viewLod = max(0, log2(W * opts.region.z / Float(max(outWidth, 1))))
        u.p3 = SIMD4(Float(e.grainSize / 100), Float(e.sharpen / 100), lod, viewLod)
        var lutAmt: Float = 0, lutSize: Float = 2
        if let ref = p.lut, let l = luts?.lut(id: ref.id) {
            if lutTexId != l.id { lutTex = makeLut3D(l); lutTexId = l.id }
            lutAmt = Float(ref.intensity / 100); lutSize = Float(l.size)
        }
        u.p4 = SIMD4(lutAmt, lutSize, Float(p.grading.balance / 100), Float(p.grading.blending / 100))
        let masks = Array(p.masks.prefix(Params.maxMasks))
        u.p5 = SIMD4(W / H, Float(opts.showMask), opts.bypass ? 1 : 0, Float(masks.count))
        let doCurve = Curves.channels.contains { !Curve.isIdentity(p.curves[keyPath: $0]) }
        let doHsl = !HSLTable.isIdentity(p)
        let g = p.grading
        let doGrade = [g.shadows, g.midtones, g.highlights].contains { $0.sat != 0 || $0.lum != 0 } || g.balance != 0
        u.p6 = SIMD4(doCurve ? 1 : 0, doHsl ? 1 : 0, doGrade ? 1 : 0, 0)
        u.p7 = SIMD4(W, H, 0, 0)
        u.region = opts.region
        u.gradeSh = SIMD4(gradeOffset(g.shadows), 0); u.gradeMid = SIMD4(gradeOffset(g.midtones), 0); u.gradeHi = SIMD4(gradeOffset(g.highlights), 0)
        u.gradeLum = SIMD4(Float(g.shadows.lum / 100), Float(g.midtones.lum / 100), Float(g.highlights.lum / 100), 0)
        if doCurve { upload(Curve.lut(p), to: curveTex, width: 256) }
        if doHsl { upload(HSLTable.build(p), to: hslTex, width: 360) }
        var mu = masks.map { m -> MaskU in
            var x = MaskU()
            x.A = SIMD4(Float(m.cx), Float(m.cy), Float(m.rx), Float(m.ry))
            let type: Float = m.type == .radial ? 0 : m.type == .linear ? 1 : 2
            x.B = SIMD4(Float(m.x2), Float(m.y2), Float(m.feather / 100), type)
            x.C = SIMD4(Float(m.lumMin / 100), Float(m.lumMax / 100), m.invert ? 1 : 0, m.enabled ? 1 : 0)
            x.D = SIMD4(Float(m.adjust.exposure), Float(m.adjust.contrast), 0, 0)
            x.E = SIMD4(Float(m.adjust.saturation), 0, 0, 0)
            let w = WhiteBalance.matrix(temperature: m.adjust.temperature, tint: m.adjust.tint)
            x.wb0 = SIMD4(w[0], w[1], w[2], 0); x.wb1 = SIMD4(w[3], w[4], w[5], 0); x.wb2 = SIMD4(w[6], w[7], w[8], 0)
            return x
        }
        if mu.isEmpty { mu = [MaskU()] } // 缓冲不能为空
        return (u, mu)
    }

    func upload(_ data: [Float], to t: MTLTexture, width: Int) {
        data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
    }

    func makeLut3D(_ l: CubeLut) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D; d.pixelFormat = .rgba32Float; d.width = l.size; d.height = l.size; d.depth = l.size; d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        l.data.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, l.size, l.size, l.size), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: l.size * 16, bytesPerImage: l.size * l.size * 16)
        }
        return t
    }

    /// 编码一次绘制到目标纹理（预览直接画到 drawable）
    public func encode(_ p: Params, into target: MTLTexture, commandBuffer cb: MTLCommandBuffer, opts: RenderOptions = RenderOptions(), clear: MTLClearColor? = nil,
                       viewport: MTLViewport? = nil, scissor: MTLScissorRect? = nil) throws {
        guard let img = image else { return }
        let (u, masks) = uniforms(p, outWidth: Int(viewport?.width ?? Double(target.width)), opts: opts)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = clear == nil ? .load : .clear
        if let clear { rp.colorAttachments[0].clearColor = clear }
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(try pipeline(target.pixelFormat))
        if let viewport { enc.setViewport(viewport) }
        if let scissor { enc.setScissorRect(scissor) }
        var uu = u
        enc.setFragmentBytes(&uu, length: MemoryLayout<Uniforms>.stride, index: 0)
        masks.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setFragmentTexture(img, index: 0)
        enc.setFragmentTexture(curveTex, index: 1)
        enc.setFragmentTexture(hslTex, index: 2)
        enc.setFragmentTexture(lutTex, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// 渲染并读回 RGBA8（行自上而下）。估计器、直方图、导出用。
    public func renderRGBA8(_ p: Params, width: Int, height: Int, opts: RenderOptions = RenderOptions()) throws -> [UInt8] {
        let t = try offscreen(.rgba8Unorm, width, height)
        let cb = queue.makeCommandBuffer()!
        try encode(p, into: t, commandBuffer: cb, opts: opts)
        cb.commit(); cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return out
    }

    /// 渲染并读回 RGBA float（16 位导出用）
    public func renderFloat(_ p: Params, width: Int, height: Int, opts: RenderOptions = RenderOptions()) throws -> [Float] {
        let t = try offscreen(.rgba32Float, width, height)
        let cb = queue.makeCommandBuffer()!
        try encode(p, into: t, commandBuffer: cb, opts: opts)
        cb.commit(); cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return out
    }

    var offscreenCache: [String: MTLTexture] = [:]
    func offscreen(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
        let key = "\(fmt.rawValue)-\(w)x\(h)"
        if let t = offscreenCache[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.texture("\(w)×\(h)") }
        if offscreenCache.count > 8 { offscreenCache.removeAll() }
        offscreenCache[key] = t
        return t
    }

    public var maxTextureSize: Int { device.supportsFamily(.apple3) ? 16384 : 8192 }
    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }
}
