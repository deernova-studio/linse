import AppKit
import LinseCore
import UniformTypeIdentifiers

// 蒙版、LUT、XMP、AI 设置、日夜间模式
extension AppState {
    // MARK: 蒙版

    func addMask(_ type: MaskType) {
        guard params.masks.count < Params.maxMasks else { return flash("最多 \(Params.maxMasks) 个蒙版") }
        let n = params.masks.filter { $0.type == type }.count + 1
        let m = Mask(type: type, index: n)
        params.masks.append(m)
        selectedMask = m.id
        showMaskOverlay = true
    }

    func deleteMask(_ id: String) {
        params.masks.removeAll { $0.id == id }
        if selectedMask == id { selectedMask = nil }
    }

    var selectedMaskIndex: Int? { selectedMask.flatMap { id in params.masks.firstIndex { $0.id == id } } }

    // MARK: LUT

    func importLUT() {
        guard busy == nil else { return flash("正在处理，请稍候") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var last: CubeLut?
        for url in panel.urls {
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
        luts.delete(id)
        lutList = luts.list
        if params.lut?.id == id { params.lut = nil }
        if matched?.lut?.id == id { matched = nil }
    }

    // MARK: XMP

    func exportXMP() {
        guard source != nil else { return flash("先导入照片") }
        let base = ((source?.name ?? "临色") as NSString).deletingPathExtension + "_临色"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = base + ".xmp"
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try XMP.make(params, name: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
            flash(params.masks.isEmpty ? "已导出 Lightroom 预设" : "已导出 Lightroom 预设（蒙版不包含在内）")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { flash("导出失败：\(error.localizedDescription)") }
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
        NSApp?.appearance = theme == .auto ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        redrawTick &+= 1
    }

    func cycleTheme() {
        let all = ThemeMode.allCases
        theme = all[(all.firstIndex(of: theme)! + 1) % all.count]
        flash(theme.label)
    }
}
