import CoreImage
@testable import LinseCore
import XCTest

final class SourceTilingTests: XCTestCase {
    func testSourceTilesMatchWholeImageWithSpatialEffectsAndMasks() throws {
        for (width, height) in [(256, 192), (259, 197), (257, 5), (4101, 19), (19, 4101)] {
            let image = try source(width: width, height: height)
            let whole = try Renderer(), tiled = try Renderer()
            let masks = SmartMaskStore()
            masks.set(.sky, MaskBitmap(id: "sky", width: 4, height: 2, data: [255, 120, 80, 30, 0, 0, 0, 0]))
            whole.maskBitmaps = masks; tiled.maskBitmaps = masks
            var effects = Preset.builtins[0].params
            effects.effects.clarity = 70; effects.effects.dehaze = 60; effects.effects.sharpen = 80
            effects.effects.grain = 25; effects.effects.vignette = -40
            var radial = Mask(type: .radial, index: 1), linear = Mask(type: .linear, index: 2), sky = Mask(type: .sky, index: 3)
            radial.adjust.exposure = 0.6; linear.adjust.saturation = -30; sky.adjust.temperature = 25
            effects.masks = [radial, linear, sky]
            var clarity = Params(), dehaze = Params(), sharpen = Params()
            clarity.effects.clarity = 70; dehaze.effects.dehaze = 60; sharpen.effects.sharpen = 80
            for params in [Params(), clarity, dehaze, sharpen, effects] {
                try whole.setImage(ci: image)
                for format in [ExportFormat.png, .tiff16] {
                    let expected = try Exporter.render(whole, params, format: format)
                    let actual = try Exporter.render(image, using: tiled, params: params, format: format,
                        sourceTileSize: max(width, height) > 2048 ? 2048 : 64)
                    let reference = [UInt8](try XCTUnwrap(expected.dataProvider?.data) as Data)
                    let bytes = [UInt8](try XCTUnwrap(actual.dataProvider?.data) as Data)
                    XCTAssertEqual(bytes.count, reference.count)
                    var maximum = 0, maximumIndex = 0, sum = 0, count = 0
                    for i in 0..<(width * height * 4) where i % 4 != 3 {
                        let a: Int, b: Int
                        if format == .tiff16 {
                            a = Int(bytes[i * 2]) | Int(bytes[i * 2 + 1]) << 8
                            b = Int(reference[i * 2]) | Int(reference[i * 2 + 1]) << 8
                        } else { a = Int(bytes[i]); b = Int(reference[i]) }
                        let difference = abs(a - b)
                        if difference > maximum { maximum = difference; maximumIndex = i }
                        sum += difference; count += 1
                    }
                    let label = "\(width)×\(height) \(format) clarity=\(params.effects.clarity) dehaze=\(params.effects.dehaze) sharpen=\(params.effects.sharpen) mean=\(Double(sum) / Double(count)) max at (\(maximumIndex / 4 % width),\(maximumIndex / 4 / width))"
                    if format == .tiff16 {
                        XCTAssertLessThanOrEqual(Double(maximum) / 65535, 1.0 / 1024, label)
                    } else {
                        XCTAssertLessThanOrEqual(maximum, 1, label)
                        XCTAssertLessThanOrEqual(Double(sum) / Double(count), 0.5, label)
                    }
                }
            }
        }
    }

    private func source(width: Int, height: Int) throws -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x % 256)
            pixels[i + 1] = UInt8((y * 7) % 256)
            pixels[i + 2] = UInt8((x * 13 + y * 11) % 256)
        } }
        return CIImage(cgImage: try XCTUnwrap(Exporter.cgImage(rgba: pixels, width: width, height: height)))
    }
}
