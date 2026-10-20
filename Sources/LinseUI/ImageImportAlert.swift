import SwiftUI

struct ImageImportAlert: ViewModifier {
    @ObservedObject var state: AppState

    func body(content: Content) -> some View {
        content.alert("无法导入图片", isPresented: Binding(
            get: { state.imageImportError != nil },
            set: { if !$0 { state.imageImportError = nil } }
        )) {
            Button("好", role: .cancel) { state.imageImportError = nil }
        } message: {
            Text(state.imageImportError ?? "")
        }
    }
}
