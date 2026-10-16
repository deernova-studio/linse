import CoreImage
import LinseCore
import SwiftUI
import UniformTypeIdentifiers

struct Slot {
    let name: String
    let ci: CIImage
    let size: CGSize
    let thumb: CGImage?
}

enum ViewMode: String, CaseIterable { case result = "结果", split = "对比", original = "原图" }

enum ExportRequestError: LocalizedError {
    case busy, missingSource
    var errorDescription: String? {
        switch self {
        case .busy: return "正在处理，请稍候"
        case .missingSource: return "先导入照片"
        }
    }
}

struct Summary: Equatable {
    var source: String
    var secs: Double
    var match: MatchSummary?
    var stale = false
    var ai: AIAnalysis?
    var aiCorrections: [String] = []
}

enum ThemeMode: String, CaseIterable {
    case auto, light, dark
    var label: String { ["auto": "跟随系统", "light": "日间模式", "dark": "夜间模式"][rawValue]! }
    var icon: String { ["auto": "circle.lefthalf.filled", "light": "sun.max", "dark": "moon"][rawValue]! }
}

@MainActor
public final class AppState: ObservableObject {
    let display: Renderer
    let proxy: Renderer
    private let exports: ExportService
    private var exportID: UUID?
    private let matches: MatchService
    private let aiKeyProvider: () -> String
    private var matchID: UUID?
    let maskService: SmartMaskService
    var maskTask: Task<Void, Never>?
    var maskRequestID: UUID?

    @Published var params = Params() { didSet { paramsDidChange() } }
    @Published var matched: Params?
    @Published var strength = 100.0
    @Published var summary: Summary?
    @Published var source: Slot?
    @Published var target: Slot?
    @Published var viewMode: ViewMode = .result
    @Published var split: CGFloat = 0.5
    @Published var peekOriginal = false
    @Published var busy: String?
    @Published var userPresets: [Preset] = []
    @Published var thumbnails: [String: CGImage] = [:]
    @Published var histogram: [[Float]] = []
    @Published var toast: String?
    @Published var redrawTick = 0
    @Published var selectedMask: String?
    @Published var showMaskOverlay = true
    @Published var lutList: [CubeLut] = []
    @Published var aiSettings = AISettings()
    @Published var aiHasKey = false
    @Published var showAISettings = false
    @Published var pickRequest: SlotKind?      // iOS：请求打开相册选图
    @Published var showLUTImporter = false     // iOS：请求打开"文件"选 .cube
    @Published var theme: ThemeMode = .auto { didSet { applyTheme() } }
    var aiTask: Task<Void, Never>?
    let luts: LutStore
    private let presetStore: PresetStore
    private(set) var presetLoadFailed = false
    let smartMasks = SmartMaskStore()

    private var suppressEdit = false
    private var histTask: Task<Void, Never>?
    private var history = EditHistory()
    private var undoTimer: Task<Void, Never>?

    public convenience init() {
        self.init(luts: LutStore(dir: Self.dataDir.appendingPathComponent("luts", isDirectory: true)),
                  theme: ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .auto,
                  presetStore: PresetStore(url: Self.dataDir.appendingPathComponent("presets.json")))
        loadPresets()
        loadAISettings()
    }

    /// 注入资源库，方便测试编辑流程而不读取用户设置或钥匙串。
    init(luts: LutStore, theme: ThemeMode = .auto, presetStore: PresetStore? = nil, matchService: MatchService? = nil,
         maskService: SmartMaskService? = nil,
         aiKeyProvider: @escaping () -> String = { ProcessInfo.processInfo.environment["LINSE_AI_KEY"] ?? AIKeychain.load() }) {
        do {
            display = try Renderer()
            proxy = try Renderer(device: display.device)
            exports = ExportService(device: display.device)
            matches = matchService ?? MatchService(device: display.device)
            self.maskService = maskService ?? SmartMaskService(device: display.device)
        } catch {
            fatalError("Metal 不可用：\(error.localizedDescription)")
        }
        self.luts = luts
        self.presetStore = presetStore ?? PresetStore(url: luts.dir.appendingPathComponent("presets.json"))
        self.aiKeyProvider = aiKeyProvider
        display.luts = luts
        proxy.luts = luts
        display.maskBitmaps = smartMasks
        proxy.maskBitmaps = smartMasks
        lutList = luts.list
        self.theme = theme
    }

