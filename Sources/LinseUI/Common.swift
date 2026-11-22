// Mac 和 iOS 共用的小组件与平台差异
import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static var appBackground: Color { .canvas }
}

extension Image {
    init(cg: CGImage) { self.init(decorative: cg, scale: 1) }
}

enum HoverCursor { case crosshair, resizeLeftRight }

extension View {
    /// 鼠标悬停时换光标（iOS 上没有光标，什么都不做）
    @ViewBuilder func hoverCursor(_ c: HoverCursor) -> some View {
        #if os(macOS)
        onHover { $0 ? (c == .crosshair ? NSCursor.crosshair : NSCursor.resizeLeftRight).push() : NSCursor.pop() }
        #else
        self
        #endif
    }
}

/// 保留临色的双圆形标志，使用单色墨色，不把装饰色带入工作区。
struct LogoMark: View {
    var body: some View {
        GeometryReader { g in
            let d = g.size.height * 17 / 32, off = g.size.width * 3.5 / 32
            ZStack {
                Circle().fill(Color.ink).frame(width: d, height: d).offset(x: off)
                Circle().stroke(Color.ink, lineWidth: 1).frame(width: d, height: d).offset(x: -off)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}
