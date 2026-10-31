import SwiftUI

struct WorkspaceAlert: ViewModifier {
    @ObservedObject var state: AppState
    func body(content: Content) -> some View {
        content.alert("编辑现场", isPresented: Binding(
            get: { state.workspaceError != nil },
            set: { if !$0 { state.workspaceError = nil } }
        )) {
            if state.workspaceRecoveryBlocked {
                Button("备份原现场并继续") {
                    Task { await state.archiveFailedWorkspaceAndContinue() }
                }
            }
            Button("好", role: .cancel) { state.workspaceError = nil }
        } message: {
            Text(state.workspaceError ?? "")
        }
    }
}
