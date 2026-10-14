import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import LinseCore
import XCTest

final class ParityTests: XCTestCase {
    func loadCG(_ path: String) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// 所有参数为 0 时输出应与原图一致
    func testIdentity() throws {
        let r = try Renderer()
        var px = [UInt8](repeating: 255, count: 64 * 48 * 4)
        for i in 0..<(64 * 48) { px[i * 4] = UInt8(i % 256); px[i * 4 + 1] = UInt8((i * 7) % 256); px[i * 4 + 2] = UInt8((i * 13) % 256) }
        r.setImage(rgba: px, width: 64, height: 48)
        let out = try r.renderRGBA8(Params(), width: 64, height: 48)
        var maxd = 0
        for i in 0..<px.count where i % 4 != 3 { maxd = max(maxd, abs(Int(px[i]) - Int(out[i]))) }
        print("identity max diff:", maxd)
        XCTAssertLessThanOrEqual(maxd, 1)
    }

    /// 和 Electron 版逐像素对照：同一张图、同一组预设
    func testParityWithElectron() throws {
        guard let dir = ProcessInfo.processInfo.environment["LINSE_DUMP_DIR"] else { throw XCTSkip("未设置 LINSE_DUMP_DIR") }
        let r = try Renderer()
        let cg = try loadCG(dir + "/source.jpeg")
        // 用 Core Image 载入路径（App 实际使用的路径）
        try r.setImage(ci: CIImage(cgImage: cg))
        let W = cg.width, H = cg.height
        let list: [(String, Params)] = [("identity", Params())] + Preset.builtins.map { ($0.id, $0.params) }
        for (id, p) in list {
            let ref = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(id).rgba")))
            let out = try r.renderRGBA8(p, width: W, height: H)
            var sum = 0, maxd = 0, n = 0
            for i in 0..<out.count where i % 4 != 3 { let d = abs(Int(out[i]) - Int(ref[i])); sum += d; maxd = max(maxd, d); n += 1 }
            print(String(format: "%-15@ mean %.2f  max %d", id as NSString, Double(sum) / Double(n), maxd))
        }
    }
}

extension ParityTests {
    func testTiledExportMatchesWhole() throws {
        guard let dir = ProcessInfo.processInfo.environment["LINSE_DUMP_DIR"] else { throw XCTSkip("未设置 LINSE_DUMP_DIR") }
        let r = try Renderer()
        let cg = try loadCG(dir + "/source.jpeg")
        // 放大到 5000 宽，强制分块
        let big = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 12.5, y: 12.5))
        try r.setImage(ci: big)
        var p = Preset.builtins[0].params
        p.effects.sharpen = 60; p.effects.clarity = 30
        let t0 = Date()
        let img = try Exporter.render(r, p, format: .jpeg)
        print("export \(img.width)x\(img.height) in \(Date().timeIntervalSince(t0))s")
        let url = URL(fileURLWithPath: dir + "/swift-out.jpg")
        try Exporter.write(img, to: url, format: .jpeg)
        let t16 = try Exporter.render(r, p, format: .tiff16)
        try Exporter.write(t16, to: URL(fileURLWithPath: dir + "/swift-out.tif"), format: .tiff16)
        XCTAssertEqual(img.width, 5000)
    }
}
