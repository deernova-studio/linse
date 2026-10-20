import CoreImage

/// 原始精度的解码图用于编辑和导出；缩略图只用于界面。
public struct ImportedImage {
    public let image: CIImage
    public let thumbnail: CGImage
    public let metadata: ImageMetadata
}
