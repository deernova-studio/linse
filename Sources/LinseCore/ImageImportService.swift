import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 两个平台共用的导入入口。RAW 必须通过原始数据解码，不能静默退回内嵌 JPEG。
public actor ImageImportService {
    private let context = CIContext(options: [.cacheIntermediates: false])
    public init() {}

    public func load(_ url: URL) throws -> ImportedImage {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ImageImportError.unreadableFile }
        // CIImage 会延迟渲染；持有文件数据，避免授权结束或原文件移动后导出失败。
        return try load(data: data, name: url.lastPathComponent)
    }

    public func load(data: Data, name: String, typeIdentifierHint: String? = nil) throws -> ImportedImage {
        try Task.checkCancellation()
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        let identifier = source.flatMap { CGImageSourceGetType($0) as String? }
        let type = identifier.flatMap { UTType($0) }
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        let namedType = typeIdentifierHint.flatMap { UTType($0) } ?? UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension.lowercased())
        // NEF / ARW 等 TIFF 容器经 ImageIO 自动识别时可能只暴露预览页。
        // 对歧义容器尝试系统注册的 RAW 解码器，并要求真实 RAW decoder version。
        // CIRAWFilter 也接受 JPEG / TIFF，此时仅有 None 版本，不能据此宣布支持 RAW。
        let ambiguous = type == nil || type == .tiff
        let detectedRAW = type?.conforms(to: .rawImage) == true || properties?[kCGImagePropertyDNGDictionary as String] != nil
        let hintedRAW = ambiguous && (namedType?.conforms(to: .rawImage) == true || Self.hasRAWHint(name))
        var rawFilter: CIRAWFilter?
        var rawIdentifier: String?
        if detectedRAW || ambiguous {
            let hints = [detectedRAW ? identifier : nil, namedType?.conforms(to: .rawImage) == true ? namedType?.identifier : nil]
                .compactMap { $0 } + Self.rawTypeIdentifiers
            var attempted = Set<String>()
            for hint in hints where attempted.insert(hint).inserted {
                try Task.checkCancellation()
                if let filter = CIRAWFilter(imageData: data, identifierHint: hint),
                   filter.supportedDecoderVersions.contains(where: { $0 != .none }) {
                    rawFilter = filter
                    rawIdentifier = hint
                    break
                }
            }
        }
        let raw = rawFilter != nil || detectedRAW || hintedRAW
        let failure: ImageImportError = raw ? .rawDecodingFailed : .invalidImage

        let decoded: CIImage?
        if raw {
            guard let filter = rawFilter else { throw failure }
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
            // 使用系统对该相机的默认显影；不额外旋转，CIRAWFilter 已应用 EXIF 方向。
            decoded = filter.outputImage
        } else {
            guard let source, CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete else { throw failure }
            decoded = CIImage(data: data, options: [.applyOrientationProperty: true])
        }
        guard let decoded else { throw failure }
        let extent = decoded.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width.isFinite, extent.height.isFinite,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max) else { throw failure }
        let image = decoded.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1, 400 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: max(1, floor(extent.width * scale)), height: max(1, floor(extent.height * scale)))
        // 真正执行解码后再交给 UI，不能仅以创建了一个惰性 CIImage 判断导入成功。
        guard let thumbnail = context.createCGImage(small, from: bounds, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false) else {
            throw failure
        }
        try Task.checkCancellation()
        var metadata = ImageMetadata.read(from: data, typeIdentifierHint: rawIdentifier)
        metadata.isRAW = raw
        if let rawIdentifier, let ext = UTType(rawIdentifier)?.preferredFilenameExtension {
            metadata.format = ext.uppercased()
        }
        return ImportedImage(image: image, thumbnail: thumbnail, metadata: metadata)
    }

    private static let rawTypeIdentifiers = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        .filter { UTType($0)?.conforms(to: .rawImage) == true }

    /// 只用于无法解析内容时给出 RAW 专用提示，不是相机支持白名单。
    private static func hasRAWHint(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if UTType(filenameExtension: ext)?.conforms(to: .rawImage) == true { return true }
        return ["raw", "dng", "arw", "srf", "sr2", "crw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "rwl", "pef", "ptx", "srw", "iiq", "3fr", "fff", "mos", "mrw", "x3f"].contains(ext)
    }
}
