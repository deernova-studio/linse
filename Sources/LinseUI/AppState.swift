import CoreImage
import LinseCore
import SwiftUI
import UniformTypeIdentifiers

/// 渲染器不是线程安全的，只在一个后台任务里用；用这个包装把它交给后台任务
final class Box<T>: @unchecked Sendable { let v: T; init(_ v: T) { self.v = v } }

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

struct Summary {
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
    let smartMasks = SmartMaskStore()

    private var suppressEdit = false
    private var histTask: Task<Void, Never>?
    private var undo: [Params] = [Params()]
    private var undoIdx = 0
    private var undoTimer: Task<Void, Never>?

    public convenience init() {
        self.init(luts: LutStore(dir: Self.dataDir.appendingPathComponent("luts", isDirectory: true)),
                  theme: ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .auto)
        loadPresets()
        loadAISettings()
    }

    /// 注入资源库，方便测试编辑流程而不读取用户设置或钥匙串。
    init(luts: LutStore, theme: ThemeMode = .auto) {
        do {
            display = try Renderer()
            proxy = try Renderer(device: display.device)
            exports = ExportService(device: display.device)
        } catch {
            fatalError("Metal 不可用：\(error.localizedDescription)")
        }
        self.luts = luts
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
            if matched != nil { matched = nil }
            scheduleUndoCommit()
        }
    }

    /// 程序内部整体替换参数（匹配、预设、撤销），不算手动编辑
    func setParams(_ p: Params, commit: Bool = true) {
        suppressEdit = true
        params = p
        suppressEdit = false
        if commit { commitUndo() }
    }

    func setStrength(_ v: Double) {
        strength = v
        guard let m = matched else { return }
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
        undo.removeSubrange((undoIdx + 1)...)
        if undo.last != params { undo.append(params) }
        if undo.count > 100 { undo.removeFirst() }
        undoIdx = undo.count - 1
    }

    func undoAction() {
        if undoTimer != nil { commitUndo(); undoTimer = nil }
        guard undoIdx > 0 else { return flash("没有可以撤销的操作") }
        undoIdx -= 1
        suppressEdit = true; params = undo[undoIdx]; suppressEdit = false
        flash("已撤销")
    }

    func redoAction() {
        guard undoIdx < undo.count - 1 else { return flash("没有可以重做的操作") }
        undoIdx += 1
        suppressEdit = true; params = undo[undoIdx]; suppressEdit = false
        flash("已重做")
    }

    func reset() {
        matched = nil; summary = nil
        setParams(Params())
        flash("已复位")
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
                try display.setImage(ci: ci)
                try proxy.setImage(ci: ci, maxSide: 320)
            } catch { return flash(error.localizedDescription) }
            source = slot
            thumbnails = [:]
            smartMasks.reset()
            refreshSmartMasks()
            redrawTick &+= 1
            scheduleHistogram()
        case .target:
            target = slot
        }
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
        let ai = aiSettings, key = useAI ? (ProcessInfo.processInfo.environment["LINSE_AI_KEY"] ?? AIKeychain.load()) : ""
        busy = useAI ? "AI（\(ai.model)\(ai.effort == .auto ? "" : " · 思考强度 \(ai.effort.rawValue)")\(ai.fast ? " · 快速" : "")）正在看图…" : "分析目标照片…"
        let proxy = Box(self.proxy), ctx = Box(display.ciContext)
        let t0 = Date()
        aiTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = proxy.v
                func measure(_ ci: CIImage) throws -> ImageStats {
                    try r.setImage(ci: ci, maxSide: 320)
                    let w = Int(r.imageSize.width), h = Int(r.imageSize.height)
                    let px = try r.renderRGBA8(Params(), width: w, height: h, opts: RenderOptions(bypass: true))
                    return Stats.compute(px, weights: Stats.detailWeights(px, width: w))
                }
                var found: AIAnalysis?
                if useAI {
                    // 把和估计器同一套的实测统计一起发给模型，让它以测量为准、以看图判断内容
                    let stats = ["source": AIAnalysis.statsJSON(try measure(source.ci)), "target": AIAnalysis.statsJSON(try measure(target.ci))]
                    let imgs = AIImages(source: try Self.jpegBase64(source.ci, ctx.v), target: try Self.jpegBase64(target.ci, ctx.v),
                                        stats: try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]))
                    found = try await AIClient.analyze(ai, key: key, images: imgs)
                    try Task.checkCancellation()
                    await MainActor.run { self?.busy = "分析目标照片…" }
                }
                let tStats = try measure(target.ci)
                try r.setImage(ci: source.ci, maxSide: 320)
                let analysis = found
                let label = analysis != nil ? "按 AI 初值精确对齐" : "正在对齐"
                let (p, sm) = try Estimator.match(r, target: tStats, options: MatchOptions(prior: analysis?.prior, portraitHint: analysis?.isPortrait, onProgress: { stage in
                    Task { @MainActor in self?.busy = "\(label)：\(stage)" }
                }))
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    var np = p
                    np.masks = self.params.masks
                    self.setParams(np)
                    self.matched = np
                    self.strength = 100
                    let secs = Date().timeIntervalSince(t0)
                    self.summary = Summary(source: analysis != nil ? "AI 辅助匹配" : "计算匹配", secs: secs, match: sm,
                                           ai: analysis, aiCorrections: analysis?.corrections(final: np) ?? [])
                    self.busy = nil
                    self.aiTask = nil
                    self.flash(String(format: "匹配完成 · %.1f 秒", secs))
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = nil
                    self.aiTask = nil
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { return self.flash("已取消") }
                    self.flash("\(useAI ? "AI 分析" : "匹配")失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 处理中的 AI 请求可以取消；计算阶段很快，不提供取消
    var canCancel: Bool { aiTask != nil && (busy?.hasPrefix("AI") ?? false) }
    func cancelBusy() { aiTask?.cancel() }

    nonisolated static func jpegBase64(_ ci: CIImage, _ ctx: CIContext, max side: CGFloat = 1024) throws -> String {
        let e = ci.extent
        let s = min(1, side / Swift.max(e.width, e.height))
        let img = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let d = ctx.jpegRepresentation(of: img, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
        else { throw AIError("图片编码失败") }
        return d.base64EncodedString()
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

    var presetsURL: URL { Self.dataDir.appendingPathComponent("presets.json") }

    func loadPresets() {
        guard let data = try? Data(contentsOf: presetsURL), let list = try? JSONDecoder().decode([Preset].self, from: data) else { return }
        userPresets = list
    }

    func savePresets() {
        guard let data = try? JSONEncoder().encode(userPresets) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }

    func applyPreset(_ p: Preset) {
        guard busy == nil else { return }
        guard source != nil else { return flash("先导入一张照片") }
        var np = p.params
        np.masks = params.masks
        setParams(np)
        matched = np
        strength = 100
        summary = Summary(source: "预设 · \(p.name)", secs: 0)
        flash("已套用「\(p.name)」")
    }

    func saveCurrentAsPreset(name: String) {
        var p = params
        p.masks = []
        userPresets.insert(Preset(id: UUID().uuidString, name: name.isEmpty ? "我的预设 \(userPresets.count + 1)" : name, params: p, createdAt: Date()), at: 0)
        savePresets()
        flash("已存为预设")
    }

    func deletePreset(_ p: Preset) {
        userPresets.removeAll { $0.id == p.id }
        savePresets()
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
