import LinseCore
import SwiftUI

/// 右侧 Camera Raw 风格面板
struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var hslTab = 0
    @State private var curveChannel = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HistogramView(bins: state.histogram).frame(height: 84).padding(14)
                Divider()
                if state.matched != nil {
                    SliderRow(label: "匹配强度 %", value: Binding(get: { state.strength }, set: { state.setStrength($0) }), range: 0...150, def: 100)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                }
                Section("基本", changed: basicChanged) { basic }
                Section("色调曲线", changed: Curves.channels.contains { !Curve.isIdentity(state.params.curves[keyPath: $0]) }) { curves }
                Section("混色器", changed: !HSLTable.isIdentity(state.params)) { hsl }
                Section("颜色分级", changed: gradingChanged) { grading }
                Section("效果", changed: effectsChanged) { effects }
            }
        }
        .scrollIndicators(.automatic)
    }

    var basicChanged: Bool {
        let p = state.params
        return [p.temperature, p.tint, p.exposure, p.contrast, p.highlights, p.shadows, p.whites, p.blacks, p.vibrance, p.saturation].contains { $0 != 0 }
    }
    var gradingChanged: Bool {
        let g = state.params.grading
        return [g.shadows, g.midtones, g.highlights].contains { $0.sat != 0 || $0.lum != 0 } || g.balance != 0
    }
    var effectsChanged: Bool {
        let e = state.params.effects
        return [e.clarity, e.dehaze, e.vignette, e.grain, e.sharpen].contains { $0 != 0 }
    }

    func b(_ kp: WritableKeyPath<Params, Double>) -> Binding<Double> {
        Binding(get: { state.params[keyPath: kp] }, set: { state.params[keyPath: kp] = $0 })
    }

    @ViewBuilder var basic: some View {
        GroupTitle("白平衡")
        SliderRow(label: "色温", value: b(\.temperature), range: -100...100, track: [.blue, .gray, .yellow])
        SliderRow(label: "色调", value: b(\.tint), range: -100...100, track: [.green, .gray, .purple])
        GroupTitle("色调")
        SliderRow(label: "曝光", value: b(\.exposure), range: -5...5, step: 0.01, digits: 2)
        SliderRow(label: "对比度", value: b(\.contrast), range: -100...100)
        SliderRow(label: "高光", value: b(\.highlights), range: -100...100)
        SliderRow(label: "阴影", value: b(\.shadows), range: -100...100)
        SliderRow(label: "白色", value: b(\.whites), range: -100...100)
        SliderRow(label: "黑色", value: b(\.blacks), range: -100...100)
        GroupTitle("偏好")
        SliderRow(label: "自然饱和度", value: b(\.vibrance), range: -100...100)
        SliderRow(label: "饱和度", value: b(\.saturation), range: -100...100)
    }

    @ViewBuilder var curves: some View {
        HStack(spacing: 2) {
            ForEach(Array(["RGB", "红", "绿", "蓝"].enumerated()), id: \.offset) { i, name in
                TabText(name, on: curveChannel == i) { curveChannel = i }
            }
            Spacer()
            Button("复位此通道") { state.params.curves[keyPath: Curves.channels[curveChannel]] = [[0, 0], [255, 255]] }
                .controlSize(.small)
        }
        .padding(.bottom, 8)
        CurveEditor(points: Binding(get: { state.params.curves[keyPath: Curves.channels[curveChannel]] },
                                    set: { state.params.curves[keyPath: Curves.channels[curveChannel]] = $0 }),
                    others: Curves.channels.enumerated().filter { $0.offset != curveChannel }.map { state.params.curves[keyPath: $0.element] },
                    color: [Color.primary, .red, .green, .blue][curveChannel])
            .aspectRatio(1, contentMode: .fit)
            .help("点击添加控制点，拖动调整，双击删除")
    }

    @ViewBuilder var hsl: some View {
        HStack(spacing: 2) {
            ForEach(Array(["色相", "饱和度", "明亮度"].enumerated()), id: \.offset) { i, n in TabText(n, on: hslTab == i) { hslTab = i } }
        }
        .padding(.bottom, 6)
        ForEach(HSLBand.allCases, id: \.self) { band in
            SliderRow(label: band.label, value: Binding(
                get: { let v = state.params.hslValue(band); return [v.hue, v.sat, v.lum][hslTab] },
                set: { nv in var v = state.params.hslValue(band); if hslTab == 0 { v.hue = nv } else if hslTab == 1 { v.sat = nv } else { v.lum = nv }; state.params.setHSL(band, v) }),
                range: -100...100, track: [.gray, bandColor(band)])
        }
    }

    func bandColor(_ b: HSLBand) -> Color {
        Color(hue: [0, 30, 55, 120, 180, 225, 270, 310][b.rawValue] / 360, saturation: 0.75, brightness: 0.85)
    }

    @ViewBuilder var grading: some View {
        ForEach(Array([("阴影", \Grading.shadows), ("中间调", \Grading.midtones), ("高光", \Grading.highlights)].enumerated()), id: \.offset) { _, item in
            let (name, kp) = item
            GroupTitle(name)
            SliderRow(label: "色相", value: Binding(get: { state.params.grading[keyPath: kp].hue }, set: { state.params.grading[keyPath: kp].hue = $0 }), range: 0...360,
                      track: [.red, .yellow, .green, .cyan, .blue, .purple, .red])
            SliderRow(label: "饱和度", value: Binding(get: { state.params.grading[keyPath: kp].sat }, set: { state.params.grading[keyPath: kp].sat = $0 }), range: 0...100)
            SliderRow(label: "明亮度", value: Binding(get: { state.params.grading[keyPath: kp].lum }, set: { state.params.grading[keyPath: kp].lum = $0 }), range: -100...100)
        }
        GroupTitle("全局")
        SliderRow(label: "混合", value: Binding(get: { state.params.grading.blending }, set: { state.params.grading.blending = $0 }), range: 0...100, def: 50)
        SliderRow(label: "平衡", value: Binding(get: { state.params.grading.balance }, set: { state.params.grading.balance = $0 }), range: -100...100)
    }

    @ViewBuilder var effects: some View {
        GroupTitle("质感")
        SliderRow(label: "清晰度", value: b(\.effects.clarity), range: -100...100)
        SliderRow(label: "去雾", value: b(\.effects.dehaze), range: -100...100)
        SliderRow(label: "锐化", value: b(\.effects.sharpen), range: 0...150)
        GroupTitle("暗角")
        SliderRow(label: "数量", value: b(\.effects.vignette), range: -100...100)
        GroupTitle("颗粒")
        SliderRow(label: "数量", value: b(\.effects.grain), range: 0...100)
        SliderRow(label: "大小", value: b(\.effects.grainSize), range: 0...100, def: 25)
    }
}

