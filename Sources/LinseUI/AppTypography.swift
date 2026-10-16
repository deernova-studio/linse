import SwiftUI

/// 系统中文与西文字体共用一套层级；语义字号同时保留 iOS 的动态字体支持。
enum AppTypography {
    static let guideTitle = Font.title3.weight(.semibold)
    static let sectionTitle = Font.callout.weight(.semibold)
    static let groupTitle = Font.subheadline.weight(.medium)
    static let tab = Font.callout.weight(.medium)
    static let metadata = Font.subheadline
    static let shortcut = Font.callout.weight(.medium)
}
