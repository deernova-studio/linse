// 自动识别的蒙版：人物（Vision 人像分割）、主体（Vision 前景实例）、天空（颜色与纹理 + 从顶部连通）。
// 结果是一张灰度位图（行自上而下，和纹理 uv 一致），按原图比例缩到长边 1024 以内；渲染器按 id 缓存成纹理。
import CoreImage
import Foundation
import Vision

public struct MaskBitmap: Sendable, Codable {
    public let id: String
    public let width: Int, height: Int
    public let data: [UInt8]
    public var coverage: Double { data.isEmpty ? 0 : Double(data.reduce(0) { $0 + Int($1) }) / Double(data.count * 255) }
}

public protocol MaskBitmapProvider: AnyObject { func maskBitmap(_ kind: MaskType) -> MaskBitmap? }

/// 当前原图的识别结果；换图时清空。渲染器可能在后台线程读，所以加锁
public final class SmartMaskStore: MaskBitmapProvider, @unchecked Sendable {
    private var items: [MaskType: MaskBitmap] = [:]
    private let lock = NSLock()
    public init() {}

    public func maskBitmap(_ kind: MaskType) -> MaskBitmap? { lock.lock(); defer { lock.unlock() }; return items[kind] }
    public func set(_ kind: MaskType, _ b: MaskBitmap) { lock.lock(); items[kind] = b; lock.unlock() }
    public func reset() { lock.lock(); items = [:]; lock.unlock() }
}

public enum SmartMask {
    public enum Failure: LocalizedError {
        case notFound(String), failed(String)
        public var errorDescription: String? {
            switch self { case .notFound(let s): return "没有识别到\(s)"; case .failed(let s): return s }
        }
    }

    public static func compute(_ kind: MaskType, image ci: CIImage, context ctx: CIContext) throws -> MaskBitmap {
        let e = ci.extent
        let s = min(1, 1024 / max(e.width, e.height))
        let w = max(1, Int((e.width * s).rounded())), h = max(1, Int((e.height * s).rounded()))
        let small = ci.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        guard let cg = ctx.createCGImage(small, from: CGRect(x: 0, y: 0, width: w, height: h)) else { throw Failure.failed("图片解码失败") }
        let b: MaskBitmap
        switch kind {
        case .person: b = try person(cg, w, h, ctx)
        case .subject: b = try subject(cg, w, h, ctx)
        case .sky: b = try sky(small, w, h, ctx)
        default: throw Failure.failed("不是识别类蒙版")
        }
        // 覆盖面积太小就当作没找到，免得加一个看不出效果的蒙版
        if b.coverage < 0.004 { throw Failure.notFound(kind.label) }
        return b
    }

    /// 把单通道的 CIImage 缩放到 w×h，读成 8 位灰度（行自上而下）
    static func gray(_ img: CIImage, _ w: Int, _ h: Int, _ ctx: CIContext) -> MaskBitmap {
        let ext = img.extent
        let scaled = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ext.width, y: CGFloat(h) / ext.height))
        var data = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeMutableBytes {
            ctx.render(scaled, toBitmap: $0.baseAddress!, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
        }
        return MaskBitmap(id: UUID().uuidString, width: w, height: h, data: data)
    }

    static func person(_ cg: CGImage, _ w: Int, _ h: Int, _ ctx: CIContext) throws -> MaskBitmap {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: cg).perform([req])
        guard let pb = req.results?.first?.pixelBuffer else { throw Failure.notFound("人物") }
        return gray(CIImage(cvPixelBuffer: pb), w, h, ctx)
    }

    static func subject(_ cg: CGImage, _ w: Int, _ h: Int, _ ctx: CIContext) throws -> MaskBitmap {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { throw Failure.notFound("主体") }
        let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        return gray(CIImage(cvPixelBuffer: pb), w, h, ctx)
    }

    /// 天空：系统没有现成的天空分割，这里在小图上找"亮、平滑、偏蓝或偏白"的像素，
    /// 只保留从图片顶边连通过来的那一片，再柔化边缘
    static func sky(_ img: CIImage, _ w: Int, _ h: Int, _ ctx: CIContext) throws -> MaskBitmap {
        let sw = max(8, min(256, w * 256 / max(w, h))), sh = max(8, min(256, h * 256 / max(w, h)))
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(sw) / CGFloat(w), y: CGFloat(sh) / CGFloat(h)))
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        px.withUnsafeMutableBytes {
            ctx.render(scaled, toBitmap: $0.baseAddress!, rowBytes: sw * 4, bounds: CGRect(x: 0, y: 0, width: sw, height: sh), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let n = sw * sh
        var r = [Float](repeating: 0, count: n), g = r, b = r, y = r
        for i in 0..<n {
            r[i] = Float(px[i * 4]) / 255; g[i] = Float(px[i * 4 + 1]) / 255; b[i] = Float(px[i * 4 + 2]) / 255
            y[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
        }
        // 候选：亮度够、局部平滑、偏蓝（晴天）或很亮且低饱和（阴天）
        var cand = [Bool](repeating: false, count: n)
        for yy in 0..<sh {
            for xx in 0..<sw {
                let i = yy * sw + xx
                let xr = min(sw - 1, xx + 1), yd = min(sh - 1, yy + 1)
                let grad = abs(y[i] - y[yy * sw + xr]) + abs(y[i] - y[yd * sw + xx])
                let blue = b[i] - (r[i] + g[i]) / 2
                let mx = max(r[i], g[i], b[i]), mn = min(r[i], g[i], b[i])
                let sat = mx > 0 ? (mx - mn) / mx : 0
                let clearSky = blue > 0.03 && y[i] > 0.25
                let overcast = y[i] > 0.62 && sat < 0.2
                let dusk = y[i] > 0.35 && r[i] > b[i] && sat < 0.55 && yy < sh / 2
                cand[i] = grad < 0.07 && (clearSky || overcast || dusk)
            }
        }
        // 从顶边的候选像素开始做 4 连通填充，相邻像素颜色差太大就停
        var sky = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        for xx in 0..<sw where cand[xx] { sky[xx] = true; stack.append(xx) }
        while let i = stack.popLast() {
            let xx = i % sw, yy = i / sw
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = xx + dx, ny = yy + dy
                guard nx >= 0, nx < sw, ny >= 0, ny < sh else { continue }
                let j = ny * sw + nx
                guard !sky[j], cand[j], abs(r[i] - r[j]) + abs(g[i] - g[j]) + abs(b[i] - b[j]) < 0.12 else { continue }
                sky[j] = true
                stack.append(j)
            }
        }
        // 柔化：两遍 3×3 盒式模糊
        var m = sky.map { $0 ? Float(1) : 0 }
        for _ in 0..<2 {
            var o = m
            for yy in 0..<sh {
                for xx in 0..<sw {
                    var sum: Float = 0, c: Float = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let nx = xx + dx, ny = yy + dy
                        if nx >= 0, nx < sw, ny >= 0, ny < sh { sum += m[ny * sw + nx]; c += 1 }
                    } }
                    o[yy * sw + xx] = sum / c
                }
            }
            m = o
        }
        return MaskBitmap(id: UUID().uuidString, width: sw, height: sh, data: m.map { UInt8(min(255, max(0, $0 * 255)).rounded()) })
    }
}
