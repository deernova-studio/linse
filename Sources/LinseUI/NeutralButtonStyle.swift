import SwiftUI

struct NeutralButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 4
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ControlFeedback(isPressed: configuration.isPressed, cornerRadius: cornerRadius, outlined: outlined))
    }
}
