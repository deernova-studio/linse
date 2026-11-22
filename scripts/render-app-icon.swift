import AppKit
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error {
    case invalidSource
    case renderingFailed
    case iconutilFailed
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Assets")
guard let artwork = NSImage(contentsOf: assets.appendingPathComponent("LinseIcon.svg")),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw IconError.invalidSource
}

func render(size: Int, forMac: Bool, to url: URL) throws {
    let alpha = forMac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    guard let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: colorSpace, bitmapInfo: alpha.rawValue) else {
        throw IconError.renderingFailed
    }
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = forMac ? CGFloat(size) * 0.08 : 0
    let tile = full.insetBy(dx: inset, dy: inset)
    if forMac {
        let radius = tile.width * 0.22
        canvas.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
        canvas.clip()
    }
    canvas.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    artwork.draw(in: tile)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = canvas.makeImage(),
          let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError.renderingFailed
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw IconError.renderingFailed }
}

let fm = FileManager.default
let temp = fm.temporaryDirectory.appendingPathComponent("LinseIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: temp, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: temp) }

let mac = root.appendingPathComponent("macOS/Linse/Assets.xcassets/AppIcon.appiconset")
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let catalogURL = mac.appendingPathComponent("icon-\(points)@\(scale)x.png")
        try render(size: points * scale, forMac: true, to: catalogURL)
        let suffix = scale == 2 ? "@2x" : ""
        try fm.copyItem(at: catalogURL, to: temp.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", temp.path, "-o", assets.appendingPathComponent("icon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw IconError.iconutilFailed }

let ios = root.appendingPathComponent("iOS/Linse/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try render(size: 1024, forMac: false, to: ios)
