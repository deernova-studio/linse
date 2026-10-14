// 风格匹配估计器：把"目标照片长什么样"翻译成一组滑块值。
// 每个阶段都把参数送进真实渲染管线渲染小图、量统计，再用带正则的 Levenberg–Marquardt 调这一阶段的滑块。
// 和 Electron 版 estimator.ts 相同的阶段、权重和限幅。
import Foundation

struct Spec { var lo: Double, hi: Double, step: Double, reg: Double, c: Double = 0 }

func solveLinear(_ A0: [[Double]], _ b: [Double]) -> [Double] {
    let n = b.count
    var M = A0.enumerated().map { $0.element + [b[$0.offset]] }
    for c in 0..<n {
        var piv = c
        for r in (c + 1)..<max(n, c + 1) where abs(M[r][c]) > abs(M[piv][c]) { piv = r }
        M.swapAt(c, piv)
        let d = M[c][c]
        if abs(d) < 1e-12 { continue }
        for r in 0..<n where r != c {
            let f = M[r][c] / d
            for k in c...n { M[r][k] -= f * M[c][k] }
        }
    }
    return (0..<n).map { abs(M[$0][$0]) < 1e-12 ? 0 : M[$0][n] / M[$0][$0] }
}

/// 带正则的 LM：cost = |r(p)|² + Σ (reg_i · (p_i − c_i))²
func solveLM(_ initial: [Double], _ specs: [Spec], iters: Int = 6, _ residual: ([Double]) -> [Double]) -> [Double] {
    let n = initial.count
    func clamp(_ p: [Double]) -> [Double] { p.enumerated().map { min(specs[$0.offset].hi, max(specs[$0.offset].lo, $0.element)) } }
    func full(_ p: [Double], _ r: [Double]) -> [Double] { r + p.enumerated().map { ($0.element - specs[$0.offset].c) * specs[$0.offset].reg } }
    func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }
    var p = clamp(initial)
    var r = full(p, residual(p))
    var c = cost(r)
    var lambda = 1e-2
    for _ in 0..<iters {
        var J: [[Double]] = []
        for j in 0..<n {
            var q = p
            var h = specs[j].step
            if q[j] + h > specs[j].hi { h = -h }
            q[j] += h
            let rq = full(q, residual(q))
            J.append(zip(rq, r).map { ($0 - $1) / h })
        }
        let m = r.count
        let JtJ = (0..<n).map { a in (0..<n).map { b in (0..<m).reduce(0.0) { $0 + J[a][$1] * J[b][$1] } } }
        let Jtr = (0..<n).map { a in -(0..<m).reduce(0.0) { $0 + J[a][$1] * r[$1] } }
        var improved = false
        for _ in 0..<4 {
            let A = JtJ.enumerated().map { i, row in row.enumerated().map { j, v in i == j ? v * (1 + lambda) + 1e-9 : v } }
            let delta = solveLinear(A, Jtr)
            let q = clamp(zip(p, delta).map(+))
            let rq = full(q, residual(q))
            let cq = cost(rq)
            if cq < c { p = q; r = rq; c = cq; lambda = max(lambda / 3, 1e-4); improved = true; break }
            lambda *= 8
        }
        if !improved { break }
    }
    return p
}

/// Lab 明度 → 同明度灰阶的 sRGB 8bit 值（曲线控制点用）
func lToGray(_ L: Double) -> Double {
    let fy = (L + 16) / 116
    let y = fy > 0.206893 ? fy * fy * fy : (fy - 16.0 / 116) / 7.787
    let c = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
    return min(255, max(0, c * 255))
}

func lumError(_ a: ImageStats, _ b: ImageStats) -> Double {
    zip(a.lumPct, b.lumPct).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.lumPct.count)
}

public struct MatchSummary: Sendable {
    public var lumBefore = 0.0, lumAfter = 0.0, castBefore = 0.0, castAfter = 0.0
    public var portrait = false
}

public struct MatchOptions {
    public var prior: Params?        // AI 辅助：模型给的参数作为起点和正则中心
    public var portraitHint: Bool?
    public var onProgress: ((String) -> Void)?
    public init(prior: Params? = nil, portraitHint: Bool? = nil, onProgress: ((String) -> Void)? = nil) {
        self.prior = prior; self.portraitHint = portraitHint; self.onProgress = onProgress
    }
}

