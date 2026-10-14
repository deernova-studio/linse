// 曲线：单调三次插值（Fritsch–Carlson），烘焙成 256 格查找表。和 Electron 版 curve.ts 相同的算法。
import Foundation

public enum Curve {
    public static func evaluate(_ points: [CurvePoint], n: Int = 256) -> [Float] {
        let pts = points.sorted { $0[0] < $1[0] }
        var out = [Float](repeating: 0, count: n)
        guard !pts.isEmpty else { return (0..<n).map { Float($0) / Float(n - 1) } }
        let xs = pts.map { $0[0] / 255 }, ys = pts.map { $0[1] / 255 }
        let k = xs.count
        if k == 1 { return [Float](repeating: Float(ys[0]), count: n) }
        var d = [Double](), m = [Double](repeating: 0, count: k)
        for i in 0..<(k - 1) { d.append((ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-6)) }
        m[0] = d[0]; m[k - 1] = d[k - 2]
        if k > 2 { for i in 1..<(k - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(k - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var seg = 0
        for j in 0..<n {
            let x = Double(j) / Double(n - 1)
            if x <= xs[0] { out[j] = Float(ys[0]); continue }
            if x >= xs[k - 1] { out[j] = Float(ys[k - 1]); continue }
            while seg < k - 2 && x > xs[seg + 1] { seg += 1 }
            let h = xs[seg + 1] - xs[seg], t = (x - xs[seg]) / h, t2 = t * t, t3 = t2 * t
            let v = (2 * t3 - 3 * t2 + 1) * ys[seg] + (t3 - 2 * t2 + t) * h * m[seg] + (-2 * t3 + 3 * t2) * ys[seg + 1] + (t3 - t2) * h * m[seg + 1]
            out[j] = Float(min(1, max(0, v)))
        }
        return out
    }

    static func sample(_ lut: [Float], _ x: Float) -> Float {
        let f = min(1, max(0, x)) * Float(lut.count - 1)
        let i = Int(f), j = min(lut.count - 1, i + 1)
        return lut[i] + (lut[j] - lut[i]) * (f - Float(i))
    }

    /// 合成为 256×1 RGBA：out_c = curve_c(curve_rgb(in))
    public static func lut(_ p: Params) -> [Float] {
        let master = evaluate(p.curves.rgb), r = evaluate(p.curves.r), g = evaluate(p.curves.g), b = evaluate(p.curves.b)
        var out = [Float](repeating: 1, count: 256 * 4)
        for i in 0..<256 {
            let m = master[i]
            out[i * 4] = sample(r, m); out[i * 4 + 1] = sample(g, m); out[i * 4 + 2] = sample(b, m)
        }
        return out
    }

    public static func isIdentity(_ pts: [CurvePoint]) -> Bool { pts.allSatisfy { abs($0[0] - $0[1]) < 1 } }
}

// 混色器 8 个分区 → 360 格查找表，相邻分区之间平滑过渡
public enum HSLTable {
    public static func build(_ p: Params) -> [Float] {
        var out = [Float](repeating: 1, count: 360 * 4)
        let c = HSLBand.centers + [360]
        for h in 0..<360 {
            var i = 0
            while i < 7 && Double(h) >= c[i + 1] { i += 1 }
            let t0 = (Double(h) - c[i]) / (c[i + 1] - c[i]), t = t0 * t0 * (3 - 2 * t0)
            let a = p.hslValue(HSLBand(rawValue: i)!), b = p.hslValue(HSLBand(rawValue: (i + 1) % 8)!)
            out[h * 4] = Float((a.hue + (b.hue - a.hue) * t) / 100)
            out[h * 4 + 1] = Float((a.sat + (b.sat - a.sat) * t) / 100)
            out[h * 4 + 2] = Float((a.lum + (b.lum - a.lum) * t) / 100)
        }
        return out
    }
    public static func isIdentity(_ p: Params) -> Bool { HSLBand.allCases.allSatisfy { p.hslValue($0).isZero } }
}
