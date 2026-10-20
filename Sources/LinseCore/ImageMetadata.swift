import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 仅保留图片详情需要的可读信息，不保存路径、定位或整份 EXIF。
public struct ImageMetadata: Equatable, Sendable {
    public var isRAW = false
    public var format: String?
    public var byteCount: Int64?
    public var colorProfile: String?
    public var bitDepth: Int?
    public var camera: String?
    public var lens: String?
    public var capturedAt: String?

    public init() {}

    public static func read(from url: URL) -> Self {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        return read(source, byteCount: size.map(Int64.init))
    }

    public static func read(from data: Data, typeIdentifierHint: String? = nil) -> Self {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeIdentifierHint { options[kCGImageSourceTypeIdentifierHint] = typeIdentifierHint }
        let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
        return read(source, byteCount: Int64(data.count))
    }

    private static func read(_ source: CGImageSource?, byteCount: Int64?) -> Self {
        var result = Self()
        result.byteCount = byteCount
        guard let source else { return result }
        if let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) {
            result.isRAW = type.conforms(to: .rawImage)
            if let ext = type.preferredFilenameExtension {
                result.format = ext.lowercased() == "jpg" ? "JPEG" : ext.uppercased()
            }
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return result }
        result.colorProfile = nonempty(properties[kCGImagePropertyProfileName as String])
        result.bitDepth = (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let make = nonempty(tiff[kCGImagePropertyTIFFMake as String])
        let model = nonempty(tiff[kCGImagePropertyTIFFModel as String])
        if let make, let model {
            result.camera = model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        } else { result.camera = model ?? make }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        result.lens = nonempty(exif[kCGImagePropertyExifLensModel as String])
        if let captured = nonempty(exif[kCGImagePropertyExifDateTimeOriginal as String]) {
            // EXIF 的日期部分使用冒号；保留原始时间，不推断缺失的时区。
            let parts = captured.split(separator: " ", maxSplits: 1)
            result.capturedAt = parts.map(String.init).enumerated().map { index, part in
                index == 0 ? part.replacingOccurrences(of: ":", with: "-") : part
            }.joined(separator: " ")
        }
        return result
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
