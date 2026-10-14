// 颜色统计：只选对"画面内容不同"不敏感的量（分位数、中性色加权的色度、按色相分区且两图都存在时才比较）。
// 和 Electron 版 stats.ts 一致。
import Foundation

public let percentiles: [Double] = [1, 5, 10, 25, 50, 75, 90, 95, 99]

public struct BandStats: Sendable { public var weight = 0.0, sat = 0.0, hue = 0.0, light = 0.0 }

public struct ImageStats: Sendable {
    public var lumPct: [Double] = []
    public var lumMean = 0.0
    public var neutralA = 0.0, neutralB = 0.0
    public var shadowA = 0.0, shadowB = 0.0, midA = 0.0, midB = 0.0, highA = 0.0, highB = 0.0
    public var chromaMean = 0.0, chromaLow = 0.0, chromaHigh = 0.0
    public var bands: [BandStats] = []
    public var skinFrac = 0.0, skinL = 0.0, skinA = 0.0, skinB = 0.0, skinC = 0.0
}

enum Lab {
    static let lin: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    static func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
    static func from(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> (L: Double, a: Double, b: Double) {
        let r = lin[Int(r8)], g = lin[Int(g8)], b = lin[Int(b8)]
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

func rgbToHS(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    if d < 1e-6 { return (0, 0) }
    let l = (mx + mn) / 2, s = d / (1 - abs(2 * l - 1) + 1e-6)
    var h: Double
    if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6); if h < 0 { h += 6 } }
    else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    return (h * 60, min(1, s))
}

func bandWeights(_ h: Double) -> (Int, Double, Int, Double) {
    let c = HSLBand.centers + [360]
    for i in 0..<8 where h >= c[i] && h < c[i + 1] {
        let t = (h - c[i]) / (c[i + 1] - c[i])
        return (i, 1 - t, (i + 1) % 8, t)
    }
    return (0, 1, 1, 0)
}

func hueDelta(_ h: Double, _ center: Double) -> Double {
    var d = h - center
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}

func skinWeight(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ L: Double) -> UInt8 {
    let R = Double(r), G = Double(g), B = Double(b)
    let cb = 128 - 0.168736 * R - 0.331264 * G + 0.5 * B
    let cr = 128 + 0.5 * R - 0.418688 * G - 0.081312 * B
    if L < 20 || L > 92 || cb < 77 || cb > 127 || cr < 135 || cr > 173 { return 0 }
    return r > g && r > b ? 1 : 0
}

public enum Stats {
    /// 细节权重：有纹理的区域权重高，大面积平坦区域（纯色背景、墙面、天空）权重低
    public static func detailWeights(_ px: [UInt8], width w: Int) -> [Float] {
        let n = px.count / 4, h = n / w
        var g = [Float](repeating: 0, count: n)
        for i in 0..<n { g[i] = (0.2126 * Float(px[i * 4]) + 0.7152 * Float(px[i * 4 + 1]) + 0.0722 * Float(px[i * 4 + 2])) / 255 }
        var grad = [Float](repeating: 0, count: n)
        if h > 2 && w > 2 {
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                grad[i] = abs(g[i + 1] - g[i - 1]) + abs(g[i + w] - g[i - w])
            } }
        }
        let r = max(2, Int((Double(max(w, h)) * 0.04).rounded()))
        // 可分离盒式模糊（前缀和）把边缘扩散成"区域"
        func blur(_ src: [Float], horiz: Bool) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            let len = horiz ? w : h, lines = horiz ? h : w
            var pre = [Float](repeating: 0, count: len + 1)
            for l in 0..<lines {
                for k in 0..<len { pre[k + 1] = pre[k] + src[horiz ? l * w + k : k * w + l] }
                for k in 0..<len {
                    let a = max(0, k - r), b = min(len - 1, k + r)
                    out[horiz ? l * w + k : k * w + l] = (pre[b + 1] - pre[a]) / Float(b - a + 1)
                }
            }
            return out
        }
        let b = blur(blur(grad, horiz: true), horiz: false)
        let ref = max(b.sorted()[Int(Double(n) * 0.75)], 1e-3)
        return b.map { 0.08 + 0.92 * min(1, $0 / ref) }
    }

    /// 原图的肤色掩码：估计器固定用它，避免调冷暖后皮肤像素掉出肤色范围
    public static func skinMask(_ px: [UInt8]) -> [UInt8] {
        (0..<(px.count / 4)).map { i in skinWeight(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], Lab.from(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]).L) }
    }

    public static func compute(_ px: [UInt8], weights: [Float]? = nil, skin fixedSkin: [UInt8]? = nil) -> ImageStats {
        let n = px.count / 4
        var hist = [Double](repeating: 0, count: 1001)
        var lumSum = 0.0, cnt = 0.0
        var nW = 0.0, nA = 0.0, nB = 0.0
        var sW = 0.0, sA = 0.0, sB = 0.0, mW = 0.0, mA = 0.0, mB = 0.0, hW = 0.0, hA = 0.0, hB = 0.0
        var chromas: [Double] = []
        chromas.reserveCapacity(n)
        var bW = [Double](repeating: 0, count: 8), bS = bW, bH = bW, bL = bW
        var kW = 0.0, kL = 0.0, kA = 0.0, kB = 0.0, kC = 0.0
        for i in 0..<n {
            let r8 = px[i * 4], g8 = px[i * 4 + 1], b8 = px[i * 4 + 2]
            let (L, a, b) = Lab.from(r8, g8, b8)
            let C = (a * a + b * b).squareRoot()
            let dw = Double(weights?[i] ?? 1)
            cnt += dw; lumSum += L * dw
            hist[max(0, min(1000, Int((L * 10).rounded())))] += dw
            let sk = fixedSkin?[i] ?? skinWeight(r8, g8, b8, L)
            if L > 20 && L < 90 && dw > 0.3 && sk == 0 { chromas.append(C) }
            if sk > 0 { kW += 1; kL += L; kA += a; kB += b; kC += C }
            let t = L / 100
            let nw = exp(-C / 12) * (L > 12 && L < 92 ? 1 : 0.1) * dw
            nW += nw; nA += nw * a; nB += nw * b
            let soft = exp(-C / 25) * dw
            let ws = (1 - t) * (1 - t) * soft, wh = t * t * soft, wm = 2 * t * (1 - t) * soft
            sW += ws; sA += ws * a; sB += ws * b
            mW += wm; mA += wm * a; mB += wm * b
            hW += wh; hA += wh * a; hB += wh * b
            let (h, s) = rgbToHS(Double(r8) / 255, Double(g8) / 255, Double(b8) / 255)
            let sw = min(1, max(0, (s - 0.12) / 0.15)) * (L > 8 && L < 97 ? 1 : 0) * dw
            if sw > 0 {
                let (i0, w0, i1, w1) = bandWeights(h)
                for (bi, bw) in [(i0, w0), (i1, w1)] {
                    let w = bw * sw
                    if w <= 0 { continue }
                    bW[bi] += w; bS[bi] += w * s; bH[bi] += w * hueDelta(h, HSLBand.centers[bi]); bL[bi] += w * L
                }
            }
        }
        var st = ImageStats()
        var acc = 0.0, pi = 0
        for k in 0...1000 where pi < percentiles.count {
            acc += hist[k]
            while pi < percentiles.count && acc >= percentiles[pi] / 100 * cnt { st.lumPct.append(Double(k) / 10); pi += 1 }
        }
        while st.lumPct.count < percentiles.count { st.lumPct.append(100) }
        if chromas.isEmpty { chromas = [0] }
        chromas.sort()
        let half = chromas.count / 2
        func mean(_ a: Int, _ b: Int) -> Double { b > a ? chromas[a..<b].reduce(0, +) / Double(b - a) : 0 }
        func div(_ x: Double, _ w: Double) -> Double { w > 1e-9 ? x / w : 0 }
        st.lumMean = lumSum / max(cnt, 1e-9)
        st.neutralA = div(nA, nW); st.neutralB = div(nB, nW)
        st.shadowA = div(sA, sW); st.shadowB = div(sB, sW)
        st.midA = div(mA, mW); st.midB = div(mB, mW)
        st.highA = div(hA, hW); st.highB = div(hB, hW)
        st.chromaMean = mean(0, chromas.count); st.chromaLow = mean(0, half); st.chromaHigh = mean(half, chromas.count)
        st.bands = (0..<8).map { i in
            let w = bW[i]
            return BandStats(weight: w / max(cnt, 1e-9), sat: w > 0 ? bS[i] / w : 0, hue: w > 0 ? bH[i] / w : 0, light: w > 0 ? bL[i] / w : 0)
        }
        st.skinFrac = kW / Double(max(n, 1))
        st.skinL = div(kL, kW); st.skinA = div(kA, kW); st.skinB = div(kB, kW); st.skinC = div(kC, kW)
        return st
    }
}
