// 全尺寸导出：按 2048 像素分块渲染再拼起来，所有分块用同一份参数；JPEG / PNG / 16 位 TIFF。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case jpeg, png, tiff16
    public var ext: String { ["jpeg": "jpg", "png": "png", "tiff16": "tif"][rawValue]! }
    public var label: String { ["jpeg": "JPEG", "png": "PNG", "tiff16": "16 位 TIFF"][rawValue]! }
    var uti: CFString { [ExportFormat.jpeg: UTType.jpeg, .png: UTType.png, .tiff16: UTType.tiff][self]!.identifier as CFString }
}

public enum Exporter {
    public static func render(_ r: Renderer, _ params: Params, format: ExportFormat, progress: ((Int, Int) -> Void)? = nil) throws -> CGImage {
        let W = Int(r.imageSize.width), H = Int(r.imageSize.height), T = 2048
        var tiles: [(Int, Int, Int, Int)] = []
        for y in stride(from: 0, to: H, by: T) { for x in stride(from: 0, to: W, by: T) { tiles.append((x, y, min(T, W - x), min(T, H - y))) } }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if format == .tiff16 {
            var buf = [UInt16](repeating: 0, count: W * H * 4)
            for (i, (x, y, w, h)) in tiles.enumerated() {
                progress?(i + 1, tiles.count)
                let region = SIMD4<Float>(Float(x) / Float(W), Float(y) / Float(H), Float(w) / Float(W), Float(h) / Float(H))
                let fp = try r.renderFloat(params, width: w, height: h, opts: RenderOptions(region: region))
                for row in 0..<h {
                    for col in 0..<w {
                        let s = (row * w + col) * 4, d = ((y + row) * W + x + col) * 4
                        for k in 0..<3 { buf[d + k] = UInt16((min(1, max(0, fp[s + k])) * 65535).rounded()) }
                        buf[d + 3] = 65535
                    }
                }
            }
            let data = buf.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
            guard let prov = CGDataProvider(data: data),
                  let img = CGImage(width: W, height: H, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: W * 8, space: srgb,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                    provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RenderError.texture("16 位图像") }
            return img
        }
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        for (i, (x, y, w, h)) in tiles.enumerated() {
            progress?(i + 1, tiles.count)
            let region = SIMD4<Float>(Float(x) / Float(W), Float(y) / Float(H), Float(w) / Float(W), Float(h) / Float(H))
            let px = try r.renderRGBA8(params, width: w, height: h, opts: RenderOptions(region: region))
            for row in 0..<h {
                buf.withUnsafeMutableBufferPointer { dst in
                    px.withUnsafeBufferPointer { src in
                        (dst.baseAddress! + ((y + row) * W + x) * 4).update(from: src.baseAddress! + row * w * 4, count: w * 4)
                    }
                }
            }
        }
        let data = Data(buf) as CFData
        guard let prov = CGDataProvider(data: data),
              let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: srgb,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { throw RenderError.texture("图像") }
        return img
    }

    public static func write(_ img: CGImage, to url: URL, format: ExportFormat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uti, 1, nil) else { throw RenderError.texture("无法写入 \(url.lastPathComponent)") }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.texture("写入失败") }
    }

    /// RGBA8 像素（行自上而下）→ CGImage（缩略图、直方图预览等）
    public static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let prov = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
