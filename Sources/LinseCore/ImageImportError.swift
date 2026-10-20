import Foundation

public enum ImageImportError: LocalizedError, Equatable {
    case unreadableFile
    case invalidImage
    case rawDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "无法读取文件。请确认文件已下载到本机，并且允许临色访问。"
        case .invalidImage:
            "文件不是可读取的图片，或内容已损坏。请选择完整的图片文件。"
        case .rawDecodingFailed:
            "无法解码这份 RAW。当前系统可能不支持该机型或压缩方式，也可能是文件不完整。请尝试更新系统，或用相机软件转存为 DNG / 16 位 TIFF 后导入。"
        }
    }
}
