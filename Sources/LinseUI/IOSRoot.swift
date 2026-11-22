#if os(iOS)
// iOS 版外壳：上面是画布，下面是调整 / 预设 / 改动；从相册选图，导出到相册或分享。
// iPad 横屏等宽屏时用和 Mac 一样的三栏。
import LinseCore
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct IOSRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: AppState
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var pick: PhotosPickerItem?
    @State private var photoSlot: AppState.SlotKind?
    @State private var fileSlot: AppState.SlotKind?
    @State private var choosingPhoto = false
    @State private var choosingImageFile = false
    @State private var tab = 0
    @State private var share: TemporaryExportFile?

    public init(state: AppState) { self.state = state }

    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1000 && !textSize.isAccessibilitySize {
                HStack(spacing: 0) {
                    SidebarView(state: state).frame(width: 300)
                    Divider()
                    VStack(spacing: 0) { actions.padding(12); Divider(); stage }
                    if state.source != nil {
                        Divider()
                        PanelView(state: state).frame(width: 340)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    stage.frame(height: state.source == nil ? max(160, geometry.size.height * 0.65) : max(120, geometry.size.height * 0.32))
                    Divider()
                    slots.padding(.horizontal, 14).padding(.vertical, 10)
                    if state.source != nil {
                        Divider()
                        bottom.frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .background(Color.canvas)
        .tint(Color.brandAccent)
        .foregroundStyle(Color.ink)
        .overlay(alignment: .top) {
            if let t = state.toast {
                Text(t).font(AppTypography.ui(13)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.surfaceRaised, in: Capsule()).padding(.top, 60).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.toast)
        .preferredColorScheme(state.colorScheme)
        .confirmationDialog("导入图片", isPresented: Binding(get: { state.importChoice != nil }, set: { if !$0 { state.importChoice = nil } }),
                            titleVisibility: .visible, presenting: state.importChoice) { kind in
            Button("从相册选择") { photoSlot = kind; choosingPhoto = true }
            Button("从文件选择（含 RAW）") { fileSlot = kind; choosingImageFile = true }
            Button("取消", role: .cancel) { }
        }
        .photosPicker(isPresented: $choosingPhoto,
                      selection: $pick, matching: .images, preferredItemEncoding: .current)
        .task(id: pick) { await importSelectedPhoto() }
        .fileImporter(isPresented: $choosingImageFile, allowedContentTypes: [.image, .rawImage]) { result in
            guard let kind = fileSlot else { return }
            fileSlot = nil
            switch result {
            case .success(let url): Task { await state.load(url, into: kind) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { state.reportImageImportError(error.localizedDescription) }
            }
        }
        .fileImporter(isPresented: $state.showLUTImporter, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { state.importLUTs(urls) }
        }
        .sheet(isPresented: $state.showAISettings) { NavigationStack { ScrollView { AISettingsView(state: state).frame(maxWidth: .infinity) } } }
        .sheet(item: $state.aiPhotoConsent) { AIPhotoConsentView(state: state, request: $0) }
        .sheet(item: $state.inspectedSlot) { ImageInspectionView(state: state, kind: $0) }
        .modifier(ImageImportAlert(state: state))
        .modifier(WorkspaceAlert(state: state))
        .sheet(item: $share) { ShareSheet(file: $0).ignoresSafeArea() }
        .task { await state.restoreWorkspace(); await state.devAutoload() }
    }

    var topBar: some View {
        HStack(spacing: 10) {
            LogoMark().frame(width: 20, height: 20)
            Text("临色").font(AppTypography.ui(16, weight: .medium))
            Spacer()
            if textSize.isAccessibilitySize {
                Picker("查看方式", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.menu).disabled(state.source == nil)
            } else {
                Picker("查看方式", selection: $state.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 200).disabled(state.source == nil)
            }
            Menu {
                Section("导出") {
                    Button { saveToPhotos() } label: { Label("存到相册", systemImage: "photo.on.rectangle") }
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Button { shareImage(f) } label: { Label("分享 \(f.label)", systemImage: "square.and.arrow.up") }
                    }
                    Button { shareLUT() } label: { Label("分享 3D LUT", systemImage: "cube") }
                    Button { shareText(state.exportBaseName + ".xmp") { state.xmpText(name: state.exportBaseName) } } label: { Label("分享 Lightroom 预设", systemImage: "slider.horizontal.3") }
                }
                .disabled(state.source == nil || state.busy != nil)
                Section {
                    Button { state.showAISettings = true } label: { Label("AI 设置", systemImage: "gearshape") }
                    Picker(selection: $state.theme) {
                        ForEach(ThemeMode.allCases, id: \.self) { Text($0.label) }
                    } label: { Label("外观", systemImage: state.theme.icon) }
                    Button { state.undoAction() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    Button { state.redoAction() } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                    Button(role: .destructive) { state.reset() } label: { Label("全部复位", systemImage: "arrow.counterclockwise") }
                        .disabled(state.source == nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 画布：按住看原图
    var stage: some View {
        StageView(state: state)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { v in if case .second(true, _) = v, state.selectedMaskIndex == nil { state.peekOriginal = true } }
                .onEnded { _ in state.peekOriginal = false })
    }

    var slots: some View {
        ViewThatFits(in: .horizontal) {
            slotRow
            VStack(spacing: 8) { slotPair; actions }
        }
    }

    var slotPair: some View {
        HStack(spacing: 12) {
            MiniSlot(title: "原图", slot: state.source) { state.inspectOrImport(.source) }
            Image(systemName: "arrow.left").font(AppTypography.ui(11, weight: .light)).foregroundStyle(Color.inkSecondary)
            MiniSlot(title: "目标图", slot: state.target) { state.inspectOrImport(.target) }
        }
    }

    var slotRow: some View {
        HStack(spacing: 12) { slotPair; Spacer(minLength: 4); actions }
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button { state.runMatch(useAI: true) } label: {
                Label("AI 辅助匹配", systemImage: "sparkles").labelStyle(.iconOnly).frame(minWidth: 24, minHeight: 32)
            }
                .buttonStyle(.bordered)
                .disabled(state.source == nil || state.target == nil || state.busy != nil)
            Button { state.runMatch() } label: { Text("匹配").font(AppTypography.ui(14, weight: .medium)).padding(.horizontal, 6).frame(minHeight: 32) }
                .buttonStyle(.bordered)
                .disabled(state.source == nil || state.target == nil || state.busy != nil)
        }
        .tint(Color.brandAccent)
    }

    var bottom: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                TabText("调整", on: tab == 0) { tab = 0 }
                TabText("预设", on: tab == 1) { tab = 1 }
                TabText("改动", on: tab == 2) { tab = 2 }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            switch tab {
            case 0: PanelView(state: state)
            case 1: ScrollView { PresetsView(state: state, columns: 3).padding(14) }
            default: ScrollView { ChangesList(state: state).padding(14) }
            }
        }
    }

    private func importSelectedPhoto() async {
        guard let item = pick, let kind = photoSlot else { return }
        defer { if pick == item { pick = nil; photoSlot = nil } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ImageImportError.unreadableFile }
            try Task.checkCancellation()
            let hint = item.supportedContentTypes.first(where: { $0.conforms(to: .rawImage) })?.identifier
            await state.load(data: data, name: kind.title, into: kind, typeIdentifierHint: hint)
        } catch {
            if !Task.isCancelled { state.reportImageImportError("读不到这张照片。请确认已从 iCloud 下载，或尝试从文件导入原始图片。") }
        }
    }

    // MARK: 导出

    func shareImage(_ f: ExportFormat) {
        do {
            let file = try TemporaryExportFile(name: state.exportBaseName + "." + f.ext)
            state.export(f, to: file.url) { _ in share = file }
        } catch { state.flash("导出失败：\(error.localizedDescription)") }
    }

    func shareText(_ name: String, _ make: () throws -> String) {
        do {
            let file = try TemporaryExportFile(name: name)
            try make().write(to: file.url, atomically: true, encoding: .utf8)
            share = file
        } catch { state.flash("导出失败：\(error.localizedDescription)") }
    }

    func shareLUT() {
        let name = state.exportBaseName
        Task {
            do {
                let text = try await state.lutText(title: name)
                let file = try TemporaryExportFile(name: name + ".cube")
                try text.write(to: file.url, atomically: true, encoding: .utf8)
                share = file
            } catch { state.flash("导出失败：\(error.localizedDescription)") }
        }
    }

    func saveToPhotos() {
        do {
            let file = try TemporaryExportFile(name: state.exportBaseName + ".jpg")
            state.export(.jpeg, to: file.url) { img in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        Task { @MainActor in state.flash("没有相册权限，可以在设置里打开") }
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: file.url)
                    }) { [file] ok, err in
                        Task { @MainActor in state.flash(ok ? "已存到相册 · \(img.width)×\(img.height)" : "保存失败：\(err?.localizedDescription ?? "")") }
                        withExtendedLifetime(file) {}
                    }
                }
            }
        } catch { state.flash("导出失败：\(error.localizedDescription)") }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let file: TemporaryExportFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        // SwiftUI 关闭 sheet 后，系统分享流程仍可能持有控制器；随它一起保留文件。
        controller.completionWithItemsHandler = { [file] _, _, _, _ in withExtendedLifetime(file) {} }
        return controller
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// 手机上的小图槽：空槽导入，已有图片时先预览。
struct MiniSlot: View {
    let title: String
    let slot: Slot?
    let action: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                ZStack {
                    Rectangle().fill(Color.surfaceSunken)
                    if let t = slot?.thumb { Image(cg: t).resizable().scaledToFill() }
                    else { Image(systemName: "plus").font(AppTypography.ui(13, weight: .light)).foregroundStyle(Color.inkSecondary) }
                }
                .frame(width: 52, height: 52).clipped()
                .overlay(Rectangle().stroke(Color.lineControl, style: StrokeStyle(lineWidth: 1, dash: slot == nil ? [3, 3] : [])))
            }
            .buttonStyle(SurfaceButtonStyle())
            .accessibilityLabel(slot == nil ? "导入\(title)" : "查看\(title)")
            Text(title).font(AppTypography.ui(10)).foregroundStyle(Color.inkSecondary)
                .accessibilityHidden(true)
        }
    }
}

extension AppState {
    func open(_ kind: SlotKind) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        importChoice = kind
    }
    func importLUT() { showLUTImporter = true }
}
#endif
