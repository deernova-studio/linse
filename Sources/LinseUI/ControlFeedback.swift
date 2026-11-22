import SwiftUI

/// A single fill for hover, press or selection; native focus indication is retained.
struct ControlFeedback: ViewModifier {
    var isPressed = false
    var isSelected = false
    var cornerRadius: CGFloat = Deernova.buttonRadius
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(isEnabled ? (isPressed || isSelected ? Color.fillSelected : hovered ? Color.fillHover : .clear) : .clear, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Deernova.opacityDisabled)
            .animation(reduceMotion ? nil : .easeOut(duration: Deernova.durationInstant), value: hovered)
            .onHover { hovered = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}