// MARK: - 小组件

struct Section<Content: View>: View {
    let title: String, changed: Bool
    @ViewBuilder let content: Content
    @State private var open = true
    init(_ title: String, changed: Bool, @ViewBuilder content: () -> Content) { self.title = title; self.changed = changed; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack {
                    Text(title).font(.system(size: 10.5)).kerning(2).foregroundStyle(.secondary)
                    Spacer()
                    if changed { Circle().fill(Color.primary).frame(width: 4, height: 4) }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .light)).rotationEffect(.degrees(open ? 0 : -90)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { VStack(alignment: .leading, spacing: 2) { content }.padding(.horizontal, 14).padding(.bottom, 14) }
            Divider()
        }
    }
}

struct GroupTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).font(.system(size: 10)).kerning(1.6).foregroundStyle(.tertiary).padding(.top, 10).padding(.bottom, 2) }
}

struct TabText: View {
    let t: String, on: Bool, action: () -> Void
    init(_ t: String, on: Bool, action: @escaping () -> Void) { self.t = t; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(t).font(.system(size: 11)).foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(alignment: .bottom) { if on { Rectangle().frame(height: 1) } }
        }
        .buttonStyle(.plain)
    }
}

/// 滑块行：名称 · 细线滑块 · 数值；双击名称复位
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var digits = 0
    var def: Double = 0
    var track: [Color]? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(value != def ? .primary : .secondary).frame(width: 68, alignment: .leading)
                .lineLimit(1).onTapGesture(count: 2) { value = def }.help("双击复位")
            ThinSlider(value: $value, range: range, step: step, def: def, track: track)
            TextField("", value: $value, format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(value != def ? .primary : .secondary).frame(width: 46)
        }
        .frame(height: 22)
    }
}

/// 极简细线滑块：1px 轨道 + 空心圆点，可带颜色渐变
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double, def: Double
    let track: [Color]?
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(track.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(Color.primary.opacity(0.22)))
                    .frame(height: 1)
                Circle().strokeBorder(Color.primary, lineWidth: 1).background(Circle().fill(hover ? Color.primary : Color(nsColor: .windowBackgroundColor)))
                    .frame(width: 10, height: 10)
                    .offset(x: CGFloat(t) * (w - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let x = min(1, max(0, (g.location.x - 5) / (w - 10)))
                let raw = range.lowerBound + Double(x) * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = def })
            .onHover { hover = $0 }
        }
        .frame(height: 16)
    }
}

struct HistogramView: View {
    let bins: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            guard bins.count == 3 else { return }
            let mx = max(1, (1..<255).map { i in bins.map { $0[i] }.max()! }.max()!)
            let colors: [Color] = [.red, .green, .blue]
            ctx.blendMode = .plusLighter
            for c in 0..<3 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 {
                    p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - CGFloat(min(1, bins[c][i] / mx)) * (size.height - 4)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.fill(p, with: .color(colors[c].opacity(0.6)))
            }
        }
    }
}
