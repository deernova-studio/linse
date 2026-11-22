import SwiftUI

/// Compact text actions on paper; the transparent hit area is outside the fill.
struct NeutralButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Deernova.buttonPaddingXSm)
            .frame(minHeight: Deernova.buttonHeightMd)
            .modifier(ControlFeedback(isPressed: configuration.isPressed, isSelected: selected))
            .frame(minWidth: Deernova.hitMin, minHeight: Deernova.hitMin)
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: Deernova.buttonHeightSm, height: Deernova.buttonHeightSm)
            .modifier(ControlFeedback(isPressed: configuration.isPressed, cornerRadius: Deernova.buttonRadiusSm))
            .frame(minWidth: Deernova.hitMin, minHeight: Deernova.hitMin)
            .contentShape(Rectangle())
    }
}

/// Cards and disclosure rows already own their geometry; never apply button padding.
struct SurfaceButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ControlFeedback(isPressed: configuration.isPressed, cornerRadius: cornerRadius))
    }
}

struct SheetHeader: View {
    let title: String
    let closeLabel: String
    var close: () -> Void
    var body: some View {
        HStack(spacing: Deernova.space3) {
            Text(title).font(.headline)
            Spacer()
            Button(closeLabel, systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: Deernova.buttonFontSizeSm))
                .buttonStyle(IconButtonStyle())
                .help(closeLabel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(minHeight: Deernova.toolbarHeight)
        .padding(.horizontal, Deernova.space4)
    }
}
