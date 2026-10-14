// 白平衡：Bradford 色适应。色温/色调换算成源白点（沿黑体轨迹 + 绿-洋红偏移），适应到 D65。
// 返回线性 sRGB 下的 3×3 矩阵（行优先）。和 Electron 版 wb.ts 相同。
import Foundation

public enum WhiteBalance {
    typealias M3 = [Double]
    static let rgb2xyz: M3 = [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.072175, 0.0193339, 0.119192, 0.9503041]
    static let xyz2rgb: M3 = [3.2404542, -1.5371385, -0.4985314, -0.969266, 1.8760108, 0.041556, 0.0556434, -0.2040259, 1.0572252]
    static let bradford: M3 = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
    static let bradfordInv: M3 = [0.9869929, -0.1470543, 0.1599627, 0.4323053, 0.5183603, 0.0492912, -0.0085287, 0.0400428, 0.9684867]
    static let d65 = (x: 0.31271, y: 0.32902)

    static func mul(_ a: M3, _ b: M3) -> M3 {
        var o = M3(repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<3 {
            let x: Double = a[r * 3 + k] * b[k * 3 + c]
            o[r * 3 + c] += x
        } } }
        return o
    }
    static func apply(_ m: M3, _ v: [Double]) -> [Double] {
        var o = [0.0, 0.0, 0.0]
        for r in 0..<3 {
            let a: Double = m[r * 3] * v[0]
            let b: Double = m[r * 3 + 1] * v[1]
            let c: Double = m[r * 3 + 2] * v[2]
            o[r] = a + b + c
        }
        return o
    }

    static func planck(_ T0: Double) -> (x: Double, y: Double) {
        let T = min(25000, max(1667, T0)), t = 1e3 / T
        func cubic(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ v: Double) -> Double { ((a * v + b) * v + c) * v + d }
        let x = T <= 4000 ? cubic(-0.2661239, -0.2343589, 0.8776956, 0.17991, t) : cubic(-3.0258469, 2.1070379, 0.2226347, 0.24039, t)
        let y: Double
        if T <= 2222 { y = cubic(-1.1063814, -1.3481102, 2.18555832, -0.20219683, x) }
        else if T <= 4000 { y = cubic(-0.9549476, -1.37418593, 2.09137015, -0.16748867, x) }
        else { y = cubic(3.081758, -5.8733867, 3.75112997, -0.37001483, x) }
        return (x, y)
    }
    static func xyz(_ p: (x: Double, y: Double)) -> [Double] { [p.x / p.y, 1, (1 - p.x - p.y) / p.y] }

    public static func matrix(temperature: Double, tint: Double) -> [Float] {
        if temperature == 0 && tint == 0 { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let ref = planck(6504), p = planck(6504 * pow(2, temperature / 100 * 0.85))
        let src = (x: d65.x + (p.x - ref.x), y: d65.y + (p.y - ref.y) + tint / 100 * 0.02)
        let ls = apply(bradford, xyz(src)), ld = apply(bradford, xyz(d65))
        let diag: M3 = [ld[0] / ls[0], 0, 0, 0, ld[1] / ls[1], 0, 0, 0, ld[2] / ls[2]]
        let m = mul(xyz2rgb, mul(bradfordInv, mul(diag, mul(bradford, rgb2xyz))))
        let g = apply(m, [1, 1, 1]), yl = 0.2126 * g[0] + 0.7152 * g[1] + 0.0722 * g[2]
        return m.map { Float($0 / yl) }
    }
}

/// 颜色分级色轮 → 去掉亮度后的 RGB 偏移量
public func gradeOffset(_ w: GradeWheel, strength: Double = 0.3) -> SIMD3<Float> {
    let h = (w.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
    let rgb: [Double] = h < 1 ? [1, x, 0] : h < 2 ? [x, 1, 0] : h < 3 ? [0, 1, x] : h < 4 ? [0, x, 1] : h < 5 ? [x, 0, 1] : [1, 0, x]
    let y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2], k = w.sat / 100 * strength
    return SIMD3(Float((rgb[0] - y) * k), Float((rgb[1] - y) * k), Float((rgb[2] - y) * k))
}
