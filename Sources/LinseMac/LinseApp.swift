import AppKit
import LinseUI
import SwiftUI

@main
struct LinseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("临色") {
            MacRootView(state: state)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { LinseCommands(state: state) }
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