public enum Estimator {
    /// 渲染器里应当已经放好原图的小图（长边约 320）
    public static func match(_ proxy: Renderer, target: ImageStats, options: MatchOptions = MatchOptions()) throws -> (Params, MatchSummary) {
        let W = Int(proxy.imageSize.width), H = Int(proxy.imageSize.height)
        var P = Params()
        let srcPx = try proxy.renderRGBA8(P, width: W, height: H, opts: RenderOptions(bypass: true))
        let srcW = Stats.detailWeights(srcPx, width: W)
        let srcSkin = Stats.skinMask(srcPx)
        func measure(_ p: Params) -> ImageStats {
            let px = (try? proxy.renderRGBA8(p, width: W, height: H)) ?? srcPx
            return Stats.compute(px, weights: srcW, skin: srcSkin)
        }
        let progress = options.onProgress ?? { _ in }
        let src = measure(P)
        let errorBefore = lumError(src, target)
        let portrait = options.portraitHint ?? (src.skinFrac > 0.03 && target.skinFrac > 0.03)
        let pri = options.prior
        // AI 初值作为正则中心，正则加强 2.5 倍；超出范围的初值先收回边界内
        func at(_ sp: Spec, _ c: Double?) -> Spec {
            guard let c else { return sp }
            var s = sp; s.c = min(sp.hi, max(sp.lo, c)); s.reg *= 2.5; return s
        }
        if let pri { P.temperature = pri.temperature; P.tint = pri.tint }
        let SK = portrait ? 4.0 : 0, NW = portrait ? 0.6 : 1.5
        func skinHue(_ st: ImageStats) -> Double { atan2(st.skinB, st.skinA) * 180 / .pi }
        let tSkinHue = skinHue(target)
        let tSkinC = src.skinC + 0.6 * (target.skinC - src.skinC)

        // 1. 白平衡
        progress("白平衡")
        func wbFit(_ p: Params) -> [Double] {
            solveLM([p.temperature, p.tint], [at(Spec(lo: -60, hi: 60, step: 4, reg: 0.015), pri?.temperature), at(Spec(lo: -60, hi: 60, step: 4, reg: 0.015), pri?.tint)], iters: 5) { v in
                var q = p; q.temperature = v[0]; q.tint = v[1]
                let s = measure(q)
                return [(s.neutralB - target.neutralB) * NW, (s.neutralA - target.neutralA) * NW, (skinHue(s) - tSkinHue) * (portrait ? 0.4 : 0)]
            }
        }
        var wb = wbFit(P); P.temperature = wb[0]; P.tint = wb[1]

        // 2. 曝光与色调：先只用曝光对齐中位数，再解其余五个
        progress("曝光与色调")
        let toneSpecs = [Spec(lo: -1.5, hi: 1.5, step: 0.1, reg: 3), Spec(lo: -50, hi: 50, step: 5, reg: 0.08), Spec(lo: -60, hi: 60, step: 5, reg: 0.06),
                         Spec(lo: -60, hi: 60, step: 5, reg: 0.06), Spec(lo: -40, hi: 40, step: 5, reg: 0.09), Spec(lo: -40, hi: 40, step: 5, reg: 0.09)]
        let pctW = [0.3, 0.6, 0.8, 1, 1.2, 1, 0.8, 0.6, 0.3]
        P.exposure = solveLM([pri?.exposure ?? 0], [at(toneSpecs[0], pri?.exposure)]) { v in
            var q = P; q.exposure = v[0]
            let st = measure(q)
            return [st.lumPct[4] - target.lumPct[4], (st.skinL - target.skinL) * SK]
        }[0]
        let toneKeys: [WritableKeyPath<Params, Double>] = [\.contrast, \.highlights, \.shadows, \.whites, \.blacks]
        let rest = solveLM(toneKeys.map { pri?[keyPath: $0] ?? 0 }, toneKeys.indices.map { at(toneSpecs[$0 + 1], pri?[keyPath: toneKeys[$0]]) }, iters: 8) { v in
            var q = P
            for (k, x) in zip(toneKeys, v) { q[keyPath: k] = x }
            let s = measure(q)
            return zip(s.lumPct, target.lumPct).enumerated().map { ($0.element.0 - $0.element.1) * pctW[$0.offset] } + [(s.skinL - target.skinL) * SK]
        }
        for (k, x) in zip(toneKeys, rest) { P[keyPath: k] = x }
        wb = wbFit(P); P.temperature = wb[0]; P.tint = wb[1]

        // 3. 色调曲线：滑块表达不了的残差交给点曲线
        progress("色调曲线")
        let cur = measure(P)
        let err = lumError(cur, target)
        if err > 1.2 {
            let pick = [1, 3, 4, 5, 7]
            var xs: [Double] = [0]
            var xk: [Int] = []
            for k in pick {
                let x = lToGray(cur.lumPct[k])
                if x - xs.last! >= 14 && x <= 241 { xs.append(x); xk.append(k) }
            }
            xs.append(255)
            let y0: [Double] = xs.indices.map { i in
                if i == 0 { let d = lToGray(target.lumPct[0]) - lToGray(cur.lumPct[0]); return d > 3 ? d : 0 }
                if i == xs.count - 1 { return 255 }
                let k = xk[i - 1]
                return xs[i] + (lToGray(target.lumPct[k]) - lToGray(cur.lumPct[k]))
            }
            func mkCurve(_ ys: [Double]) -> [CurvePoint] {
                var pts: [CurvePoint] = [], last = -1.0, lastX = 0.0
                for (i, x) in xs.enumerated() {
                    var y = min(255, x + 40, max(x - 40, ys[i]))
                    if i > 0 { let dx = x - lastX; y = min(last + dx * 2, max(last + dx * 0.5, y)) }
                    y = min(255, max(0, y))
                    pts.append([x.rounded(), y.rounded()]); last = y; lastX = x
                }
                return pts
            }
            let ys = solveLM(y0, xs.map { _ in Spec(lo: 0, hi: 255, step: 3, reg: 0) }) { v in
                var q = P; q.curves.rgb = mkCurve(v)
                let s = measure(q)
                return zip(s.lumPct, target.lumPct).enumerated().map { ($0.element.0 - $0.element.1) * pctW[$0.offset] } + v.enumerated().map { ($0.element - xs[$0.offset]) * 0.04 }
            }
            var q = P; q.curves.rgb = mkCurve(ys)
            if lumError(measure(q), target) < err - 0.3 { P.curves.rgb = q.curves.rgb }
        }

        // 4. 自然饱和度 / 饱和度
        progress("饱和度")
        let vs = solveLM([pri?.vibrance ?? 0, pri?.saturation ?? 0], [at(Spec(lo: -50, hi: 50, step: 5, reg: 0.05), pri?.vibrance), at(Spec(lo: -50, hi: 50, step: 5, reg: 0.05), pri?.saturation)]) { v in
            var q = P; q.vibrance = v[0]; q.saturation = v[1]
            let st = measure(q)
            return [st.chromaLow - target.chromaLow, st.chromaHigh - target.chromaHigh]
        }
        P.vibrance = vs[0]; P.saturation = vs[1]

        // 5. 混色器：只调两张图里都有足够像素的色相分区；人像时红/橙留给肤色阶段
        progress("混色器")
        let base = measure(P)
        let active = (0..<8).filter { base.bands[$0].weight > 0.03 && target.bands[$0].weight > 0.03 && !(portrait && $0 <= 1) }
        if !active.isEmpty {
            var specs: [Spec] = [], initial: [Double] = []
            for bi in active {
                let ph = pri?.hslValue(HSLBand(rawValue: bi)!)
                specs += [at(Spec(lo: -30, hi: 30, step: 8, reg: 0.08), ph?.hue), at(Spec(lo: -50, hi: 50, step: 8, reg: 0.05), ph?.sat), at(Spec(lo: -40, hi: 40, step: 8, reg: 0.06), ph?.lum)]
                initial += [ph?.hue ?? 0, ph?.sat ?? 0, ph?.lum ?? 0]
            }
            let v = solveLM(initial, specs, iters: 5) { vals in
                var q = P
                for (k, bi) in active.enumerated() { q.setHSL(HSLBand(rawValue: bi)!, HSLValue(hue: vals[k * 3], sat: vals[k * 3 + 1], lum: vals[k * 3 + 2])) }
                let st = measure(q)
                return active.flatMap { bi -> [Double] in
                    let a = st.bands[bi], t = target.bands[bi]
                    return [(a.hue - t.hue) * 0.15, (a.sat - t.sat) * 30, ((a.light - st.lumPct[4]) - (t.light - target.lumPct[4])) * 0.4]
                }
            }
            for (k, bi) in active.enumerated() { P.setHSL(HSLBand(rawValue: bi)!, HSLValue(hue: v[k * 3], sat: v[k * 3 + 1], lum: v[k * 3 + 2])) }
        }

        // 5b. 人像肤色：用红/橙把肤色明度、冷暖、浓淡对到目标
        func fitSkin() {
            if let pri, P.hslValue(.orange).isZero {
                P.setHSL(.orange, pri.hslValue(.orange))
                var red = P.hslValue(.red); red.sat = pri.hslValue(.red).sat; red.lum = pri.hslValue(.red).lum; P.setHSL(.red, red)
            }
            let o = P.hslValue(.orange), rd = P.hslValue(.red)
            let po = pri?.hslValue(.orange), pr = pri?.hslValue(.red)
            let v = solveLM([o.hue, o.sat, o.lum, rd.sat, rd.lum], [
                at(Spec(lo: -30, hi: 30, step: 6, reg: 0.04), po?.hue), at(Spec(lo: -60, hi: 60, step: 6, reg: 0.025), po?.sat),
                at(Spec(lo: -50, hi: 50, step: 6, reg: 0.03), po?.lum), at(Spec(lo: -60, hi: 60, step: 6, reg: 0.03), pr?.sat),
                at(Spec(lo: -50, hi: 50, step: 6, reg: 0.035), pr?.lum),
            ]) { x in
                var q = P
                q.setHSL(.orange, HSLValue(hue: x[0], sat: x[1], lum: x[2]))
                var r2 = q.hslValue(.red); r2.sat = x[3]; r2.lum = x[4]; q.setHSL(.red, r2)
                let st = measure(q)
                return [(st.skinL - target.skinL) * 1.5, (skinHue(st) - tSkinHue) * 0.4, st.skinC - tSkinC]
            }
            P.setHSL(.orange, HSLValue(hue: v[0], sat: v[1], lum: v[2]))
            var r3 = P.hslValue(.red); r3.sat = v[3]; r3.lum = v[4]; P.setHSL(.red, r3)
        }
        if portrait { progress("肤色"); fitSkin() }

        // 6. 颜色分级：和白平衡联合求解，整体偏色归白平衡，明暗之间的差异归分级
        progress("颜色分级")
        func toWheel(_ x: Double, _ y: Double) -> (Double, Double) {
            (fmod(atan2(y, x) * 180 / .pi + 360, 360), min(100, (x * x + y * y).squareRoot()))
        }
        func xy(_ w: GradeWheel?) -> [Double?] {
            guard let w else { return [nil, nil] }
            return [cos(w.hue * .pi / 180) * w.sat, sin(w.hue * .pi / 180) * w.sat]
        }
        let pw = xy(pri?.grading.shadows) + xy(pri?.grading.highlights)
        let gspecs = [at(Spec(lo: -60, hi: 60, step: 4, reg: 0.015), pri?.temperature), at(Spec(lo: -60, hi: 60, step: 4, reg: 0.015), pri?.tint)]
            + pw.map { at(Spec(lo: -35, hi: 35, step: 6, reg: 0.1), $0) }
        let g = solveLM([P.temperature, P.tint] + pw.map { $0 ?? 0 }, gspecs) { v in
            var q = P
            q.temperature = v[0]; q.tint = v[1]
            let (sh, ss) = toWheel(v[2], v[3]), (hh, hs) = toWheel(v[4], v[5])
            q.grading.shadows.hue = sh; q.grading.shadows.sat = ss; q.grading.highlights.hue = hh; q.grading.highlights.sat = hs
            let st = measure(q)
            return [(st.neutralA - target.neutralA) * NW, (st.neutralB - target.neutralB) * NW,
                    st.shadowA - target.shadowA, st.shadowB - target.shadowB, st.highA - target.highA, st.highB - target.highB,
                    (skinHue(st) - tSkinHue) * (portrait ? 0.4 : 0)]
        }
        P.temperature = g[0]; P.tint = g[1]
        let (sh, ss) = toWheel(g[2], g[3]), (hh, hs) = toWheel(g[4], g[5])
        P.grading.shadows.hue = sh; P.grading.shadows.sat = ss; P.grading.highlights.hue = hh; P.grading.highlights.sat = hs
        if portrait { fitSkin() }

        // 质感量不出来，有 AI 判断时直接采用
        if let pri { P.effects = pri.effects }

        progress("整理参数")
        P = rounded(P)
        let final = measure(P)
        var sm = MatchSummary()
        sm.lumBefore = errorBefore; sm.lumAfter = lumError(final, target)
        sm.castBefore = hypot(src.neutralA - target.neutralA, src.neutralB - target.neutralB)
        sm.castAfter = hypot(final.neutralA - target.neutralA, final.neutralB - target.neutralB)
        sm.portrait = portrait
        return (P, sm)
    }

