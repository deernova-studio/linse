import LinseUI
import SwiftUI

@main
struct LinseApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup { IOSRootView(state: state) }
    }
}
