// Camera Raw 风格的参数模型。所有数值都是"滑块值"，渲染管线负责把它们翻译成像素运算。
// 和 Electron 版的 params.ts 一一对应；字段名保持一致，参数 JSON 可以互相导入。
import Foundation

public enum HSLBand: Int, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    public var label: String { ["红色", "橙色", "黄色", "绿色", "浅绿色", "蓝色", "紫色", "洋红"][rawValue] }
    public var key: String { ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"][rawValue] }
    /// 色相区间中心（度），与 Lightroom 的混色器分区一致
    public static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
}

public struct HSLValue: Codable, Equatable, Sendable {
    public var hue = 0.0, sat = 0.0, lum = 0.0
    public init(hue: Double = 0, sat: Double = 0, lum: Double = 0) { self.hue = hue; self.sat = sat; self.lum = lum }
    public var isZero: Bool { hue == 0 && sat == 0 && lum == 0 }
}

public struct GradeWheel: Codable, Equatable, Sendable {
    public var hue = 0.0, sat = 0.0, lum = 0.0 // hue 0..360, sat 0..100, lum -100..100
    public init(hue: Double = 0, sat: Double = 0, lum: Double = 0) { self.hue = hue; self.sat = sat; self.lum = lum }
}

public struct Grading: Codable, Equatable, Sendable {
    public var shadows = GradeWheel(), midtones = GradeWheel(), highlights = GradeWheel()
    public var blending = 50.0, balance = 0.0
    public init() {}
}

public struct Effects: Codable, Equatable, Sendable {
    public var clarity = 0.0, dehaze = 0.0, vignette = 0.0, grain = 0.0, grainSize = 25.0, sharpen = 0.0
    public init() {}
}

public struct LutRef: Codable, Equatable, Sendable {
    public var id: String, name: String, intensity: Double
    public init(id: String, name: String, intensity: Double = 100) { self.id = id; self.name = name; self.intensity = intensity }
}

public enum MaskType: String, Codable, Sendable, CaseIterable {
    case radial, linear, luminance
    case person, subject, sky // 识别出的位图蒙版
    public var isSmart: Bool { self == .person || self == .subject || self == .sky }
    public var label: String {
        ["radial": "径向渐变", "linear": "线性渐变", "luminance": "亮度范围", "person": "人物", "subject": "主体", "sky": "天空"][rawValue]!
    }
}

public struct MaskAdjust: Codable, Equatable, Sendable {
    public var exposure = 0.0, contrast = 0.0, temperature = 0.0, tint = 0.0, saturation = 0.0
    public init() {}
}

public struct Mask: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var type: MaskType
    public var enabled = true, invert = false
    // radial：中心 (cx,cy) 与半径 (rx,ry)，归一化 0..1；linear：从 (cx,cy) 到 (x2,y2) 渐变
    public var cx = 0.5, cy = 0.5, rx = 0.3, ry = 0.3, x2 = 0.5, y2 = 0.5
    public var feather = 50.0
    public var lumMin = 60.0, lumMax = 100.0 // luminance：亮度范围 0..100
    public var adjust = MaskAdjust()

    public init(type: MaskType, index: Int) {
        self.type = type
        self.name = "\(type.label) \(index)"
        if type == .linear { cy = 0 }
        if type.isSmart { feather = 20 }
    }
}

public typealias CurvePoint = [Double] // [x, y]，0..255

public struct Curves: Codable, Equatable, Sendable {
    public var rgb: [CurvePoint] = [[0, 0], [255, 255]]
    public var r: [CurvePoint] = [[0, 0], [255, 255]]
    public var g: [CurvePoint] = [[0, 0], [255, 255]]
    public var b: [CurvePoint] = [[0, 0], [255, 255]]
    public init() {}
    public static let channels: [WritableKeyPath<Curves, [CurvePoint]>] = [\.rgb, \.r, \.g, \.b]
}

