import CoreImage
import Foundation
@testable import LinseCore
import XCTest

final class ParityTests: XCTestCase {
    // 8-bit GPU 实现间允许少量量化差异，同时限制平均值和最坏像素；不能只打印误差。
    private let meanTolerance = 0.5
    private let maximumTolerance = 4

    func testIdentity() throws {
        let renderer = try Renderer()
        let pixels = syntheticPixels(width: 64, height: 48)
        renderer.setImage(rgba: pixels, width: 64, height: 48)
        let output = try renderer.renderRGBA8(Params(), width: 64, height: 48)
        XCTAssertLessThanOrEqual(try difference(output, pixels).maximum, 1)
    }

    func testParityWithElectron() throws {
        let directory = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Electron")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let source = [UInt8](try Data(contentsOf: directory.appendingPathComponent("source.rgba")))
        XCTAssertEqual(source.count, manifest.width * manifest.height * 4)
        XCTAssertEqual(Set(manifest.cases.map(\.id)), Set(["identity", "channel-curves", "all-hsl"] + Preset.builtins.map(\.id)))
        let renderer = try Renderer()
        for useCoreImage in [false, true] {
            if useCoreImage {
                let image = try XCTUnwrap(Exporter.cgImage(rgba: source, width: manifest.width, height: manifest.height))
                try renderer.setImage(ci: CIImage(cgImage: image))
            } else {
                renderer.setImage(rgba: source, width: manifest.width, height: manifest.height)
            }
            for item in manifest.cases {
                if let preset = Preset.builtins.first(where: { $0.id == item.id }) {
                    XCTAssertEqual(item.params, preset.params, "内置预设变化时必须复核参考样本")
                }
                let reference = [UInt8](try Data(contentsOf: directory.appendingPathComponent(item.id + ".rgba")))
                let output = try renderer.renderRGBA8(item.params, width: manifest.width, height: manifest.height)
                let error = try difference(output, reference)
                let context = "\(item.id) / \(useCoreImage ? "CoreImage" : "RGBA8"): mean=\(error.mean), max=\(error.maximum)"
                XCTAssertLessThanOrEqual(error.mean, meanTolerance, context)
                XCTAssertLessThanOrEqual(error.maximum, maximumTolerance, context)
            }
        }
    }

    func testParityThresholdRejectsColorDrift() throws {
        let reference = syntheticPixels(width: 64, height: 48)
        var shifted = reference
        for i in stride(from: 0, to: shifted.count, by: 4) { shifted[i] = UInt8(min(255, Int(shifted[i]) + 20)) }
        let error = try difference(shifted, reference)
        XCTAssertGreaterThan(error.mean, meanTolerance)
        XCTAssertGreaterThan(error.maximum, maximumTolerance)
        XCTAssertThrowsError(try difference(Array(reference.dropLast()), reference))
    }

    func testTiledExportMatchesWhole() throws {
        let width = 2053, height = 37 // 两块，包括非整块宽度；不依赖外部照片。
        let renderer = try Renderer()
        renderer.setImage(rgba: syntheticPixels(width: width, height: height), width: width, height: height)
        var params = Preset.builtins[0].params
        params.effects.sharpen = 60
        params.effects.clarity = 30
        let whole = try renderer.renderRGBA8(params, width: width, height: height)
        let image = try Exporter.render(renderer, params, format: .png)
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        let tiled = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
        XCTAssertLessThanOrEqual(try difference(tiled, whole).maximum, 1)

        let wholeFloat = try renderer.renderFloat(params, width: width, height: height)
        let image16 = try Exporter.render(renderer, params, format: .tiff16)
        XCTAssertEqual(image16.bitsPerComponent, 16)
        let bytes = [UInt8](try XCTUnwrap(image16.dataProvider?.data) as Data)
        XCTAssertEqual(bytes.count, width * height * 8)
        var maximum = 0
        for i in wholeFloat.indices where i % 4 != 3 {
            let actual = Int(bytes[i * 2]) | (Int(bytes[i * 2 + 1]) << 8)
            let expected = Int((min(1, max(0, wholeFloat[i])) * 65535).rounded())
            maximum = max(maximum, abs(actual - expected))
        }
        // 不同视口的归一化坐标插值有浮点误差；允许不足 1/4 个 8-bit 灰阶的差异。
        XCTAssertLessThanOrEqual(Double(maximum) / 65535, 1.0 / 1024, "16-bit 分块结果不能出现接缝或颜色漂移")
    }

    private struct Manifest: Decodable {
        let width: Int, height: Int
        let cases: [Case]
        struct Case: Decodable { let id: String; let params: Params }
    }

    private func difference(_ output: [UInt8], _ reference: [UInt8]) throws -> (mean: Double, maximum: Int) {
        guard output.count == reference.count, !output.isEmpty, output.count % 4 == 0 else { throw ComparisonError.dimensions }
        var sum = 0, maximum = 0
        for i in output.indices where i % 4 != 3 {
            let delta = abs(Int(output[i]) - Int(reference[i]))
            sum += delta
            maximum = max(maximum, delta)
        }
        return (Double(sum) / Double(output.count / 4 * 3), maximum)
    }
    private enum ComparisonError: Error { case dimensions }

    private func syntheticPixels(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x % 256)
            pixels[i + 1] = UInt8((y * 7) % 256)
            pixels[i + 2] = UInt8((x * 13 + y * 11) % 256)
        } }
        return pixels
    }
}
