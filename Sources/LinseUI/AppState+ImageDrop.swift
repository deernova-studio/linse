import SwiftUI

extension AppState {
    /// 同时拖入两张图时按原图、目标图顺序载入，避免异步解码彼此抢占 busy 状态。
    func importDroppedImages(_ providers: [NSItemProvider], into kinds: [SlotKind]) -> Bool {
        guard !providers.isEmpty, busy == nil else { return false }
        Task {
            for (provider, kind) in zip(providers, kinds) {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                guard let url else {
                    reportImageImportError("无法读取拖入的文件，请通过导入按钮重新选择。")
                    continue
                }
                await load(url, into: kind)
            }
        }
        return true
    }
}
