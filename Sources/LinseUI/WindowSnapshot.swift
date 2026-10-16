#if os(macOS)
import AppKit
import ScreenCaptureKit

/// 仅供显式启用 LINSE_SNAPSHOT 的开发自测使用；系统管理屏幕捕获权限。
@MainActor
enum WindowSnapshot {
    static func save(_ window: NSWindow, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let selected = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw Failure.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: selected)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        config.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure.encoding
        }
        try data.write(to: url, options: .atomic)
    }

    private enum Failure: LocalizedError {
        case windowUnavailable, encoding
        var errorDescription: String? {
            switch self {
            case .windowUnavailable: return "找不到可截取的应用窗口"
            case .encoding: return "无法编码窗口截图"
            }
        }
    }
}
#endif
