// 导出 Lightroom / Camera Raw 预设（.xmp）。字段名是 Adobe 的 crs 命名空间；
// 本应用的渲染数学不是 Adobe 的，所以在 Lightroom 里套用后效果会接近但不会完全一致。蒙版不导出。和 Electron 版 xmp.ts 相同。
import Foundation

public enum XMP {
    static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func sgn(_ v: Double, _ digits: Int = 0) -> String {
        let r = digits == 0 ? v.rounded() : (v * 100).rounded() / 100
        let s = digits == 0 ? String(Int(r)) : String(format: "%.2f", r)
        return r > 0 ? "+" + s : s
    }
    static func int(_ v: Double) -> String { String(Int(v.rounded())) }

    static func curveSeq(_ tag: String, _ pts: [CurvePoint]) -> String {
        let items = pts.map { "      <rdf:li>\(Int($0[0].rounded())), \(Int($0[1].rounded()))</rdf:li>" }.joined(separator: "\n")
        return "   <crs:\(tag)>\n    <rdf:Seq>\n\(items)\n    </rdf:Seq>\n   </crs:\(tag)>"
    }

    public static func make(_ p: Params, name: String) -> String {
        let g = p.grading, e = p.effects
        var attrs: [(String, String)] = [
            ("PresetType", "Normal"), ("UUID", UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            ("SupportsAmount", "False"), ("SupportsColor", "True"), ("SupportsMonochrome", "True"),
            ("SupportsHighDynamicRange", "True"), ("SupportsNormalDynamicRange", "True"),
            ("SupportsSceneReferred", "True"), ("SupportsOutputReferred", "True"),
            ("Version", "15.0"), ("ProcessVersion", "11.0"),
            ("IncrementalTemperature", sgn(p.temperature)), ("IncrementalTint", sgn(p.tint)),
            ("Exposure2012", sgn(p.exposure, 2)), ("Contrast2012", sgn(p.contrast)),
            ("Highlights2012", sgn(p.highlights)), ("Shadows2012", sgn(p.shadows)),
            ("Whites2012", sgn(p.whites)), ("Blacks2012", sgn(p.blacks)),
            ("Vibrance", sgn(p.vibrance)), ("Saturation", sgn(p.saturation)),
            ("ToneCurveName2012", "Custom"),
            ("ColorGradeShadowHue", int(g.shadows.hue)), ("ColorGradeShadowSat", int(g.shadows.sat)), ("ColorGradeShadowLum", sgn(g.shadows.lum)),
            ("ColorGradeMidtoneHue", int(g.midtones.hue)), ("ColorGradeMidtoneSat", int(g.midtones.sat)), ("ColorGradeMidtoneLum", sgn(g.midtones.lum)),
            ("ColorGradeHighlightHue", int(g.highlights.hue)), ("ColorGradeHighlightSat", int(g.highlights.sat)), ("ColorGradeHighlightLum", sgn(g.highlights.lum)),
            ("ColorGradeBlending", int(g.blending)), ("SplitToningBalance", sgn(g.balance)),
            ("Clarity2012", sgn(e.clarity)), ("Dehaze", sgn(e.dehaze)), ("PostCropVignetteAmount", sgn(e.vignette)),
            ("GrainAmount", int(e.grain)), ("Sharpness", int(e.sharpen)), ("GrainSize", int(e.grainSize)),
            ("HasSettings", "True"),
        ]
        for b in HSLBand.allCases {
            let v = p.hslValue(b), n = bandNames[b.rawValue]
            attrs += [("HueAdjustment\(n)", sgn(v.hue)), ("SaturationAdjustment\(n)", sgn(v.sat)), ("LuminanceAdjustment\(n)", sgn(v.lum))]
        }
        let attrText = attrs.map { "   crs:\($0.0)=\"\(esc($0.1))\"" }.joined(separator: "\n")
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="临色">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(attrText)>
           <crs:Name>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(esc(name))</rdf:li>
            </rdf:Alt>
           </crs:Name>
           <crs:Group>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">临色</rdf:li>
            </rdf:Alt>
           </crs:Group>
        \(curveSeq("ToneCurvePV2012", p.curves.rgb))
        \(curveSeq("ToneCurvePV2012Red", p.curves.r))
        \(curveSeq("ToneCurvePV2012Green", p.curves.g))
        \(curveSeq("ToneCurvePV2012Blue", p.curves.b))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }
}
