import AppKit
import LinseCore
import SwiftUI

@main
struct LinseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("临色") {
            ContentView(state: state)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
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
                Button("导出 JPEG…") { state.export(.jpeg) }.keyboardShortcut("e")
                Button("导出 PNG…") { state.export(.png) }
                Button("导出 16 位 TIFF…") { state.export(.tiff16) }
                Button("导出 LUT（.cube）…") { state.exportLUT() }
                Button("导出 Lightroom 预设（.xmp）…") { state.exportXMP() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // swift run 启动时没有 bundle，手动设成普通应用以获得菜单栏和焦点
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(state: state).frame(width: 272)
            Divider()
            StageView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PanelView(state: state).frame(width: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                Picker("", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(width: 180).disabled(state.source == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.cycleTheme() } label: { Image(systemName: state.theme.icon) }.help("外观：\(state.theme.label)")
                Button { state.showAISettings = true } label: { Image(systemName: "gearshape") }.help("AI 设置")
                Button { state.reset() } label: { Image(systemName: "arrow.counterclockwise") }.help("全部复位").disabled(state.source == nil)
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.label) { state.export(f) } }
                    Divider()
                    Button("3D LUT（.cube）") { state.exportLUT() }
                    Button("Lightroom 预设（.xmp）") { state.exportXMP() }
                } label: { Text("导出") }
                .disabled(state.source == nil)
                Button { state.runMatch(useAI: true) } label: { Label("AI 辅助匹配", systemImage: "sparkles").labelStyle(.titleAndIcon) }
                    .help("先让视觉模型看图给出初值和判断，再用计算精确对齐")
                    .disabled(state.source == nil || state.target == nil || state.busy != nil)
                Button { state.runMatch() } label: { Text("计算匹配").padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).tint(.primary)
                    .help("纯计算：统计两张图的颜色并反推滑块，离线可用")
                    .disabled(state.source == nil || state.target == nil || state.busy != nil)
            }
        }
        .sheet(isPresented: $state.showAISettings) { AISettingsView(state: state) }
        .onAppear { state.applyTheme() }
        .background(KeyPeek(state: state))
        .task { state.devAutoload() }
    }
}

/// 按住空格看原图
struct KeyPeek: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> NSView {
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 49, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
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

/// 标志：左边一个细线圆（你的照片），右边一个渐变实心圆（目标的色彩），叠在一起
struct LogoMark: View {
    var body: some View {
        GeometryReader { g in
            let d = g.size.height * 17 / 32, off = g.size.width * 3.5 / 32
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.95, green: 0.71, blue: 0.42), Color(red: 0.89, green: 0.44, blue: 0.54), Color(red: 0.49, green: 0.55, blue: 0.94)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: d, height: d).offset(x: off)
                Circle().stroke(Color.primary, lineWidth: 1.2).frame(width: d, height: d).offset(x: -off)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}
