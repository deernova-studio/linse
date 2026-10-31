import LinseUI
import SwiftUI
import UIKit

@main
struct LinseApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            IOSRootView(state: state)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    Task { @MainActor in
                        let task = UIApplication.shared.beginBackgroundTask(withName: "保存编辑现场")
                        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
                        await state.saveWorkspaceNow()
                    }
                }
        }
    }
}
