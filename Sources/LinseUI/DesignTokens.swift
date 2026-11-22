import SwiftUI

// Compatibility names for existing editor content. Native toolbars keep system sizes.
enum AppMetrics {
    static let space = Deernova.space1
    static let inset = Deernova.space4
    static let cardRadius = Deernova.cardRadius
    static let controlHeight = Deernova.hitMin
    static let rowHeight = Deernova.rowHeight
}

struct PaperDivider: View {
    var body: some View {
        Rectangle().fill(Color.line).frame(height: Deernova.strokeLine).accessibilityHidden(true)
    }
}
