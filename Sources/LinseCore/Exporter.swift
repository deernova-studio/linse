// 全尺寸导出：按 2048 像素分块渲染再拼起来，所有分块用同一份参数；JPEG / PNG / 16 位 TIFF。
import CoreGraphics
import CoreImage
import Darwin
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
        try renderTiles(r, params, width: Int(r.imageSize.width), height: Int(r.imageSize.height), tileSize: 2048,
                        format: format, prepare: nil, progress: progress)
    }

    /// sourceTileSize 供回归测试强制输入分块；正常导出仅在输入超出单纹理上限时切换。
    static func render(_ source: CIImage, using r: Renderer, params: Params, format: ExportFormat,
                       sourceTileSize: Int? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> CGImage {
        let (width, height) = try Renderer.imageDimensions(source)
        if sourceTileSize == nil && max(width, height) <= r.maxTextureSize {
            try r.setImage(ci: source)
            return try render(r, params, format: format, progress: progress)
        }
        let input = try TiledImageSource(source, renderer: r, params: params)
        return try renderTiles(r, params, width: input.width, height: input.height,
            tileSize: min(sourceTileSize ?? 2048, r.maxTextureSize - 6), format: format, prepare: input.load, progress: progress)
    }

    private static func renderTiles(_ r: Renderer, _ params: Params, width W: Int, height H: Int, tileSize T: Int,
                                    format: ExportFormat, prepare: ((CGRect) throws -> Void)?, progress: ((Int, Int) -> Void)?) throws -> CGImage {
        guard T > 0 else { throw RenderError.invalidImageSize }
        let buffer = try MappedRaster(width: W, height: H, bytesPerPixel: format == .tiff16 ? 8 : 4)
        var tiles: [(Int, Int, Int, Int)] = []
        for y in stride(from: 0, to: H, by: T) { for x in stride(from: 0, to: W, by: T) { tiles.append((x, y, min(T, W - x), min(T, H - y))) } }
        if format == .tiff16 {
            let buf = buffer.pointer.assumingMemoryBound(to: UInt16.self)
            for (i, (x, y, w, h)) in tiles.enumerated() {
                try autoreleasepool {
                    try Task.checkCancellation()
                    progress?(i + 1, tiles.count)
                    try prepare?(CGRect(x: x, y: y, width: w, height: h))
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
            }
            return try buffer.image(bitsPerComponent: 16)
        }
        for (i, (x, y, w, h)) in tiles.enumerated() {
            try autoreleasepool {
                try Task.checkCancellation()
                progress?(i + 1, tiles.count)
                try prepare?(CGRect(x: x, y: y, width: w, height: h))
                let region = SIMD4<Float>(Float(x) / Float(W), Float(y) / Float(H), Float(w) / Float(W), Float(h) / Float(H))
                let px = try r.renderRGBA8(params, width: w, height: h, opts: RenderOptions(region: region))
                for row in 0..<h {
                    px.withUnsafeBufferPointer { src in
                        buffer.pixel(x, y + row).copyMemory(from: src.baseAddress! + row * w * 4, byteCount: w * 4)
                    }
                }
            }
        }
        return try buffer.image(bitsPerComponent: 8)
    }

    public static func write(_ img: CGImage, to url: URL, format: ExportFormat) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".linse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        // ImageIO 编码失败时可能留下它自己的临时文件，一并限定在本次任务目录内。
        let temporary = staging.appendingPathComponent("image.\(format.ext)")
        guard let dest = CGImageDestinationCreateWithURL(temporary as CFURL, format.uti, 1, nil) else { throw RenderError.texture("无法写入 \(url.lastPathComponent)") }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.texture("写入失败") }
        try Task.checkCancellation()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// RGBA8 像素（行自上而下）→ CGImage（缩略图、直方图预览等）
    public static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let prov = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
