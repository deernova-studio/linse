// 3D LUT（.cube）：解析导入的文件；把当前全局调整烘焙成 .cube 导出。
import Foundation

public struct CubeLut: Sendable {
    public let id: String, name: String, size: Int
    public let data: [Float] // RGBA，r 变化最快

    public enum ParseError: Error, LocalizedError {
        case message(String)
        public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    public init(id: String, name fallback: String, text: String) throws {
        var size = 0, name = fallback
        var lo: [Double] = [0, 0, 0], hi: [Double] = [1, 1, 1]
        var vals: [Double] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let up = line.uppercased()
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if up.hasPrefix("TITLE") {
                if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b { name = String(line[line.index(after: a)..<b]) }
                continue
            }
            if up.hasPrefix("LUT_1D_SIZE") { throw ParseError.message("只支持 3D LUT") }
            if up.hasPrefix("LUT_3D_SIZE") { size = Int(parts.last ?? "") ?? 0; continue }
            if up.hasPrefix("DOMAIN_MIN") || up.hasPrefix("DOMAIN_MAX") {
                let v = parts.dropFirst().compactMap(Double.init)
                guard v.count == 3, v.allSatisfy(\.isFinite) else { throw ParseError.message("\(parts[0]) 无效") }
                if up.hasPrefix("DOMAIN_MIN") { lo = v } else { hi = v }
                continue
            }
            if parts.count >= 3, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) {
                guard r.isFinite, g.isFinite, b.isFinite else { throw ParseError.message("数值无效") }
                vals += [r, g, b]
            }
        }
        guard (2...128).contains(size) else { throw ParseError.message("缺少 LUT_3D_SIZE") }
        guard vals.count == size * size * size * 3 else { throw ParseError.message("数据数量不对：应为 \(size * size * size) 组，实际 \(vals.count / 3) 组") }
        var data = [Float](repeating: 1, count: size * size * size * 4)
        for i in 0..<(size * size * size) {
            for k in 0..<3 { data[i * 4 + k] = Float((vals[i * 3 + k] - lo[k]) / ((hi[k] - lo[k]) == 0 ? 1 : (hi[k] - lo[k]))) }
        }
        self.id = id; self.name = name; self.size = size; self.data = data
    }

    /// 只含逐像素调整的参数：蒙版、清晰度、去雾、暗角、颗粒、锐化依赖位置或邻域，LUT 装不下
    public static func lutParams(_ p: Params) -> Params {
        var q = p
        q.masks = []
        q.effects = Effects()
        return q
    }

    /// 烘焙成 .cube 文本（每个格点都走一遍同一条渲染管线）
    public static func bake(_ r: Renderer, _ p: Params, title: String, size: Int = 33) throws -> String {
        let W = size * size, H = size
        var px = [UInt8](repeating: 255, count: W * H * 4)
        for g in 0..<size { for b in 0..<size { for rr in 0..<size {
            let i = (g * W + rr + b * size) * 4
            px[i] = UInt8((Double(rr) / Double(size - 1) * 255).rounded())
            px[i + 1] = UInt8((Double(g) / Double(size - 1) * 255).rounded())
            px[i + 2] = UInt8((Double(b) / Double(size - 1) * 255).rounded())
        } } }
        let saved = r.image
        defer { if let saved { r.setImage(texture: saved) } }
        r.setImage(rgba: px, width: W, height: H)
        let out = try r.renderRGBA8(lutParams(p), width: W, height: H)
        var lines = ["TITLE \"\(title.replacingOccurrences(of: "\"", with: ""))\"", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        lines.reserveCapacity(size * size * size + 4)
        for b in 0..<size { for g in 0..<size { for rr in 0..<size {
            let i = (g * W + rr + b * size) * 4
            lines.append(String(format: "%.6f %.6f %.6f", Double(out[i]) / 255, Double(out[i + 1]) / 255, Double(out[i + 2]) / 255))
        } } }
        return lines.joined(separator: "\n") + "\n"
    }
}
