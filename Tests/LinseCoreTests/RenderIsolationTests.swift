import Metal
@testable import LinseCore
import XCTest

final class RenderIsolationTests: XCTestCase {
    func testQueuedFramesKeepTheirCurveSnapshots() throws {
        var light = Params(), dark = Params()
        light.curves.rgb = [[0, 64], [255, 255]]
        dark.curves.rgb = [[0, 0], [255, 128]]
        try assertIsolatedDraws([light, dark, light, Params()])
    }

    func testQueuedFramesKeepTheirHSLSnapshots() throws {
        var saturated = Params(), muted = Params()
        for band in HSLBand.allCases {
            saturated.setHSL(band, HSLValue(hue: 20, sat: 40, lum: 10))
            muted.setHSL(band, HSLValue(hue: -20, sat: -70, lum: -20))
        }
        try assertIsolatedDraws([saturated, muted, saturated, Params()])
    }

    func testDrawsWithinOneCommandBufferKeepTheirOwnLookups() throws {
        var first = Params(), second = Params()
        first.curves.rgb = [[0, 50], [255, 255]]
        first.setHSL(.red, HSLValue(sat: 50))
        second.curves.rgb = [[0, 0], [255, 160]]
        second.setHSL(.red, HSLValue(sat: -70))
        try assertIsolatedDraws([first, second, first], singleCommandBuffer: true)
    }

    private func assertIsolatedDraws(_ settings: [Params], singleCommandBuffer: Bool = false,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let renderer = try Renderer()
        let width = 8, height = 6
        let colors: [[UInt8]] = [[128, 128, 128, 255], [200, 70, 50, 255], [50, 130, 200, 255]]
        let pixels = (0..<(width * height)).flatMap { colors[$0 % colors.count] }
        renderer.setImage(rgba: pixels, width: width, height: height)
        let expected = try settings.map { try renderer.renderRGBA8($0, width: width, height: height) }
        XCTAssertNotEqual(expected[0], expected[1], "测试参数必须产生不同的图像", file: file, line: line)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let targets = try settings.map { _ in try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor)) }
        let gate = try XCTUnwrap(renderer.device.makeSharedEvent())
        defer { gate.signaledValue = 1 }
        var commands: [MTLCommandBuffer] = []
        if singleCommandBuffer {
            let command = try XCTUnwrap(renderer.makeCommandBuffer())
            command.encodeWaitForEvent(gate, value: 1)
            for (params, target) in zip(settings, targets) {
                try renderer.encode(params, into: target, commandBuffer: command)
            }
            command.commit()
            commands.append(command)
        } else {
            for (params, target) in zip(settings, targets) {
                let command = try XCTUnwrap(renderer.makeCommandBuffer())
                command.encodeWaitForEvent(gate, value: 1)
                try renderer.encode(params, into: target, commandBuffer: command)
                command.commit()
                commands.append(command)
            }
        }
        // 所有 CPU 侧更新完成后才放行 GPU，确定性复现多帧在途；不依赖时间或负载。
        gate.signaledValue = 1
        for command in commands {
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU 未完成", file: file, line: line)
        }
        for (index, target) in targets.enumerated() {
            var actual = [UInt8](repeating: 0, count: width * height * 4)
            actual.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            let difference = zip(actual, expected[index]).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(difference, 1, "第 \(index) 次绘制使用了其他绘制的查找表", file: file, line: line)
        }
    }
}