    var effectiveView: ViewMode { peekOriginal ? .original : viewMode }

    /// 画布四周留白（点）；手机屏幕小，留得少一些
    var canvasInset: CGFloat {
        #if os(macOS)
        24
        #else
        8
        #endif
    }

    // MARK: 参数变化

    private func paramsDidChange() {
        redrawTick &+= 1
        scheduleHistogram()
        if !suppressEdit {
            // 手动改了参数：强度条不再代表当前状态
            if matched != nil { matched = nil; strength = 100 }
            scheduleUndoCommit()
        }
    }

    private var editSnapshot: EditorSnapshot {
        EditorSnapshot(params: params, matched: matched, strength: strength, summary: summary)
    }

    private func restoreEdit(_ snapshot: EditorSnapshot) {
        suppressEdit = true
        params = snapshot.params
        matched = snapshot.matched
        strength = snapshot.strength
        summary = snapshot.summary
        suppressEdit = false
        if let id = selectedMask, !params.masks.contains(where: { $0.id == id }) { selectedMask = nil }
    }

    private func applyEdit(_ snapshot: EditorSnapshot) {
        commitUndo()
        restoreEdit(snapshot)
        commitUndo()
    }

    func setStrength(_ v: Double) {
        guard let m = matched else { return }
        strength = v
        var p = Estimator.scaled(m, v / 100)
        p.masks = params.masks
        suppressEdit = true; params = p; suppressEdit = false
        scheduleUndoCommit()
    }

    // MARK: 撤销

