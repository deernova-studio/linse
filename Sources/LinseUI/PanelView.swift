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
                PanelSection("基本", changed: basicChanged) { basic }
                PanelSection("色调曲线", changed: Curves.channels.contains { !Curve.isIdentity(state.params.curves[keyPath: $0]) }) { curves }
                PanelSection("混色器", changed: !HSLTable.isIdentity(state.params)) { hsl }
                PanelSection("颜色分级", changed: gradingChanged) { grading }
                PanelSection("滤镜 LUT", changed: state.params.lut != nil) { lut }
                PanelSection("效果", changed: effectsChanged) { effects }
                PanelSection("蒙版", changed: !state.params.masks.isEmpty) { MaskPanel(state: state) }
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

    @ViewBuilder var lut: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { state.params.lut?.id ?? "" }, set: { state.selectLUT($0.isEmpty ? nil : $0) })) {
                Text("无").tag("")
                ForEach(state.lutList, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().controlSize(.small)
            Button("导入…") { state.importLUT() }.controlSize(.small).help("导入 .cube 格式的 3D LUT")
            if let id = state.params.lut?.id {
                Button("删除") { state.deleteLUT(id) }.controlSize(.small).help("从本机删除这个 LUT")
            }
        }
        .padding(.top, 4)
        if state.params.lut != nil {
            SliderRow(label: "强度", value: Binding(get: { state.params.lut?.intensity ?? 0 }, set: { state.params.lut?.intensity = $0 }), range: 0...100, def: 100)
        }
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

// MARK: - 蒙版

struct MaskPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([[MaskType.person, .subject, .sky], [.radial, .linear, .luminance]], id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { t in
                        Button { state.addMask(t) } label: {
                            Label(t.label, systemImage: t.isSmart ? "wand.and.stars" : "plus").font(.system(size: 11)).frame(maxWidth: .infinity)
                        }
                        .controlSize(.small).disabled(state.params.masks.count >= Params.maxMasks || state.busy != nil)
                        .help(t.isSmart ? "自动识别\(t.label)" : "")
                    }
                }
            }
        }
        .padding(.top, 4)
        ForEach(state.params.masks) { m in
            let on = m.id == state.selectedMask
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { m.enabled }, set: { v in update(m.id) { $0.enabled = v } })).labelsHidden().controlSize(.mini).help("启用")
                Text(m.name).font(.system(size: 12)).foregroundStyle(on ? .primary : .secondary)
                Spacer()
                Button("删除蒙版", systemImage: "xmark") { state.deleteMask(m.id) }
                    .labelStyle(.iconOnly).font(.system(size: 9))
                    .buttonStyle(NeutralButtonStyle()).foregroundStyle(.secondary).help("删除")
            }
            .padding(.horizontal, 8).frame(height: 26)
            .overlay(Rectangle().stroke(Color.primary.opacity(on ? 0.5 : 0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .modifier(ControlFeedback(cornerRadius: 0))
            .onTapGesture { state.selectedMask = on ? nil : m.id }
            .help(m.type == .radial || m.type == .linear ? "点击选中后，可以在图上拖动摆放" : "点击选中")
        }
        if let i = state.selectedMaskIndex {
            let m = state.params.masks[i]
            HStack(spacing: 16) {
                Toggle("显示蒙版叠加", isOn: $state.showMaskOverlay)
                Toggle("反相", isOn: Binding(get: { m.invert }, set: { v in update(m.id) { $0.invert = v } }))
            }
            .font(.system(size: 11)).controlSize(.small).padding(.top, 6)
            GroupTitle("范围")
            switch m.type {
            case .radial:
                row("中心 X", m.id, \.cx, 0...100, 50, scale: 100)
                row("中心 Y", m.id, \.cy, 0...100, 50, scale: 100)
                row("宽度", m.id, \.rx, 1...100, 30, scale: 100)
                row("高度", m.id, \.ry, 1...100, 30, scale: 100)
                row("羽化", m.id, \.feather, 0...100, 50)
            case .linear:
                row("起点 X", m.id, \.cx, 0...100, 50, scale: 100)
                row("起点 Y", m.id, \.cy, 0...100, 0, scale: 100)
                row("终点 X", m.id, \.x2, 0...100, 50, scale: 100)
                row("终点 Y", m.id, \.y2, 0...100, 50, scale: 100)
            case .luminance:
                row("亮度下限", m.id, \.lumMin, 0...100, 60)
                row("亮度上限", m.id, \.lumMax, 0...100, 100)
                row("平滑", m.id, \.feather, 0...100, 50)
            case .person, .subject, .sky:
                row("羽化", m.id, \.feather, 0...100, 20)
            }
            GroupTitle("局部调整")
            row("曝光", m.id, \.adjust.exposure, -4...4, 0, step: 0.01, digits: 2)
            row("对比度", m.id, \.adjust.contrast, -100...100, 0)
            row("色温", m.id, \.adjust.temperature, -100...100, 0)
            row("色调", m.id, \.adjust.tint, -100...100, 0)
            row("饱和度", m.id, \.adjust.saturation, -100...100, 0)
        }
    }

    func update(_ id: String, _ f: (inout Mask) -> Void) {
        guard let i = state.params.masks.firstIndex(where: { $0.id == id }) else { return }
        f(&state.params.masks[i])
    }

    func row(_ label: String, _ id: String, _ kp: WritableKeyPath<Mask, Double>, _ range: ClosedRange<Double>, _ def: Double,
             scale: Double = 1, step: Double = 1, digits: Int = 0) -> some View {
        SliderRow(label: label, value: Binding(
            get: { (state.params.masks.first { $0.id == id }?[keyPath: kp] ?? 0) * scale },
            set: { v in update(id) { $0[keyPath: kp] = v / scale } }), range: range, step: step, digits: digits, def: def)
    }
}

// MARK: - 小组件

struct PanelSection<Content: View>: View {
    let title: String, changed: Bool
    @ViewBuilder let content: Content
    @State private var open = true
    init(_ title: String, changed: Bool, @ViewBuilder content: () -> Content) {
        self.title = title; self.changed = changed; self.content = content()
        // 开发自测：LINSE_PANEL_FOCUS 只展开列出的分区
        if let f = ProcessInfo.processInfo.environment["LINSE_PANEL_FOCUS"] { _open = State(initialValue: f.split(separator: ",").contains { $0 == title }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack {
                    Text(title).font(AppTypography.sectionTitle).foregroundStyle(.primary)
                    Spacer()
                    if changed { Circle().fill(Color.primary).frame(width: 4, height: 4) }
                    Image(systemName: "chevron.down").font(.system(size: 10)).rotationEffect(.degrees(open ? 0 : -90)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(NeutralButtonStyle(cornerRadius: 0))
            if open { VStack(alignment: .leading, spacing: 2) { content }.padding(.horizontal, 14).padding(.bottom, 14) }
            Divider()
        }
    }
}

struct GroupTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).font(AppTypography.groupTitle).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 2) }
}

struct TabText: View {
    let t: String, on: Bool, action: () -> Void
    init(_ t: String, on: Bool, action: @escaping () -> Void) { self.t = t; self.on = on; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(t).font(AppTypography.tab).foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(alignment: .bottom) { if on { Rectangle().frame(height: 1) } }
        }
        .buttonStyle(NeutralButtonStyle())
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
                Circle().strokeBorder(Color.primary, lineWidth: 1).background(Circle().fill(hover ? Color.primary : Color.appBackground))
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
