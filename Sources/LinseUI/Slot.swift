import CoreImage
import LinseCore

struct Slot: Identifiable {
    var id = UUID()
    let name: String
    let ci: CIImage
    let size: CGSize
    let thumb: CGImage?
    let metadata: ImageMetadata
    var originalData: Data? = nil
    var typeIdentifierHint: String? = nil
}
