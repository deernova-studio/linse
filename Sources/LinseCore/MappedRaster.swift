import CoreGraphics
import Darwin
import Foundation

/// 大图像素由临时文件支撑，避免同时保留多个完整 Swift 数组；CGImage 持有映射直到编码结束。
final class MappedRaster {
    let width: Int, height: Int, bytesPerPixel: Int, byteCount: Int
    let pointer: UnsafeMutableRawPointer

    init(width: Int, height: Int, bytesPerPixel: Int) throws {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (count, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard width > 0, height > 0, bytesPerPixel > 0, !pixelOverflow, !byteOverflow, count > 0 else {
            throw RenderError.texture("无效的导出尺寸")
        }
        self.width = width; self.height = height; self.bytesPerPixel = bytesPerPixel; byteCount = count
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linse-raster-\(UUID().uuidString)")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.systemError() }
        defer { close(descriptor); unlink(url.path) }
        // 先确保磁盘空间可用；避免稀疏映射写到一半才因磁盘已满触发 SIGBUS。
        var allocation = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(count), fst_bytesalloc: 0)
        guard fcntl(descriptor, F_PREALLOCATE, &allocation) != -1, ftruncate(descriptor, off_t(count)) == 0 else {
            throw Self.systemError()
        }
        guard let address = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), address != MAP_FAILED else {
            throw Self.systemError()
        }
        pointer = address
    }

    deinit { munmap(pointer, byteCount) }

    func pixel(_ x: Int, _ y: Int) -> UnsafeMutableRawPointer { pointer + (y * width + x) * bytesPerPixel }

    func image(bitsPerComponent: Int) throws -> CGImage {
        let retained = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pointer, size: byteCount, releaseData: { info, _, _ in
            if let info { Unmanaged<MappedRaster>.fromOpaque(info).release() }
        }) else { retained.release(); throw RenderError.texture("导出像素缓冲") }
        let byteOrder = bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        guard let image = CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bytesPerPixel * 8, bytesPerRow: width * bytesPerPixel, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | byteOrder), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RenderError.texture("导出图像") }
        return image
    }

    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
