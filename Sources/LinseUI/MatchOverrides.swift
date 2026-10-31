import LinseCore

/// 手动设定的字段不再随匹配强度变化；其余字段始终从原匹配结果重新计算。
/// 记录字段名而非浮点差值，避免强度归零或限幅后丢失编辑。
enum MatchOverrides {
    private struct Field {
        let name: String
        let differs: (Params, Params) -> Bool
        let copy: (Params, inout Params) -> Void
        init<T: Equatable>(_ name: String, _ key: WritableKeyPath<Params, T>) {
            self.name = name
            differs = { $0[keyPath: key] != $1[keyPath: key] }
            copy = { source, target in target[keyPath: key] = source[keyPath: key] }
        }
    }

    private static let fields: [Field] = [
        Field("temperature", \.temperature),
        Field("tint", \.tint),
        Field("exposure", \.exposure),
        Field("contrast", \.contrast),
        Field("highlights", \.highlights),
        Field("shadows", \.shadows),
        Field("whites", \.whites),
        Field("blacks", \.blacks),
        Field("vibrance", \.vibrance),
        Field("saturation", \.saturation),
        Field("curves.rgb", \.curves.rgb),
        Field("curves.r", \.curves.r),
        Field("curves.g", \.curves.g),
        Field("curves.b", \.curves.b),
        Field("grading.shadows.hue", \.grading.shadows.hue),
        Field("grading.shadows.sat", \.grading.shadows.sat),
        Field("grading.shadows.lum", \.grading.shadows.lum),
        Field("grading.midtones.hue", \.grading.midtones.hue),
        Field("grading.midtones.sat", \.grading.midtones.sat),
        Field("grading.midtones.lum", \.grading.midtones.lum),
        Field("grading.highlights.hue", \.grading.highlights.hue),
        Field("grading.highlights.sat", \.grading.highlights.sat),
        Field("grading.highlights.lum", \.grading.highlights.lum),
        Field("grading.blending", \.grading.blending),
        Field("grading.balance", \.grading.balance),
        Field("effects.clarity", \.effects.clarity),
        Field("effects.dehaze", \.effects.dehaze),
        Field("effects.vignette", \.effects.vignette),
        Field("effects.grain", \.effects.grain),
        Field("effects.grainSize", \.effects.grainSize),
        Field("effects.sharpen", \.effects.sharpen),
        Field("lut", \.lut),
    ]

    static func changed(from old: Params, to new: Params) -> Set<String> {
        var result = Set(fields.filter { $0.differs(old, new) }.map(\.name))
        for band in HSLBand.allCases {
            for (name, key) in hslFields where old.hslValue(band)[keyPath: key] != new.hslValue(band)[keyPath: key] {
                result.insert("hsl.\(band.key).\(name)")
            }
        }
        return result
    }

    private static let hslFields: [(String, WritableKeyPath<HSLValue, Double>)] = [
        ("hue", \.hue), ("sat", \.sat), ("lum", \.lum)
    ]

    static func applying(_ names: Set<String>, values: Params, to base: Params) -> Params {
        var result = base
        for field in fields where names.contains(field.name) { field.copy(values, &result) }
        for band in HSLBand.allCases {
            var value = result.hslValue(band)
            for (name, key) in hslFields where names.contains("hsl.\(band.key).\(name)") {
                value[keyPath: key] = values.hslValue(band)[keyPath: key]
            }
            result.setHSL(band, value)
        }
        return result
    }
}
