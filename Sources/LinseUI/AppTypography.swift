import SwiftUI

/// Desktop density and semantic iOS text sizes share the same roles.
enum AppTypography {
    static let guideTitle = Font.system(.title2, design: .serif).weight(.semibold)
    static let sectionTitle = ui(13, weight: .semibold)
    static let groupTitle = ui(11)
    static let tab = ui(13, weight: .medium)
    static let metadata = ui(11)
    static let shortcut = ui(11, weight: .medium)

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        return .system(size: size <= 11 ? 11 : max(13, size), weight: weight)
        #else
        let style: Font.TextStyle = size <= 11 ? .caption : size <= 13 ? .subheadline : size <= 17 ? .body : .title3
        return .system(style, weight: weight)
        #endif
    }
}
