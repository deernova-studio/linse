import LinseCore
import SwiftUI

/// AI 设置。交互原则：输入过程中不报错；只有点"获取模型"或"测试连接"才发请求，
/// 打开时如果已经保存过 Key，会安静地拉一次模型列表（失败也不标红）。
struct AISettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var s = AISettings()
    @State private var key = ""
    @State private var showKey = false
    @State private var models: [String] = []
    @State private var manual = false
    @State private var modelHint = ""
    @State private var urlHint = ""
    @State private var test = ""
    @State private var testOK = false
    @State private var testing = false
    @State private var loadSeq = 0
    @State private var showPrivacy = false
    @State private var confirmClearKey = false
    @FocusState private var urlFocused: Bool

    static let efforts: [(AIEffort, String)] = [(.auto, "默认"), (.low, "低"), (.medium, "中"), (.high, "高"), (.xhigh, "很高"), (.max, "最高")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI 设置").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { dismiss() } label: {
                    Label("关闭 AI 设置", systemImage: "xmark")
                        .labelStyle(.iconOnly).font(.system(size: 11, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(NeutralButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 22).padding(.trailing, 8).padding(.vertical, 6)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                field("接口协议") {
                    Picker("接口协议", selection: $s.proto) {
                        Text("OpenAI").tag(AIProtocol.openai)
                        Text("Anthropic").tag(AIProtocol.anthropic)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                field("Base URL", hint: urlHint, warn: true) {
                    LineField {
                        TextField(s.proto == .openai ? "https://api.openai.com/v1" : "https://api.anthropic.com", text: $s.baseUrl)
                            .focused($urlFocused)
                    }
                    .help(s.proto == .openai ? "留空使用 OpenAI 官方地址；只填域名时会自动补 /v1" : "留空使用 Anthropic 官方地址")
                }
                field("API Key") {
                    LineField {
                        Group {
                            if showKey { TextField(state.aiHasKey ? "已保存 · 留空不修改" : "sk-…", text: $key) }
                            else { SecureField(state.aiHasKey ? "已保存 · 留空不修改" : "sk-…", text: $key) }
                        }
                        Button(showKey ? "隐藏 API Key" : "显示 API Key", systemImage: showKey ? "eye.slash" : "eye") { showKey.toggle() }
                            .labelStyle(.iconOnly).font(.system(size: 11))
                            .buttonStyle(NeutralButtonStyle()).foregroundStyle(.secondary)
                    }
                    if state.aiHasKey {
                        Button("清除已保存的 API Key") { confirmClearKey = true }
                            .font(.caption).buttonStyle(NeutralButtonStyle())
                    }
                }
                field("模型", hint: modelHint, warn: true) {
                    HStack(spacing: 10) {
                        if manual || models.isEmpty {
                            LineField { TextField("模型 ID", text: $s.model) }
                        } else {
                            Picker("模型", selection: Binding(get: { s.model }, set: { v in if v == "__manual__" { manual = true } else { s.model = v } })) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                                Divider()
                                Text("手动输入…").tag("__manual__")
                            }
                            .labelsHidden()
                        }
                        Button("获取模型") { Task { await loadModels(quiet: false) } }.controlSize(.small)
                            .help("只读取模型名称列表，不代表模型可以生成回复。请用“测试连接”验证当前模型。")
                    }
                }
                field("思考强度") {
                    Picker("思考强度", selection: $s.effort) { ForEach(Self.efforts, id: \.0) { Text($0.1).tag($0.0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .help(s.proto == .openai ? "作为 reasoning_effort 传递，很多模型只认 低 / 中 / 高" : "作为 effort 传递")
                }
                HStack(spacing: 10) {
                    Text("快速模式").font(.callout)
                    Spacer()
                    Text("可能增加费用").font(.subheadline).foregroundStyle(.secondary)
                    Toggle("快速模式", isOn: $s.fast)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help("优先处理请求，需当前服务和模型支持。")
                }
            }
            .padding(22)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if !test.isEmpty {
                    Text(test).font(.callout).foregroundStyle(testOK ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button(testing ? "测试中…" : "测试连接") { Task { await runTest() } }.disabled(testing)
                    Button("隐私说明") { showPrivacy = true }
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("保存") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        #if os(macOS)
        .frame(width: 480)
        #else
        .frame(maxWidth: 480)
        #endif
        .onAppear {
            s = state.aiSettings
            models = [s.model]
            if state.aiHasKey { Task { await loadModels(quiet: true) } }
        }
        .onChange(of: s.proto) {
            loadSeq += 1
            modelHint = ""; test = ""
        }
        .onChange(of: urlFocused) { _, f in
            // 只在离开输入框时检查地址格式，输入过程中不打扰
            if !f { urlHint = AIClient.urlOK(s.baseUrl) ? "" : "地址需要以 http:// 或 https:// 开头" }
        }
        .onChange(of: s.baseUrl) { if !urlHint.isEmpty, AIClient.urlOK(s.baseUrl) { urlHint = "" } }
        .onChange(of: s) { test = "" }
        .onChange(of: key) { test = "" }
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
        .confirmationDialog("清除这台设备上保存的 API Key？", isPresented: $confirmClearKey, titleVisibility: .visible) {
            Button("清除 API Key", role: .destructive, action: clearSavedKey)
            Button("取消", role: .cancel) { }
        } message: {
            Text("之后仍可离线编辑。重新使用 AI 时需要再次填写 Key。")
        }
    }

    func field<C: View>(_ title: String, hint: String = "", warn: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10.5)).kerning(1.2).foregroundStyle(.secondary)
            c()
            if !hint.isEmpty { Text(hint).font(.system(size: 10.5)).foregroundStyle(warn ? .orange : .secondary) }
        }
    }

    var effectiveKey: String { key.isEmpty ? state.aiKey() : key }

    func loadModels(quiet: Bool) async {
        guard AIClient.urlOK(s.baseUrl) else { if !quiet { modelHint = "地址格式不对，先改好 Base URL" }; return }
        let k = effectiveKey
        guard !k.isEmpty else { if !quiet { modelHint = "先填写 API Key" }; return }
        loadSeq += 1
        let seq = loadSeq
        if !quiet { modelHint = "获取中…" }
        do {
            let list = try await AIClient.listModels(s, key: k)
            guard seq == loadSeq else { return }
            modelHint = ""
            guard !list.isEmpty else { return }
            models = list.contains(s.model) || s.model.isEmpty ? list : [s.model] + list
            if s.model.isEmpty { s.model = list[0] }
            manual = false
        } catch {
            guard seq == loadSeq else { return }
            // 安静模式（打开时自动拉取）失败不提示，可以手动输入
            modelHint = quiet ? "" : "获取失败：\(error.localizedDescription)"
        }
    }

    func runTest() async {
        guard AIClient.urlOK(s.baseUrl) else { testOK = false; test = "地址格式不对"; return }
        let settings = s, enteredKey = key
        let requestKey = effectiveKey
        testing = true; test = "测试中…"
        defer { testing = false }
        do {
            let r = try await AIClient.test(settings, key: requestKey)
            guard s == settings, key == enteredKey else { return }
            testOK = true; test = "已连通 · \(r)"
        } catch {
            guard s == settings, key == enteredKey else { return }
            testOK = false; test = error.localizedDescription
        }
    }

    func save() {
        guard AIClient.urlOK(s.baseUrl) else { urlHint = "地址需要以 http:// 或 https:// 开头"; return }
        do {
            try state.saveAISettings(s, key: key.isEmpty ? nil : key)
            state.flash("AI 设置已保存")
            dismiss()
        } catch {
            testOK = false; test = "保存失败：\(error.localizedDescription)"
        }
    }

    private func clearSavedKey() {
        do {
            try state.saveAISettings(state.aiSettings, key: "")
            key = ""
            testOK = true
            test = "已清除保存的 API Key"
            loadSeq += 1
        } catch {
            testOK = false
            test = "清除失败：\(error.localizedDescription)"
        }
    }
}

/// 底部一条细线的输入框
struct LineField<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        HStack(spacing: 6) { content }
            .textFieldStyle(.plain).font(.system(size: 12.5))
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.25)).frame(height: 1) }
    }
}
