import AppKit
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
    let thumb: NSImage
}

enum ViewMode: String, CaseIterable { case result = "结果", split = "对比", original = "原图" }

struct Summary {
    var source: String
    var secs: Double
    var match: MatchSummary?
    var stale = false
}

@MainActor
final class AppState: ObservableObject {
    let display: Renderer
    let proxy: Renderer
    var exporter: Renderer?

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
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var histogram: [[Float]] = []
    @Published var toast: String?
    @Published var redrawTick = 0
    @Published var selectedMask: String?

    private var suppressEdit = false
    private var histTask: Task<Void, Never>?
    private var undo: [Params] = [Params()]
    private var undoIdx = 0
    private var undoTimer: Task<Void, Never>?

    init() {
        do {
            display = try Renderer()
            proxy = try Renderer(device: display.device)
        } catch {
            fatalError("Metal 不可用：\(error.localizedDescription)")
        }
        loadPresets()
    }

    var effectiveView: ViewMode { peekOriginal ? .original : viewMode }

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

    func open(_ kind: SlotKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, into: kind)
    }

    enum SlotKind { case source, target }

    func load(_ url: URL, into kind: SlotKind) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        // Core Image 负责解码：JPEG、PNG、HEIC、TIFF、相机 RAW 都走这里，并按 EXIF 方向摆正
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return flash("打不开这张图：\(url.lastPathComponent)")
        }
        let ext = ci.extent
        let thumbCI = ci.transformed(by: CGAffineTransform(scaleX: 400 / max(ext.width, ext.height), y: 400 / max(ext.width, ext.height)))
        let thumb: NSImage = {
            guard let cg = display.ciContext.createCGImage(thumbCI, from: thumbCI.extent) else { return NSImage() }
            return NSImage(cgImage: cg, size: .zero)
        }()
        let slot = Slot(name: url.lastPathComponent, ci: ci, size: ext.size, thumb: thumb)
        switch kind {
        case .source:
            do {
                try display.setImage(ci: ci)
                try proxy.setImage(ci: ci, maxSide: 320)
            } catch { return flash(error.localizedDescription) }
            source = slot
            thumbnails = [:]
            redrawTick &+= 1
            scheduleHistogram()
        case .target:
            target = slot
        }
        if summary != nil, summary?.source.hasPrefix("预设") == false { summary?.stale = true }
    }

    // MARK: 匹配

    func runMatch() {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard let source, let target else { return flash(source == nil ? "缺少照片" : "缺少目标风格图") }
        busy = "分析目标照片…"
        let proxy = Box(self.proxy)
        let t0 = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = proxy.v
                try r.setImage(ci: target.ci, maxSide: 320)
                let tw = Int(r.imageSize.width), th = Int(r.imageSize.height)
                let tpx = try r.renderRGBA8(Params(), width: tw, height: th, opts: RenderOptions(bypass: true))
                let tStats = Stats.compute(tpx, weights: Stats.detailWeights(tpx, width: tw))
                try r.setImage(ci: source.ci, maxSide: 320)
                let (p, sm) = try Estimator.match(r, target: tStats, options: MatchOptions(onProgress: { stage in
                    Task { @MainActor in self?.busy = "正在对齐：\(stage)" }
                }))
                await MainActor.run {
                    guard let self else { return }
                    var np = p
                    np.masks = self.params.masks
                    self.setParams(np)
                    self.matched = np
                    self.strength = 100
                    self.summary = Summary(source: "计算匹配", secs: Date().timeIntervalSince(t0), match: sm)
                    self.busy = nil
                    self.flash(String(format: "匹配完成 · %.1f 秒", Date().timeIntervalSince(t0)))
                }
            } catch {
                await MainActor.run { self?.busy = nil; self?.flash("匹配失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: 直方图 / 预设缩略图（都用小图渲染，同一条管线）

    private func scheduleHistogram() {
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

    func thumbnail(for p: Preset) -> NSImage? {
        let key = p.id + (p.createdAt.map { "\($0.timeIntervalSince1970)" } ?? "")
        if let t = thumbnails[key] { return t }
        guard source != nil, busy == nil else { return nil }
        let w = Int(proxy.imageSize.width), h = Int(proxy.imageSize.height)
        guard let px = try? proxy.renderRGBA8(p.params, width: w, height: h), let cg = Exporter.cgImage(rgba: px, width: w, height: h) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        DispatchQueue.main.async { self.thumbnails[key] = img }
        return img
    }

    // MARK: 预设

    var presetsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

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

    func export(_ format: ExportFormat) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard let source else { return flash("先导入照片") }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (source.name as NSString).deletingPathExtension + "_临色." + format.ext
        panel.allowedContentTypes = [format == .jpeg ? .jpeg : format == .png ? .png : .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "正在渲染全尺寸…"
        let params = self.params, ci = source.ci
        let ex = Box(exporter ?? (try? Renderer(device: display.device)))
        exporter = ex.v
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let r = ex.v else { throw RenderError.noDevice }
                try r.setImage(ci: ci)
                defer { r.releaseImage() }
                let img = try Exporter.render(r, params, format: format) { i, n in
                    Task { @MainActor in self?.busy = "正在渲染全尺寸… \(i)/\(n)" }
                }
                try Exporter.write(img, to: url, format: format)
                await MainActor.run {
                    self?.busy = nil
                    self?.flash("已导出 \(img.width)×\(img.height) \(format.label)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run { self?.busy = nil; self?.flash("导出失败：\(error.localizedDescription)") }
            }
        }
    }

    func exportLUT() {
        guard source != nil else { return flash("先导入照片") }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ((source?.name ?? "临色") as NSString).deletingPathExtension + "_临色.cube"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let r = try exporter ?? Renderer(device: display.device)
            exporter = r
            let text = try Cube.bake(r, params, title: url.deletingPathExtension().lastPathComponent)
            try text.write(to: url, atomically: true, encoding: .utf8)
            flash("已导出 LUT")
        } catch { flash("导出失败：\(error.localizedDescription)") }
    }

    /// 开发自测：LINSE_SOURCE / LINSE_TARGET 指定启动时载入的图，LINSE_MATCH=1 顺便跑一次匹配，LINSE_VIEW 设查看模式
    func devAutoload() {
        // 启动时不要让第一个数值框抢焦点
        DispatchQueue.main.async { NSApp.windows.forEach { $0.makeFirstResponder(nil) } }
        let env = ProcessInfo.processInfo.environment
        if let s = env["LINSE_SOURCE"] { load(URL(fileURLWithPath: s), into: .source) }
        if let t = env["LINSE_TARGET"] { load(URL(fileURLWithPath: t), into: .target) }
        if env["LINSE_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["LINSE_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let v = env["LINSE_VIEW"], let m = ViewMode(rawValue: v) { viewMode = m }
        if env["LINSE_MATCH"] == "1" { runMatch() }
        if let out = env["LINSE_SNAPSHOT"] {
            // 等匹配结束后截自己的窗口（自己的窗口不需要屏幕录制权限），然后退出
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                while busy != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let w = NSApp.windows.first(where: { $0.isVisible }),
                      let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                if env["LINSE_QUIT"] == "1" { NSApp.terminate(nil) }
            }
        }
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

typealias Cube = CubeLut