public struct Params: Codable, Equatable, Sendable {
    public var temperature = 0.0, tint = 0.0          // -100..100
    public var exposure = 0.0                          // EV
    public var contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    public var vibrance = 0.0, saturation = 0.0
    public var curves = Curves()
    public var hsl: [String: HSLValue] = Dictionary(uniqueKeysWithValues: HSLBand.allCases.map { ($0.key, HSLValue()) })
    public var grading = Grading()
    public var effects = Effects()
    public var lut: LutRef?
    public var masks: [Mask] = []

    public init() {}

    public static let maxMasks = 4

    public func hslValue(_ b: HSLBand) -> HSLValue { hsl[b.key] ?? HSLValue() }
    public mutating func setHSL(_ b: HSLBand, _ v: HSLValue) { hsl[b.key] = v }

    // 外部来的 JSON（Electron 版参数文件、旧预设）字段可能不全：逐个字段解码，缺的用默认值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)).flatMap { $0?.isFinite == true ? $0 : nil } ?? 0 }
        temperature = d(.temperature); tint = d(.tint); exposure = d(.exposure)
        contrast = d(.contrast); highlights = d(.highlights); shadows = d(.shadows); whites = d(.whites); blacks = d(.blacks)
        vibrance = d(.vibrance); saturation = d(.saturation)
        curves = (try? c.decodeIfPresent(Curves.self, forKey: .curves)) ?? Curves()
        let raw = (try? c.decodeIfPresent([String: HSLValue].self, forKey: .hsl)) ?? [:]
        hsl = Dictionary(uniqueKeysWithValues: HSLBand.allCases.map { ($0.key, raw[$0.key] ?? HSLValue()) })
        grading = (try? c.decodeIfPresent(Grading.self, forKey: .grading)) ?? Grading()
        effects = (try? c.decodeIfPresent(Effects.self, forKey: .effects)) ?? Effects()
        lut = try? c.decodeIfPresent(LutRef.self, forKey: .lut)
        masks = Array(((try? c.decodeIfPresent([Mask].self, forKey: .masks)) ?? []).prefix(Params.maxMasks))
    }
}

// 子结构同样容忍缺字段
extension HSLValue {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = ((try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? nil) ?? 0
        sat = ((try? c.decodeIfPresent(Double.self, forKey: .sat)) ?? nil) ?? 0
        lum = ((try? c.decodeIfPresent(Double.self, forKey: .lum)) ?? nil) ?? 0
    }
}
extension GradeWheel {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = ((try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? nil) ?? 0
        sat = ((try? c.decodeIfPresent(Double.self, forKey: .sat)) ?? nil) ?? 0
        lum = ((try? c.decodeIfPresent(Double.self, forKey: .lum)) ?? nil) ?? 0
    }
}
extension Grading {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = ((try? c.decodeIfPresent(GradeWheel.self, forKey: .shadows)) ?? nil) ?? GradeWheel()
        midtones = ((try? c.decodeIfPresent(GradeWheel.self, forKey: .midtones)) ?? nil) ?? GradeWheel()
        highlights = ((try? c.decodeIfPresent(GradeWheel.self, forKey: .highlights)) ?? nil) ?? GradeWheel()
        blending = ((try? c.decodeIfPresent(Double.self, forKey: .blending)) ?? nil) ?? 50
        balance = ((try? c.decodeIfPresent(Double.self, forKey: .balance)) ?? nil) ?? 0
    }
}
extension Curves {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func ok(_ k: CodingKeys) -> [CurvePoint] {
            guard let v = (try? c.decodeIfPresent([CurvePoint].self, forKey: k)) ?? nil, v.count >= 2,
                  v.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return [[0, 0], [255, 255]] }
            return v.map { [min(255, max(0, $0[0])), min(255, max(0, $0[1]))] }
        }
        rgb = ok(.rgb); r = ok(.r); g = ok(.g); b = ok(.b)
    }
}
extension Effects {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ def: Double) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? def }
        clarity = d(.clarity, 0); dehaze = d(.dehaze, 0); vignette = d(.vignette, 0)
        grain = d(.grain, 0); grainSize = d(.grainSize, 25); sharpen = d(.sharpen, 0)
    }
}
