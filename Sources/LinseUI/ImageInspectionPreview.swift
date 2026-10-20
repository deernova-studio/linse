import LinseCore
import SwiftUI

struct ImageInspectionPreview: View {
    let slot: Slot
    let service: ImagePreviewService
    @State private var preview: CGImage?
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.03))
            .overlay {
                if let image = preview ?? slot.thumb {
                    Image(image, scale: 1, label: Text("图片完整预览"))
                        .resizable().scaledToFit().padding(24)
                }
            }
            .overlay(alignment: .bottom) {
                if loading {
                    ProgressView("正在加载预览…").controlSize(.small)
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(16)
                } else if let failure {
                    Text(failure).font(.callout).multilineTextAlignment(.center)
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(16)
                }
            }
            .clipped()
            .task { await loadPreview() }
    }

    private func loadPreview() async {
        do {
            let image = try await service.preview(slot.ci)
            try Task.checkCancellation()
            preview = image
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            loading = false
        }
    }
}
