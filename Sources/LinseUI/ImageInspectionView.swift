import LinseCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct ImageInspectionView: View {
    @ObservedObject var state: AppState
    let kind: AppState.SlotKind
    @Environment(\.dismiss) private var dismiss
    @State private var replacementError: String?
    @State private var choosingReplacement = false
    #if os(iOS)
    @State private var replacementItem: PhotosPickerItem?
    @State private var importing = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(kind.title)预览").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Label("关闭预览", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeutralButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 6)
            Divider()
            if let slot = state.slot(for: kind) {
                GeometryReader { geometry in
                    let wide = geometry.size.width >= 700
                    let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        ImageInspectionPreview(slot: slot, service: state.imagePreviews)
                            .id(slot.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().frame(width: wide ? 1 : nil, height: wide ? nil : 1)
                        ImageDetailsView(slot: slot)
                            .frame(width: wide ? 260 : nil, height: wide ? nil : min(250, geometry.size.height * 0.45))
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                if let busy = state.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                if let replacementError {
                    Text(replacementError).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                #if os(macOS)
                Button("切换图片", systemImage: "arrow.triangle.2.circlepath") {
                    replacementError = nil
                    choosingReplacement = true
                }
                .buttonStyle(.bordered).controlSize(.large).tint(.primary)
                .disabled(state.busy != nil)
                .help(state.busy == nil ? "重新选择\(kind.title)" : "正在处理，请稍候")
                #else
                if importing && state.busy == nil { ProgressView().controlSize(.small) }
                Menu {
                    PhotosPicker(selection: $replacementItem, matching: .images, preferredItemEncoding: .current) {
                        Label("从相册选择", systemImage: "photo")
                    }
                    Button("从文件选择（含 RAW）", systemImage: "folder") {
                        replacementError = nil
                        choosingReplacement = true
                    }
                } label: {
                    Label(importing ? "正在读取图片…" : "切换图片", systemImage: "arrow.triangle.2.circlepath").frame(minHeight: 32)
                }
                .buttonStyle(.bordered).tint(.primary).disabled(state.busy != nil || importing)
                #endif
                Button("确认") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.large).tint(.primary)
            }
            .padding(20)
        }
        .background(Color.appBackground)
        #if os(macOS)
        .frame(width: 900, height: 600)
        #else
        .presentationDetents([.large])
        .task(id: replacementItem) { await replacePhoto() }
        #endif
        .fileImporter(isPresented: $choosingReplacement, allowedContentTypes: [.image, .rawImage], onCompletion: replaceImage)
    }

    private func replaceImage(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                if !(await state.load(url, into: kind)) {
                    replacementError = state.toast ?? "无法打开这张图片，请重新选择。"
                }
            }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            replacementError = error.localizedDescription
        }
    }
    #if os(iOS)
    private func replacePhoto() async {
        guard let item = replacementItem else { return }
        importing = true
        replacementError = nil
        defer { importing = false; replacementItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                replacementError = "读不到这张照片，请重新选择。"
                return
            }
            try Task.checkCancellation()
            let hint = item.supportedContentTypes.first(where: { $0.conforms(to: .rawImage) })?.identifier
            if !(await state.load(data: data, name: kind.title, into: kind, typeIdentifierHint: hint)) {
                replacementError = state.toast ?? "无法打开这张图片，请重新选择。"
            }
        } catch {
            if !Task.isCancelled { replacementError = error.localizedDescription }
        }
    }
    #endif
}
