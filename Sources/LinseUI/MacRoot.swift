#if os(macOS)
// Mac 版外壳：三栏布局、工具栏、菜单命令、文件对话框、按住空格看原图
import AppKit
import LinseCore
import SwiftUI
import UniformTypeIdentifiers

public struct LinseCommands: Commands {
    @ObservedObject var state: AppState
    public init(state: AppState) { self.state = state }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("导入照片…") { state.open(.source) }.keyboardShortcut("o")
            Button("导入目标风格…") { state.open(.target) }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { state.undoAction() }.keyboardShortcut("z")
            Button("重做") { state.redoAction() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("AI 设置…") { state.showAISettings = true }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .help) {
            Button("隐私说明") { state.showPrivacyPolicy = true }
        }
        CommandMenu("调整") {
            Button("计算匹配") { state.runMatch() }.keyboardShortcut(.return)
            Button("AI 辅助匹配") { state.runMatch(useAI: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("全部复位") { state.reset() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Picker("查看", selection: $state.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            Picker("外观", selection: $state.theme) {
                ForEach(ThemeMode.allCases, id: \.self) { Text($0.label) }
            }
            Divider()
            Button("导入 LUT…") { state.importLUT() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("导出 JPEG…") { state.saveImage(.jpeg) }.keyboardShortcut("e")
            Button("导出 PNG…") { state.saveImage(.png) }
            Button("导出 16 位 TIFF…") { state.saveImage(.tiff16) }
            Button("导出 LUT（.cube）…") { state.saveLUT() }
            Button("导出 Lightroom 预设（.xmp）…") { state.saveXMP() }
        }
    }
}

public struct MacRootView: View {
    @ObservedObject var state: AppState
    public init(state: AppState) { self.state = state }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(state: state).frame(width: 272)
            Divider()
            StageView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.source != nil {
                Divider()
                PanelView(state: state).frame(width: 320)
            }
        }
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                Text(t).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                    .padding(.bottom, 24).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.toast)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    LogoMark().frame(width: 18, height: 18)
                    Text("临色").font(.system(size: 13, weight: .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("查看方式", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 180).disabled(state.source == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("切换外观", systemImage: state.theme.icon) { state.cycleTheme() }
                    .labelStyle(.iconOnly).buttonStyle(MacToolbarButtonStyle(iconOnly: true))
                    .help("外观：\(state.theme.label)")
                Button("AI 设置", systemImage: "gearshape") { state.showAISettings = true }
                    .labelStyle(.iconOnly).buttonStyle(MacToolbarButtonStyle(iconOnly: true))
                    .help("AI 设置")
                Button("全部复位", systemImage: "arrow.counterclockwise") { state.reset() }
                    .labelStyle(.iconOnly).buttonStyle(MacToolbarButtonStyle(iconOnly: true))
                    .help(state.source == nil ? "先导入原图" : "全部复位")
                    .disabled(state.source == nil || state.busy != nil)
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.label) { state.saveImage(f) } }
                    Divider()
                    Button("3D LUT（.cube）") { state.saveLUT() }
                    Button("Lightroom 预设（.xmp）") { state.saveXMP() }
                } label: {
                    HStack(spacing: 4) {
                        Text("导出")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                    }
                }
                .menuStyle(.button).buttonStyle(MacToolbarButtonStyle())
                .menuIndicator(.hidden).fixedSize()
                .help(state.source == nil ? "先导入原图" : state.busy != nil ? "正在处理，请稍候" : "导出照片、LUT 或预设")
                .disabled(state.source == nil || state.busy != nil)
                Button { state.runMatch(useAI: true) } label: { Label("AI 辅助匹配", systemImage: "sparkles").labelStyle(.titleAndIcon) }
                    .buttonStyle(MacToolbarButtonStyle())
                    .help(matchUnavailableReason ?? "先让视觉模型看图给出初值和判断，再用计算精确对齐")
                    .disabled(state.source == nil || state.target == nil || state.busy != nil)
                Button("计算匹配") { state.runMatch() }
                    .buttonStyle(MacToolbarButtonStyle())
                    .help(matchUnavailableReason ?? "纯计算：统计两张图的颜色并反推滑块，离线可用")
                    .disabled(state.source == nil || state.target == nil || state.busy != nil)
            }
        }
        .sheet(isPresented: $state.showAISettings) { AISettingsView(state: state) }
        .sheet(item: $state.aiPhotoConsent) { AIPhotoConsentView(state: state, request: $0) }
        .sheet(isPresented: $state.showPrivacyPolicy) { PrivacyPolicyView() }
        .sheet(item: $state.inspectedSlot) { ImageInspectionView(state: state, kind: $0) }
        .modifier(ImageImportAlert(state: state))
        .onAppear { state.applyTheme() }
        .background(KeyPeek(state: state))
        .task { await state.devAutoload(); state.devSnapshot() }
    }

    private var matchUnavailableReason: String? {
        if state.busy != nil { return "正在处理，请稍候" }
        if state.source == nil { return state.target == nil ? "先导入原图和目标风格图" : "先导入原图" }
        if state.target == nil { return "先导入目标风格图" }
        return nil
    }
}

