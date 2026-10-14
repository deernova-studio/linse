// 内置风格预设（与 Electron 版一致）
import Foundation

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: String, name: String, builtin: Bool, params: Params
    public var createdAt: Date?
    public init(id: String, name: String, builtin: Bool = false, params: Params, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.builtin = builtin; self.params = params; self.createdAt = createdAt
    }

    public static let builtins: [Preset] = [
        make("film-warm", "胶片暖调") {
            $0.temperature = 18; $0.tint = 4; $0.contrast = -10; $0.highlights = -20; $0.shadows = 15; $0.vibrance = -10; $0.saturation = -8
            $0.curves.rgb = [[0, 18], [255, 250]]
            $0.grading.shadows = GradeWheel(hue: 200, sat: 10); $0.grading.highlights = GradeWheel(hue: 40, sat: 18)
            $0.effects.grain = 28; $0.effects.grainSize = 30; $0.effects.vignette = -12
        },
        make("teal-orange", "青橙电影") {
            $0.temperature = -6; $0.contrast = 20; $0.highlights = -25; $0.shadows = 10; $0.vibrance = 10
            $0.setHSL(.orange, HSLValue(sat: 15)); $0.setHSL(.aqua, HSLValue(hue: -20)); $0.setHSL(.blue, HSLValue(hue: -15, sat: 10))
            $0.grading.shadows = GradeWheel(hue: 195, sat: 30); $0.grading.highlights = GradeWheel(hue: 35, sat: 25)
            $0.effects.clarity = 10; $0.effects.vignette = -18
        },
        make("jp-fresh", "日系清新") {
            $0.exposure = 0.35; $0.temperature = -8; $0.tint = 3; $0.contrast = -20; $0.highlights = -30; $0.shadows = 30; $0.whites = 10; $0.blacks = 15
            $0.vibrance = -5; $0.saturation = -12; $0.curves.rgb = [[0, 20], [255, 255]]
            $0.setHSL(.green, HSLValue(hue: 20, sat: -20)); $0.setHSL(.blue, HSLValue(sat: -10))
            $0.effects.dehaze = -8
        },
        make("portrait-clear", "人像通透") {
            $0.exposure = 0.2; $0.contrast = 5; $0.highlights = -25; $0.shadows = 20; $0.whites = 10; $0.vibrance = 12
            $0.setHSL(.orange, HSLValue(sat: -8, lum: 15)); $0.setHSL(.red, HSLValue(lum: 8))
            $0.effects.clarity = -8; $0.effects.dehaze = 6
        },
        make("cool-minimal", "冷调极简") {
            $0.temperature = -20; $0.contrast = 10; $0.vibrance = -10; $0.saturation = -25
            $0.grading.shadows = GradeWheel(hue: 215, sat: 15); $0.grading.highlights = GradeWheel(hue: 210, sat: 8)
            $0.effects.clarity = 12
        },
        make("retro-fade", "复古褪色") {
            $0.temperature = 10; $0.contrast = -15; $0.saturation = -20; $0.curves.rgb = [[0, 35], [64, 70], [192, 200], [255, 235]]
            $0.grading.shadows = GradeWheel(hue: 160, sat: 12); $0.grading.highlights = GradeWheel(hue: 45, sat: 15)
            $0.effects.grain = 40; $0.effects.grainSize = 45; $0.effects.vignette = -20
        },
        make("moody-dark", "暗调氛围") {
            $0.exposure = -0.4; $0.contrast = 25; $0.highlights = -30; $0.shadows = -20; $0.blacks = -15; $0.saturation = -15
            $0.grading.shadows = GradeWheel(hue: 220, sat: 15); $0.grading.highlights = GradeWheel(hue: 35, sat: 12)
            $0.effects.clarity = 18; $0.effects.vignette = -30
        },
        make("bw-contrast", "黑白高反差") {
            $0.saturation = -100; $0.contrast = 35; $0.highlights = -15; $0.shadows = -10; $0.whites = 20; $0.blacks = -15
            $0.effects.clarity = 25; $0.effects.grain = 22; $0.effects.grainSize = 20
        },
    ]

    static func make(_ id: String, _ name: String, _ f: (inout Params) -> Void) -> Preset {
        var p = Params(); f(&p)
        return Preset(id: id, name: name, builtin: true, params: p)
    }
}
