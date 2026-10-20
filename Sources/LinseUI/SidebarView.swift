import LinseCore
import SwiftUI

/// 左栏：两张图的槽位 + 改动 / 预设
struct SidebarView: View {
    @ObservedObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                SlotView(title: "原图", slot: state.source) { state.inspectOrImport(.source) }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .onDrop(of: [.fileURL], isTargeted: nil) { drop($0, .source) }
                SlotView(title: "目标图", slot: state.target) { state.inspectOrImport(.target) }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .onDrop(of: [.fileURL], isTargeted: nil) { drop($0, .target) }
            }
            .padding(14)
            Divider()
            HStack(spacing: 2) {
                TabText("改动", on: tab == 0) { tab = 0 }
                TabText("预设", on: tab == 1) { tab = 1 }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                if tab == 0 { ChangesList(state: state).padding(14) } else { PresetsView(state: state).padding(14) }
            }
        }
    }

    func drop(_ providers: [NSItemProvider], _ k: AppState.SlotKind) -> Bool {
        state.importDroppedImages(providers, into: [k])
    }

}

struct SlotView: View {
    let title: String
    let slot: Slot?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                Rectangle().fill(Color.primary.opacity(0.04))
                    .frame(height: 84)
                    // 图片只填充已分配的槽位，不能用自身宽高比撑大侧栏。
                    .overlay {
                        if let t = slot?.thumb { Image(cg: t).resizable().scaledToFill() }
                        else { Image(systemName: "plus").font(.body).foregroundStyle(.secondary) }
                    }
                    .clipped()
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: slot == nil ? [3, 3] : [])))
            }
            .buttonStyle(NeutralButtonStyle(cornerRadius: 0, outlined: true))
            .accessibilityLabel(slot == nil ? "导入\(title)" : "查看\(title)")
            .help(slot.map { "查看\(title)：\($0.name)" } ?? "导入\(title)")
            Text(title).font(AppTypography.sectionTitle).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// 改动列表：像表单一样一行一项，只列非零的参数
struct ChangesList: View {
    @ObservedObject var state: AppState

