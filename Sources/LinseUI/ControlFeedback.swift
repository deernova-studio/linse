import SwiftUI

/// 自定义控件共用的中性反馈；不改变内容布局，也不覆盖原生输入控件的交互。
struct ControlFeedback: ViewModifier {
    var isPressed = false
    var cornerRadius: CGFloat = 4
    var outlined = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        let active = isEnabled && (hovered || isPressed)
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(Color.primary.opacity(isEnabled ? (isPressed ? 0.12 : hovered ? 0.06 : 0) : 0), in: shape)
            .overlay {
                if outlined {
                    shape.strokeBorder(Color.primary.opacity(active ? 0.4 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}
