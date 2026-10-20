import CoreImage
import LinseCore

struct Slot: Identifiable {
    let id = UUID()
    let name: String
    let ci: CIImage
    let size: CGSize
    let thumb: CGImage?
    let metadata: ImageMetadata
}
