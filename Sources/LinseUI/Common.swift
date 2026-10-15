// Mac 和 iOS 共用的小组件与平台差异
import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
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

/// 标志：左边一个细线圆（你的照片），右边一个渐变实心圆（目标的色彩），叠在一起
struct LogoMark: View {
    var body: some View {
        GeometryReader { g in
            let d = g.size.height * 17 / 32, off = g.size.width * 3.5 / 32
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.95, green: 0.71, blue: 0.42), Color(red: 0.89, green: 0.44, blue: 0.54), Color(red: 0.49, green: 0.55, blue: 0.94)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: d, height: d).offset(x: off)
                Circle().stroke(Color.primary, lineWidth: 1.2).frame(width: d, height: d).offset(x: -off)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}
