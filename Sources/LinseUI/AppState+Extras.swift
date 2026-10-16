import LinseCore
import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

// 蒙版、LUT、XMP、AI 设置、日夜间模式
extension AppState {
    // MARK: 蒙版

    func addMask(_ type: MaskType) {
        guard params.masks.count < Params.maxMasks else { return flash("最多 \(Params.maxMasks) 个蒙版") }
        if type.isSmart && smartMasks.maskBitmap(type) == nil {
            // 先识别，识别到了再加蒙版
            return detect(type) { [weak self] in self?.addMask(type) }
        }
        let n = params.masks.filter { $0.type == type }.count + 1
        let m = Mask(type: type, index: n)
        params.masks.append(m)
        selectedMask = m.id
        showMaskOverlay = true
    }

    /// 在后台识别人物/主体/天空；完成后在主线程回调
    func detect(_ type: MaskType, then done: (() -> Void)? = nil) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        guard let ci = source?.ci else { return flash("先导入照片") }
        busy = "正在识别\(type.label)…"
        let ctx = Box(display.ciContext), store = smartMasks
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SmartMask.compute(type, image: ci, context: ctx.v) }
            await MainActor.run {
                guard let self else { return }
                self.busy = nil
                self.scheduleHistogram()
                switch result {
                case .success(let b):
                    // 识别期间换了图，结果作废
                    guard self.source?.ci === ci else { return }
                    store.set(type, b)
                    self.redrawTick &+= 1
                    done?()
                case .failure(let e):
                    self.flash(e.localizedDescription)
                }
            }
        }
    }

    /// 换图后，已有的识别类蒙版按新图重新识别
    func refreshSmartMasks() {
        let kinds = Set(params.masks.map(\.type).filter { $0.isSmart && smartMasks.maskBitmap($0) == nil })
        guard let k = kinds.first else { return }
        detect(k) { [weak self] in self?.refreshSmartMasks() }
    }

    func deleteMask(_ id: String) {
        params.masks.removeAll { $0.id == id }
        if selectedMask == id { selectedMask = nil }
    }

    var selectedMaskIndex: Int? { selectedMask.flatMap { id in params.masks.firstIndex { $0.id == id } } }

    // MARK: LUT

    func importLUTs(_ urls: [URL]) {
        guard busy == nil else { return flash("正在处理，请稍候") }
        var last: CubeLut?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { last = try luts.importFile(url) } catch { flash("\(url.lastPathComponent) 无法使用：\(error.localizedDescription)") }
        }
        lutList = luts.list
        if let l = last {
            params.lut = LutRef(id: l.id, name: l.name, intensity: 100)
            flash("已导入并套用「\(l.name)」")
        }
    }

    func selectLUT(_ id: String?) {
        guard let id, let l = luts.lut(id: id) else { params.lut = nil; return }
        params.lut = LutRef(id: l.id, name: l.name, intensity: params.lut?.intensity ?? 100)
    }

    func deleteLUT(_ id: String) {
        guard !presetLoadFailed else { return flash("预设读取失败，暂时无法确认 LUT 依赖，请修复后再删除") }
        let dependents = userPresets.filter { $0.params.lut?.id == id }
        guard dependents.isEmpty else {
            return flash("LUT 正被预设「\(dependents.prefix(3).map(\.name).joined(separator: "、"))」使用，请先删除相关预设")
        }
        do { try luts.delete(id) }
        catch { return flash("删除 LUT 失败：\(error.localizedDescription)") }
        lutList = luts.list
        forgetLUT(id)
    }

    // MARK: AI 设置（设置存在数据目录，Key 存钥匙串）

    var aiSettingsURL: URL { Self.dataDir.appendingPathComponent("ai-settings.json") }

    func loadAISettings() {
        if let d = try? Data(contentsOf: aiSettingsURL), let s = try? JSONDecoder().decode(AISettings.self, from: d) { aiSettings = s }
        aiHasKey = !AIKeychain.load().isEmpty
    }

    /// key 为 nil 表示不修改已保存的 Key
    func saveAISettings(_ s: AISettings, key: String?) throws {
        var s = s
        s.baseUrl = s.baseUrl.trimmingCharacters(in: .whitespaces)
        s.model = s.model.trimmingCharacters(in: .whitespaces)
        if s.model.isEmpty { s.model = AISettings().model }
        if s.proto != .anthropic { s.fast = false }
        let data = try JSONEncoder().encode(s)
        try data.write(to: aiSettingsURL, options: .atomic)
        if let key {
            guard AIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AIError("Key 没能存进钥匙串") }
        }
        aiSettings = s
        aiHasKey = !AIKeychain.load().isEmpty
    }

    // MARK: 日夜间模式

    func applyTheme() {
        UserDefaults.standard.set(theme.rawValue, forKey: "theme")
        #if os(macOS)
        NSApp?.appearance = theme == .auto ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        #endif
        redrawTick &+= 1
    }

    var colorScheme: ColorScheme? { theme == .auto ? nil : theme == .dark ? .dark : .light }

    func cycleTheme() {
        let all = ThemeMode.allCases
        theme = all[(all.firstIndex(of: theme)! + 1) % all.count]
        flash(theme.label)
    }
}