    public static func rounded(_ p: Params) -> Params {
        var P = p
        P.temperature.round(); P.tint.round(); P.exposure = (P.exposure * 100).rounded() / 100
        for k in [\Params.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance, \.saturation] as [WritableKeyPath<Params, Double>] { P[keyPath: k].round() }
        for b in HSLBand.allCases {
            var v = P.hslValue(b); v.hue.round(); v.sat.round(); v.lum.round(); P.setHSL(b, v)
        }
        for k in [\Grading.shadows, \.midtones, \.highlights] as [WritableKeyPath<Grading, GradeWheel>] {
            P.grading[keyPath: k].hue.round(); P.grading[keyPath: k].sat.round(); P.grading[keyPath: k].lum.round()
        }
        for k in [\Effects.clarity, \.dehaze, \.vignette, \.grain, \.grainSize, \.sharpen] as [WritableKeyPath<Effects, Double>] { P.effects[keyPath: k].round() }
        return P
    }

    /// 按强度缩放匹配结果，并按各滑块范围截断
    public static func scaled(_ p: Params, _ k: Double) -> Params {
        var q = p
        func cl(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        q.temperature = cl(p.temperature * k, -100, 100); q.tint = cl(p.tint * k, -100, 100); q.exposure = cl(p.exposure * k, -5, 5)
        for kp in [\Params.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.vibrance, \.saturation] as [WritableKeyPath<Params, Double>] { q[keyPath: kp] = cl(p[keyPath: kp] * k, -100, 100) }
        for b in HSLBand.allCases { let v = p.hslValue(b); q.setHSL(b, HSLValue(hue: cl(v.hue * k, -100, 100), sat: cl(v.sat * k, -100, 100), lum: cl(v.lum * k, -100, 100))) }
        for kp in Curves.channels { q.curves[keyPath: kp] = p.curves[keyPath: kp].map { [$0[0], cl($0[0] + ($0[1] - $0[0]) * k, 0, 255)] } }
        for kp in [\Grading.shadows, \.midtones, \.highlights] as [WritableKeyPath<Grading, GradeWheel>] {
            q.grading[keyPath: kp].sat = cl(p.grading[keyPath: kp].sat * k, 0, 100); q.grading[keyPath: kp].lum = cl(p.grading[keyPath: kp].lum * k, -100, 100)
        }
        q.effects.clarity = cl(p.effects.clarity * k, -100, 100); q.effects.dehaze = cl(p.effects.dehaze * k, -100, 100)
        q.effects.vignette = cl(p.effects.vignette * k, -100, 100); q.effects.grain = cl(p.effects.grain * k, 0, 100); q.effects.sharpen = cl(p.effects.sharpen * k, 0, 150)
        if let l = p.lut { q.lut?.intensity = cl(l.intensity * k, 0, 100) }
        return rounded(q)
    }
}
