#if os(macOS)
import SwiftUI

/// 与工作区一致的中性色工具栏；悬停和按下反馈不依赖强调色。
struct MacToolbarButtonStyle: ButtonStyle {
    var iconOnly = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, iconOnly ? 8 : 10)
            .frame(height: 30)
            .modifier(ControlFeedback(isPressed: configuration.isPressed))
    }
}
#endif