    private func scheduleUndoCommit() {
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.commitUndo()
        }
    }

    func commitUndo() {
        undoTimer?.cancel()
        undoTimer = nil
        history.record(editSnapshot)
    }

    func undoAction() {
        commitUndo()
        guard let snapshot = history.undo() else { return flash("没有可以撤销的操作") }
        restoreEdit(snapshot)
        flash("已撤销")
    }

    func redoAction() {
        commitUndo()
        guard let snapshot = history.redo() else { return flash("没有可以重做的操作") }
        restoreEdit(snapshot)
        flash("已重做")
    }

    func reset() {
        applyEdit(EditorSnapshot())
        flash("已复位")
    }

    /// LUT 删除是资源操作，不允许历史记录重新引入已不存在的资源。
    func forgetLUT(_ id: String) {
        commitUndo()
        history.removeLUT(id)
        restoreEdit(editSnapshot.removingLUT(id))
        thumbnails.removeAll()
    }

    // MARK: 载入

    enum SlotKind { case source, target }

    func load(_ url: URL, into kind: SlotKind) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        // 从"文件"App 或拖进来的文件可能需要临时访问授权
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Core Image 负责解码：JPEG、PNG、HEIC、TIFF、相机 RAW 都走这里，并按 EXIF 方向摆正
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return flash("打不开这张图：\(url.lastPathComponent)")
        }
        load(ci, name: url.lastPathComponent, into: kind)
    }

    /// 相册里选的图是一段数据
    func load(data: Data, name: String, into kind: SlotKind) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return flash("打不开这张图") }
        load(ci, name: name, into: kind)
    }

    func load(_ ci: CIImage, name: String, into kind: SlotKind) {
        // 原点挪到 (0,0)，后面的缩放和识别都按这个算
        let ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let ext = ci.extent
        let thumbCI = ci.transformed(by: CGAffineTransform(scaleX: 400 / max(ext.width, ext.height), y: 400 / max(ext.width, ext.height)))
        let thumb = display.ciContext.createCGImage(thumbCI, from: thumbCI.extent)
        let slot = Slot(name: name, ci: ci, size: ext.size, thumb: thumb)
        switch kind {
        case .source:
            do {
                try display.setImage(ci: ci, maxSide: display.maxTextureSize)
                try proxy.setImage(ci: ci, maxSide: 320)
            } catch { return flash(error.localizedDescription) }
            invalidateMaskDetection()
            source = slot
            thumbnails = [:]
            smartMasks.reset()
            refreshSmartMasks()
            redrawTick &+= 1
            scheduleHistogram()
        case .target:
            target = slot
        }
        history.invalidateMatchSummaries()
        if summary != nil, summary?.source.hasPrefix("预设") == false { summary?.stale = true }
    }

    // MARK: 匹配

    /// useAI：先让视觉模型看图给出初值和判断，再用计算精确对齐
    func runMatch(useAI: Bool = false) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard let source, let target else { return flash(source == nil ? "缺少照片" : "缺少目标风格图") }
        if useAI && !aiHasKey {
            showAISettings = true
            return flash("先填写 API Key")
        }
        let ai = aiSettings, key = useAI ? aiKeyProvider() : ""
        let id = UUID()
        matchID = id
        busy = useAI ? "AI（\(ai.model)\(ai.effort == .auto ? "" : " · 思考强度 \(ai.effort.rawValue)")\(ai.fast ? " · 快速" : "")）正在看图…" : "分析目标照片…"
        let matches = self.matches
        aiTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await matches.match(source: source.ci, target: target.ci, ai: useAI ? ai : nil, key: key) { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.matchID == id else { return }
                        self.busy = message
                    }
                }
                try Task.checkCancellation()
                guard let self, self.matchID == id else { return }
                var params = result.params
                params.masks = self.params.masks
                self.applyEdit(EditorSnapshot(params: params, matched: params, summary:
                    Summary(source: result.analysis == nil ? "计算匹配" : "AI 辅助匹配", secs: result.seconds, match: result.summary,
                            ai: result.analysis, aiCorrections: result.analysis?.corrections(final: params) ?? [])))
                self.finishMatch(id)
                self.flash(String(format: "匹配完成 · %.1f 秒", result.seconds))
            } catch {
                guard let self, self.matchID == id else { return }
                self.finishMatch(id)
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return self.flash("已取消") }
                self.flash("\(useAI ? "AI 分析" : "匹配")失败：\(error.localizedDescription)")
            }
        }
    }

    /// 处理中的 AI 请求可以取消；计算阶段很快，不提供取消
    var canCancel: Bool { aiTask != nil && (busy?.hasPrefix("AI") ?? false) }
    func cancelBusy() { aiTask?.cancel() }

    private func finishMatch(_ id: UUID) {
        guard matchID == id else { return }
        matchID = nil
        aiTask = nil
        busy = nil
        scheduleHistogram()
    }

    // MARK: 直方图 / 预设缩略图（都用小图渲染，同一条管线）

    func scheduleHistogram() {
        histTask?.cancel()
        guard source != nil else { histogram = []; return }
        histTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled, self.busy == nil else { return }
            let w = Int(self.proxy.imageSize.width), h = Int(self.proxy.imageSize.height)
            guard let px = try? self.proxy.renderRGBA8(self.params, width: w, height: h) else { return }
            var bins = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 3)
            for i in stride(from: 0, to: px.count, by: 4) { for c in 0..<3 { bins[c][Int(px[i + c])] += 1 } }
            self.histogram = bins
        }
    }

    func thumbnail(for p: Preset) -> CGImage? {
        if let ref = p.params.lut, luts.lut(id: ref.id) == nil { return nil }
        let key = p.id + (p.createdAt.map { "\($0.timeIntervalSince1970)" } ?? "")
        if let t = thumbnails[key] { return t }
        guard source != nil, busy == nil else { return nil }
        let w = Int(proxy.imageSize.width), h = Int(proxy.imageSize.height)
        guard let px = try? proxy.renderRGBA8(p.params, width: w, height: h), let cg = Exporter.cgImage(rgba: px, width: w, height: h) else { return nil }
        DispatchQueue.main.async { self.thumbnails[key] = cg }
        return cg
    }

    // MARK: 预设

    static var dataDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadPresets() {
        do {
            userPresets = try presetStore.load()
            presetLoadFailed = false
        } catch {
            presetLoadFailed = true
            flash("读取预设失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func savePresets(_ next: [Preset]) -> Bool {
        guard !presetLoadFailed else { flash("预设读取失败，修复预设文件并重新载入后才能保存"); return false }
        do {
            try presetStore.save(next)
            userPresets = next
            return true
        } catch {
            flash("保存预设失败：\(error.localizedDescription)")
            return false
        }
    }

    func applyPreset(_ p: Preset) {
        guard busy == nil else { return }
        guard source != nil else { return flash("先导入一张照片") }
        if let ref = p.params.lut, luts.lut(id: ref.id) == nil {
            return flash("预设缺少 LUT「\(ref.name)」，请重新导入滤镜并保存预设")
        }
        var np = p.params
        np.masks = params.masks
        applyEdit(EditorSnapshot(params: np, matched: np, summary: Summary(source: "预设 · \(p.name)", secs: 0)))
        flash("已套用「\(p.name)」")
    }

    func saveCurrentAsPreset(name: String) {
        var p = params
        p.masks = []
        if let ref = p.lut, luts.lut(id: ref.id) == nil { return flash("保存预设失败：缺少 LUT「\(ref.name)」") }
        var next = userPresets
        next.insert(Preset(id: UUID().uuidString, name: name.isEmpty ? "我的预设 \(userPresets.count + 1)" : name, params: p, createdAt: Date()), at: 0)
        guard savePresets(next) else { return }
        flash("已存为预设")
    }

    func deletePreset(_ p: Preset) {
        savePresets(userPresets.filter { $0.id != p.id })
    }

    // MARK: 导出

    var exportBaseName: String { ((source?.name ?? "临色") as NSString).deletingPathExtension + "_临色" }

    /// 全尺寸渲染并写到 url；完成后在主线程回调
    @discardableResult
    func export(_ format: ExportFormat, to url: URL, done: @escaping (CGImage) -> Void) -> Task<Void, Never>? {
        guard busy == nil else { flash("正在处理，请稍候"); return nil }
        guard let source else { flash("先导入照片"); return nil }
        let id = UUID()
        exportID = id
        busy = "正在渲染全尺寸…"
        let params = self.params, assets = ExportAssets(params: params, luts: luts, maskBitmaps: smartMasks)
        let exports = self.exports
        return Task(priority: .userInitiated) { [weak self] in
            do {
                let img = try await exports.writeImage(source.ci, params: params, assets: assets, format: format, to: url) { [weak self] i, n in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportID == id else { return }
                        self.busy = "正在渲染全尺寸… \(i)/\(n)"
                    }
                }
                guard let self, self.exportID == id else { return }
                self.exportID = nil
                self.busy = nil
                done(img)
            } catch {
                guard let self, self.exportID == id else { return }
                self.exportID = nil
                self.busy = nil
                self.flash("导出失败：\(error.localizedDescription)")
            }
        }
    }

    func lutText(title: String) async throws -> String {
        guard busy == nil else { throw ExportRequestError.busy }
        guard source != nil else { throw ExportRequestError.missingSource }
        let id = UUID()
        exportID = id
        busy = "正在导出 LUT…"
        let params = self.params, assets = ExportAssets(params: params, luts: luts)
        defer {
            if exportID == id { exportID = nil; busy = nil }
        }
        return try await exports.lutText(params: params, assets: assets, title: title)
    }

    func xmpText(name: String) -> String { XMP.make(params, name: name) }

    /// 开发自测：LINSE_SOURCE / LINSE_TARGET 指定启动时载入的图，LINSE_MATCH=1 顺便跑一次匹配，LINSE_VIEW 设查看模式
    func devAutoload() {
        let env = ProcessInfo.processInfo.environment
        if let s = env["LINSE_SOURCE"] { load(URL(fileURLWithPath: s), into: .source) }
        if let t = env["LINSE_TARGET"] { load(URL(fileURLWithPath: t), into: .target) }
        if let t = env["LINSE_APPEARANCE"], let m = ThemeMode(rawValue: t) { theme = m }
        if let v = env["LINSE_VIEW"], let m = ViewMode(rawValue: v) { viewMode = m }
        if let k = env["LINSE_AI_KEY"], !k.isEmpty { aiHasKey = true }
        if let b = env["LINSE_AI_BASE"] { aiSettings.baseUrl = b }
        if let m = env["LINSE_AI_MODEL"] { aiSettings.model = m }
        if let l = env["LINSE_LUT"], let lut = try? luts.importFile(URL(fileURLWithPath: l)) {
            lutList = luts.list
            params.lut = LutRef(id: lut.id, name: lut.name, intensity: 100)
        }
        if let t = env["LINSE_MASK"], let mt = MaskType(rawValue: t) { addMask(mt) }
        if env["LINSE_AI_SETTINGS"] == "1" { showAISettings = true }
        if env["LINSE_MATCH"] == "1" { runMatch() }
        if env["LINSE_MATCH"] == "ai" { runMatch(useAI: true) }
    }

    /// 等处理结束（匹配、识别）再继续，开发自测截图用
    func waitIdle() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        while busy != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    // MARK: 提示

    func flash(_ s: String) {
        toast = s
        let cur = s
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self?.toast == cur { self?.toast = nil }
        }
    }
}
