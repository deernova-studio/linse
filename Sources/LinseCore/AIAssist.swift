// 把模型返回的 JSON 变成参数先验，并整理出"AI 判断"说明。模型输出不可信，逐项校验和限幅。和 Electron 版 aiAssist.ts 相同。
import Foundation

public struct AIAnalysis: Sendable, Equatable {
    public var sourceScene = "", targetScene = "", styleSummary = ""
    public var contentNotStyle: [String] = []
    public var isPortrait: Bool?
    public var reasons: [(slider: String, why: String)] = []
    public var prior = Params()

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceScene == rhs.sourceScene && lhs.targetScene == rhs.targetScene
            && lhs.styleSummary == rhs.styleSummary && lhs.contentNotStyle == rhs.contentNotStyle
            && lhs.isPortrait == rhs.isPortrait && lhs.prior == rhs.prior
            && lhs.reasons.elementsEqual(rhs.reasons) { $0.slider == $1.slider && $0.why == $1.why }
    }

    /// 从模型输出的 JSON 对象解析；字段缺失或类型不对都按默认值处理
    public init(json: [String: Any]) {
        func str(_ v: Any?, _ max: Int = 200) -> String { (v as? String).map { String($0.prefix(max)) } ?? "" }
        sourceScene = str(json["source_scene"])
        targetScene = str(json["target_scene"])
        styleSummary = str(json["style_summary"], 400)
        contentNotStyle = ((json["content_not_style"] as? [Any]) ?? []).map { str($0, 60) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
        isPortrait = json["is_portrait"] as? Bool
        for r in ((json["reasons"] as? [Any]) ?? []).prefix(8) {
            guard let o = r as? [String: Any] else { continue }
            let s = str(o["slider"], 20), w = str(o["why"])
            if !s.isEmpty, !w.isEmpty { reasons.append((s, w)) }
        }
        prior = Self.toPrior(json["params"] as? [String: Any] ?? [:])
    }

    static func num(_ v: Any?, _ lo: Double, _ hi: Double) -> Double {
        let n: Double
        if let d = v as? Double { n = d } else if let i = v as? Int { n = Double(i) } else if let s = v as? String, let d = Double(s) { n = d } else { return 0 }
        return n.isFinite ? min(hi, max(lo, n)) : 0
    }

    /// AI 的值只当起点；两张图内容差很多时模型容易给极端值，这里先收窄到常用范围
    static func toPrior(_ src: [String: Any]) -> Params {
        var p = Params()
        p.temperature = num(src["temperature"], -50, 50)
        p.tint = num(src["tint"], -35, 35)
        p.exposure = num(src["exposure"], -1.5, 1.5)
        p.contrast = num(src["contrast"], -60, 60)
        p.highlights = num(src["highlights"], -60, 60)
        p.shadows = num(src["shadows"], -60, 60)
        p.whites = num(src["whites"], -60, 60)
        p.blacks = num(src["blacks"], -60, 60)
        p.vibrance = num(src["vibrance"], -50, 50)
        p.saturation = num(src["saturation"], -50, 50)
        let fx = src["effects"] as? [String: Any] ?? [:]
        p.effects.clarity = num(fx["clarity"], -50, 50)
        p.effects.dehaze = num(fx["dehaze"], -40, 40)
        p.effects.vignette = num(fx["vignette"], -50, 30)
        p.effects.grain = num(fx["grain"], 0, 60)
        p.effects.grainSize = fx["grainSize"] == nil ? 25 : num(fx["grainSize"], 0, 100)
        let hsl = src["hsl"] as? [String: Any] ?? [:]
        for b in HSLBand.allCases {
            let v = hsl[b.key] as? [String: Any] ?? [:]
            var h = HSLValue()
            h.hue = num(v["hue"], -40, 40); h.sat = num(v["sat"], -60, 60); h.lum = num(v["lum"], -50, 50)
            p.setHSL(b, h)
        }
        let g = src["grading"] as? [String: Any] ?? [:]
        for (k, kp) in [("shadows", \Grading.shadows), ("midtones", \Grading.midtones), ("highlights", \Grading.highlights)] {
            let v = g[k] as? [String: Any] ?? [:]
            let hue = num(v["hue"], -720, 720).truncatingRemainder(dividingBy: 360)
            p.grading[keyPath: kp].hue = hue < 0 ? hue + 360 : hue
            p.grading[keyPath: kp].sat = num(v["sat"], 0, 40)
            p.grading[keyPath: kp].lum = 0
        }
        return p
    }

    /// AI 初值 → 实测对齐后的最终值；差得多的说明统计结果修正了 AI 的估计
    public func corrections(final f: Params) -> [String] {
        func sign(_ v: Double, _ d: Int) -> String { (v > 0 ? "+" : "") + String(format: "%.\(d)f", v) }
        var rows: [(String, Double, Double, Int)] = [
            ("色温", prior.temperature, f.temperature, 0), ("色调", prior.tint, f.tint, 0), ("曝光", prior.exposure, f.exposure, 2),
            ("对比度", prior.contrast, f.contrast, 0), ("高光", prior.highlights, f.highlights, 0), ("阴影", prior.shadows, f.shadows, 0),
            ("饱和度", prior.saturation, f.saturation, 0), ("自然饱和度", prior.vibrance, f.vibrance, 0),
        ]
        for b in HSLBand.allCases { rows.append(("\(b.label)饱和度", prior.hslValue(b).sat, f.hslValue(b).sat, 0)) }
        return rows.filter { abs($0.1) >= 3 || abs($0.2) >= 3 }.map { "\($0.0) \(sign($0.1, $0.3))→\(sign($0.2, $0.3))" }
    }

    /// 发给模型的精简统计：和估计器用的是同一套测量
    public static func statsJSON(_ st: ImageStats) -> [String: Any] {
        // 用十进制数，避免 JSON 里出现 3.7999999999999998 这种长尾
        func r(_ v: Double, _ d: Int = 1) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.\(d)f", v.isFinite ? v : 0)) }
        var bands: [String: Any] = [:]
        for b in HSLBand.allCases where b.rawValue < st.bands.count {
            let x = st.bands[b.rawValue]
            if x.weight > 0.02 { bands[b.key] = ["share_pct": r(x.weight * 100, 0), "sat_pct": r(x.sat * 100, 0), "L": r(x.light, 0)] }
        }
        let pct = st.lumPct.count >= 9 ? st.lumPct : [Double](repeating: 0, count: 9)
        return [
            "L_percentiles": ["p1": r(pct[0]), "p5": r(pct[1]), "p25": r(pct[3]), "p50": r(pct[4]), "p75": r(pct[5]), "p95": r(pct[7]), "p99": r(pct[8])],
            "neutral_ab": [r(st.neutralA), r(st.neutralB)],
            "shadow_ab": [r(st.shadowA), r(st.shadowB)],
            "highlight_ab": [r(st.highA), r(st.highB)],
            "midtone_chroma": r(st.chromaMean),
            "skin": st.skinFrac > 0.02 ? ["share_pct": r(st.skinFrac * 100, 0), "L": r(st.skinL), "a": r(st.skinA), "b": r(st.skinB), "chroma": r(st.skinC)] as Any : NSNull(),
            "hue_bands": bands,
        ]
    }
}