/// 按住空格看原图
struct KeyPeek: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> NSView {
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 49, NSApp.keyWindow?.attachedSheet == nil, NSApp.keyWindow?.sheetParent == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
            let down = e.type == .keyDown
            Task { @MainActor in if state.peekOriginal != down { state.peekOriginal = down } }
            return nil
        }
        return NSView()
    }
    func updateNSView(_ v: NSView, context: Context) {}
    func makeCoordinator() -> C { C() }
    final class C { var monitor: Any?; deinit { if let monitor { NSEvent.removeMonitor(monitor) } } }
}

extension AppState {
    func open(_ kind: SlotKind) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url, into: kind) }
    }

    func importLUT() {
        guard busy == nil else { return flash("正在处理，请稍候") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importLUTs(panel.urls)
    }

    func savePanel(_ name: String, _ type: UTType?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let type { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func saveImage(_ format: ExportFormat) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard source != nil else { return flash("先导入照片") }
        guard let url = savePanel(exportBaseName + "." + format.ext, format == .jpeg ? .jpeg : format == .png ? .png : .tiff) else { return }
        export(format, to: url) { [weak self] img in
            self?.flash("已导出 \(img.width)×\(img.height) \(format.label)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func saveLUT() {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard source != nil else { return flash("先导入照片") }
        guard let url = savePanel(exportBaseName + ".cube", UTType(filenameExtension: "cube")) else { return }
        Task {
            do {
                let text = try await lutText(title: url.deletingPathExtension().lastPathComponent)
                try text.write(to: url, atomically: true, encoding: .utf8)
                flash("已导出 LUT")
            } catch { flash("导出失败：\(error.localizedDescription)") }
        }
    }

    func saveXMP() {
        guard source != nil else { return flash("先导入照片") }
        guard let url = savePanel(exportBaseName + ".xmp", UTType(filenameExtension: "xmp")) else { return }
        do {
            try xmpText(name: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
            flash(params.masks.isEmpty ? "已导出 Lightroom 预设" : "已导出 Lightroom 预设（蒙版不包含在内）")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { flash("导出失败：\(error.localizedDescription)") }
    }

    /// 开发自测：LINSE_SNAPSHOT 等处理结束后截自己的窗口，LINSE_QUIT=1 截完退出。
    func devSnapshot() {
        // 启动时不要让第一个数值框抢焦点
        Task {
            await Task.yield()
            NSApp.windows.forEach { $0.makeFirstResponder(nil) }
        }
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LINSE_SNAPSHOT"] else { return }
        Task {
            defer { if env["LINSE_QUIT"] == "1" { NSApp.terminate(nil) } }
            await waitIdle()
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return flash("开发截图失败：没有可见窗口") }
            do {
                let url = URL(fileURLWithPath: out)
                try await WindowSnapshot.save(window, to: url)
                if let sheet = window.attachedSheet {
                    let sheetURL = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-sheet.png")
                    try await WindowSnapshot.save(sheet, to: sheetURL)
                }
            } catch {
                flash("开发截图失败：\(error.localizedDescription)")
            }
        }
    }
}
#endif
