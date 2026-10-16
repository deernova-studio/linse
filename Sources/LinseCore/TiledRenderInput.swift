import CoreGraphics
import Metal
import simd

struct TiledRenderInput {
    let size: CGSize
    let region: SIMD4<Float>
    let sharpRegion: SIMD4<Float>
    let sharp: MTLTexture?
    let blur: MTLTexture?
    let blurBaseLevel: Int
}
