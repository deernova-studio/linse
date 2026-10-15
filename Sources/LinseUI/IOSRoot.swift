#if os(iOS)
// iOS 版外壳：上面是画布，下面是调整 / 预设 / 改动；从相册选图，导出到相册或分享。
// iPad 横屏等宽屏时用和 Mac 一样的三栏。
import LinseCore
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct IOSRootView: View {
    @ObservedObject var state: AppState
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var pick: PhotosPickerItem?
    @State private var tab = 0
    @State private var share: ShareItem?

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Group {
            if hSize == .regular {
                HStack(spacing: 0) {
                    SidebarView(state: state).frame(width: 300)
                    Divider()
                    VStack(spacing: 0) { actions.padding(12); Divider(); stage }
                    Divider()
                    PanelView(state: state).frame(width: 340)
                }
            } else {
                VStack(spacing: 0) {
                    stage.frame(maxHeight: .infinity)
                    Divider()
                    slots.padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                    bottom.frame(height: 330)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            if let t = state.toast {
                Text(t).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 60).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.toast)
        .preferredColorScheme(state.colorScheme)
        .photosPicker(isPresented: Binding(get: { state.pickRequest != nil }, set: { if !$0 { state.pickRequest = nil } }),
                      selection: $pick, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pick) { item in
            guard let item, let kind = state.pickRequest ?? Optional(.source) else { return }
            state.pickRequest = nil
            pick = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    state.load(data: data, name: kind == .source ? "照片" : "目标风格", into: kind)
                } else {
                    state.flash("读不到这张照片")
                }
            }
        }
        .fileImporter(isPresented: $state.showLUTImporter, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { state.importLUTs(urls) }
        }
        .sheet(isPresented: $state.showAISettings) { NavigationStack { ScrollView { AISettingsView(state: state).frame(maxWidth: .infinity) } } }
        .sheet(item: $share) { ShareSheet(items: [$0.url]).ignoresSafeArea() }
        .task { state.devAutoload() }
    }

    var topBar: some View {
        HStack(spacing: 10) {
            LogoMark().frame(width: 20, height: 20)
            Text("临色").font(.system(size: 16, weight: .medium))
            Spacer()
            Picker("", selection: $state.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).frame(width: 156).disabled(state.source == nil)
            Menu {
                Section("导出") {
                    Button { saveToPhotos() } label: { Label("存到相册", systemImage: "photo.on.rectangle") }
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Button { shareImage(f) } label: { Label("分享 \(f.label)", systemImage: "square.and.arrow.up") }
                    }
                    Button { shareText(state.exportBaseName + ".cube") { try state.lutText(title: state.exportBaseName) } } label: { Label("分享 3D LUT", systemImage: "cube") }
                    Button { shareText(state.exportBaseName + ".xmp") { state.xmpText(name: state.exportBaseName) } } label: { Label("分享 Lightroom 预设", systemImage: "slider.horizontal.3") }
                }
                .disabled(state.source == nil)
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
                Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .light)).frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.appBackground)
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
        HStack(spacing: 12) {
            MiniSlot(title: "原图", slot: state.source) { state.open(.source) }
            Image(systemName: "arrow.left").font(.system(size: 11, weight: .light)).foregroundStyle(.secondary)
            MiniSlot(title: "目标风格", slot: state.target) { state.open(.target) }
            Spacer(minLength: 4)
            actions
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button { state.runMatch(useAI: true) } label: { Image(systemName: "sparkles").frame(width: 22, height: 22) }
                .buttonStyle(.bordered)
                .disabled(state.source == nil || state.target == nil || state.busy != nil)
            Button { state.runMatch() } label: { Text("匹配").font(.system(size: 14, weight: .medium)).padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).tint(.primary)
                .foregroundStyle(Color.appBackground)
                .disabled(state.source == nil || state.target == nil || state.busy != nil)
        }
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

    // MARK: 导出

    func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func shareImage(_ f: ExportFormat) {
        let url = tempURL(state.exportBaseName + "." + f.ext)
        state.export(f, to: url) { _ in share = ShareItem(url: url) }
    }

    func shareText(_ name: String, _ make: () throws -> String) {
        do {
            let url = tempURL(name)
            try make().write(to: url, atomically: true, encoding: .utf8)
            share = ShareItem(url: url)
        } catch { state.flash("导出失败：\(error.localizedDescription)") }
    }

    func saveToPhotos() {
        let url = tempURL(state.exportBaseName + ".jpg")
        state.export(.jpeg, to: url) { img in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    Task { @MainActor in state.flash("没有相册权限，可以在设置里打开") }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }) { ok, err in
                    Task { @MainActor in state.flash(ok ? "已存到相册 · \(img.width)×\(img.height)" : "保存失败：\(err?.localizedDescription ?? "")") }
                }
            }
        }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

/// 手机上的小图槽：点一下从相册选
struct MiniSlot: View {
    let title: String
    let slot: Slot?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    if let t = slot?.thumb { Image(cg: t).resizable().scaledToFill() }
                    else { Image(systemName: "plus").font(.system(size: 13, weight: .light)).foregroundStyle(.secondary) }
                }
                .frame(width: 52, height: 52).clipped()
                .overlay(Rectangle().stroke(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: slot == nil ? [3, 3] : [])))
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

extension AppState {
    func open(_ kind: SlotKind) { pickRequest = kind }
    func importLUT() { showLUTImporter = true }
}
#endif
