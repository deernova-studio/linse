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
            CommandMenu("调整") {
                Button("计算匹配") { state.runMatch() }.keyboardShortcut(.return)
                Button("全部复位") { state.reset() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Picker("查看", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("导出 JPEG…") { state.export(.jpeg) }.keyboardShortcut("e")
                Button("导出 PNG…") { state.export(.png) }
                Button("导出 16 位 TIFF…") { state.export(.tiff16) }
                Button("导出 LUT（.cube）…") { state.exportLUT() }
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
                    LogoMark().frame(width: 16, height: 16)
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
                Button { state.reset() } label: { Image(systemName: "arrow.counterclockwise") }.help("全部复位").disabled(state.source == nil)
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.label) { state.export(f) } }
                    Divider()
                    Button("LUT（.cube）") { state.exportLUT() }
                } label: { Text("导出") }
                .disabled(state.source == nil)
                Button { state.runMatch() } label: { Text("计算匹配").padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).tint(.primary)
                    .disabled(state.source == nil || state.target == nil || state.busy != nil)
            }
        }
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

/// 标志：两个错开的圆，一空一实，表示“一张图的色彩落到另一张上”
struct LogoMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary, lineWidth: 1.2).offset(x: -2.5)
            Circle().fill(Color.primary.opacity(0.85)).padding(3).offset(x: 2.5)
        }
    }
}
