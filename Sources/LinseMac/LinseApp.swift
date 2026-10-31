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
                .onAppear { delegate.state = state }
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { LinseCommands(state: state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task {
            let saved = await state.saveWorkspaceNow()
            if saved { sender.reply(toApplicationShouldTerminate: true); return }
            let alert = NSAlert()
            alert.messageText = "编辑现场未能保存"
            alert.informativeText = "继续退出可能丢失本次编辑。你可以取消退出后重试。"
            alert.addButton(withTitle: "取消退出")
            alert.addButton(withTitle: "仍然退出")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // swift run 启动时没有 bundle，手动设成普通应用以获得菜单栏和焦点
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