    var body: some View {
        let rows = Self.rows(state.params)
        VStack(alignment: .leading, spacing: 0) {
            if let s = state.summary {
                HStack {
                    Text(s.source).font(.system(size: 12))
                    Spacer()
                    if s.stale { Text("图已更换").font(.system(size: 10)).foregroundStyle(.orange) }
                    else if s.secs > 0 { Text(String(format: "%.1f 秒", s.secs)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
                }
                .padding(.bottom, 10)
                if let ai = s.ai { AINotes(ai: ai, corrections: s.aiCorrections).padding(.bottom, 12) }
            }
            if rows.isEmpty {
                Text("还没有改动").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 24)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                if r.1.isEmpty { GroupTitle(r.0) }
                else {
                    HStack {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(r.1).font(.system(size: 12).monospacedDigit())
                    }
                    .frame(height: 22)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
                }
            }
        }
    }

    static func f(_ v: Double, _ d: Int = 0) -> String { (v > 0 ? "+" : "") + String(format: "%.\(d)f", v) }

    /// (名称, 值)；值为空表示分组标题
    static func rows(_ p: Params) -> [(String, String)] {
        var out: [(String, String)] = []
        func group(_ t: String, _ items: [(String, String)]) { if !items.isEmpty { out.append((t, "")); out += items } }
        let nz: [(String, Double, Int)] = [("色温", p.temperature, 0), ("色调", p.tint, 0), ("曝光", p.exposure, 2), ("对比度", p.contrast, 0), ("高光", p.highlights, 0),
                                           ("阴影", p.shadows, 0), ("白色", p.whites, 0), ("黑色", p.blacks, 0), ("自然饱和度", p.vibrance, 0), ("饱和度", p.saturation, 0)]
        group("基本", nz.filter { abs($0.1) >= 0.5 * pow(10, -Double($0.2)) }.map { ($0.0, f($0.1, $0.2)) })
        let names = ["RGB", "红", "绿", "蓝"]
        group("曲线", Curves.channels.enumerated().compactMap { i, kp in
            let pts = p.curves[keyPath: kp]
            return Curve.isIdentity(pts) ? nil : (names[i], "\(pts.count) 个点")
        })
        var hsl: [(String, String)] = []
        for b in HSLBand.allCases {
            let v = p.hslValue(b)
            let parts = [("色相", v.hue), ("饱和", v.sat), ("明亮", v.lum)].filter { abs($0.1) >= 0.5 }.map { "\($0.0) \(f($0.1))" }
            if !parts.isEmpty { hsl.append((b.label, parts.joined(separator: "  "))) }
        }
        group("混色器", hsl)
        var gr: [(String, String)] = []
        for (n, w) in [("阴影", p.grading.shadows), ("中间调", p.grading.midtones), ("高光", p.grading.highlights)] where w.sat >= 0.5 || abs(w.lum) >= 0.5 {
            gr.append((n, "\(Int(w.hue))°  饱和 \(Int(w.sat))" + (abs(w.lum) >= 0.5 ? "  明亮 \(f(w.lum))" : "")))
        }
        if abs(p.grading.balance) >= 0.5 { gr.append(("平衡", f(p.grading.balance))) }
        group("颜色分级", gr)
        if let l = p.lut { group("滤镜", [(l.name, "\(Int(l.intensity))%")]) }
        let e = p.effects
        group("效果", [("清晰度", e.clarity), ("去雾", e.dehaze), ("锐化", e.sharpen), ("暗角", e.vignette), ("颗粒", e.grain)].filter { abs($0.1) >= 0.5 }.map { ($0.0, f($0.1)) })
        group("蒙版", p.masks.map { ($0.name, $0.enabled ? "启用" : "停用") })
        return out
    }
}

/// AI 看图的判断：场景、风格、排除的内容、每个滑块的理由、实测对 AI 初值的修正
struct AINotes: View {
    let ai: AIAnalysis
    let corrections: [String]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ai.styleSummary.isEmpty { Text(ai.styleSummary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            if !ai.contentNotStyle.isEmpty {
                Text("不当作风格：" + ai.contentNotStyle.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ai.reasons.isEmpty || !corrections.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(open ? "收起 AI 判断" : "展开 AI 判断").font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 8)).rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(NeutralButtonStyle())
            }
            if open {
                ForEach(Array(ai.reasons.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.slider).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(r.why).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !corrections.isEmpty {
                    GroupTitle("AI 初值 → 实测后")
                    ForEach(corrections, id: \.self) { Text($0).font(.system(size: 11).monospacedDigit()) }
                }
            }
        }
        .padding(10)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// 预设库：存当前调整、我的预设、内置预设，缩略图用当前原图渲染
struct PresetsView: View {
    @ObservedObject var state: AppState
    var columns = 2
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if naming {
                HStack {
                    TextField("预设名称", text: $newName).textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit { save() }
                    Button("存") { save() }.buttonStyle(NeutralButtonStyle()).font(.system(size: 12))
                    Button("取消") { naming = false }.buttonStyle(NeutralButtonStyle()).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 1) }
            } else {
                Button { newName = ""; naming = true } label: { Label("把当前调整存为预设", systemImage: "plus").font(.system(size: 12)) }
                    .buttonStyle(NeutralButtonStyle()).disabled(state.source == nil)
            }
            if !state.userPresets.isEmpty {
                GroupTitle("我的")
                grid(state.userPresets)
            }
            GroupTitle("内置")
            grid(Preset.builtins)
        }
    }

    func save() { state.saveCurrentAsPreset(name: newName.trimmingCharacters(in: .whitespaces)); naming = false }

    func grid(_ list: [Preset]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 12) {
            ForEach(list) { p in
                Button { state.applyPreset(p) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Rectangle().fill(Color.primary.opacity(0.05))
                            .frame(height: 74)
                            .overlay {
                                if let img = state.thumbnail(for: p) { Image(cg: img).resizable().scaledToFill() }
                            }
                            .clipped()
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        Text(p.name).font(.system(size: 11)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NeutralButtonStyle(cornerRadius: 0, outlined: true))
                .contextMenu { if !p.builtin { Button("删除") { state.deletePreset(p) } } }
            }
        }
    }
}

