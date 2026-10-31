import Foundation
import LinseCore

extension AppState {
    func scheduleWorkspaceSave() {
        guard workspaceReady, workspaceStore != nil else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            await self?.saveWorkspaceNow()
        }
    }

    /// 退出 / 转入后台时跳过防抖，等待最后一次写入完成。
    @discardableResult
    public func saveWorkspaceNow() async -> Bool {
        guard let store = workspaceStore else { return true }
        guard workspaceReady else { return !workspaceRecoveryBlocked }
        history.record(editSnapshot)
        var images: [UUID: Data] = [:]
        for slot in [source, target].compactMap({ $0 }) {
            guard let data = slot.originalData else {
                workspaceError = "无法保存编辑现场：缺少原始图片数据"
                return false
            }
            images[slot.id] = data
        }
        func reference(_ slot: Slot?) -> WorkspaceImage? {
            slot.map { WorkspaceImage(id: $0.id, name: $0.name, typeIdentifierHint: $0.typeIdentifierHint) }
        }
        var masks: [MaskType: MaskBitmap] = [:]
        for type in MaskType.allCases where type.isSmart { masks[type] = smartMasks.maskBitmap(type) }
        let record = WorkspaceRecord(source: reference(source), target: reference(target), edit: editSnapshot,
                                     history: history, masks: masks, viewMode: viewMode.rawValue, split: Double(split))
        do {
            try await store.save(record, images: images)
            return true
        } catch {
            workspaceError = "保存编辑现场失败：\(error.localizedDescription)"
            return false
        }
    }

    func archiveFailedWorkspaceAndContinue() async {
        guard workspaceRecoveryBlocked, let store = workspaceStore else { return }
        do {
            try await store.archive()
            workspaceRecoveryBlocked = false
            workspaceReady = true
            workspaceError = nil
            _ = await saveWorkspaceNow()
        } catch {
            workspaceError = "备份原编辑现场失败：\(error.localizedDescription)"
        }
    }

    func restoreWorkspace() async {
        guard !workspaceRestoreStarted else { return }
        workspaceRestoreStarted = true
        guard let store = workspaceStore else { workspaceReady = true; return }
        guard source == nil, target == nil, busy == nil else { workspaceReady = true; return }
        busy = "正在恢复上次编辑…"
        defer {
            busy = nil
            if workspaceReady { refreshSmartMasks() }
        }
        do {
            if let (record, images) = try await store.load() {
                // 所有图片先解码成功，再安装到编辑器；损坏的现场不自动覆盖。
                var decoded: [(SlotKind, WorkspaceImage, ImportedImage)] = []
                for (kind, reference) in [(SlotKind.source, record.source), (.target, record.target)] {
                    if let reference, let data = images[reference.id] {
                        let image = try await imageImports.load(data: data, name: reference.name, typeIdentifierHint: reference.typeIdentifierHint)
                        decoded.append((kind, reference, image))
                    }
                }
                for (kind, reference, image) in decoded {
                    guard load(image.image, name: reference.name, into: kind, metadata: image.metadata,
                               thumbnail: image.thumbnail, originalData: image.originalData, typeIdentifierHint: image.typeIdentifierHint) else {
                        throw WorkspaceStore.Failure.missingImage
                    }
                    if kind == .source { source?.id = reference.id } else { target?.id = reference.id }
                }
                for (type, bitmap) in record.masks { smartMasks.set(type, bitmap) }
                restoreEdit(record.edit)
                history = record.history
                viewMode = ViewMode(rawValue: record.viewMode) ?? .result
                split = min(1, max(0, record.split))
                flash("已恢复上次编辑")
            }
            workspaceReady = true
        } catch {
            workspaceRecoveryBlocked = true
            workspaceError = "恢复编辑现场失败：\(error.localizedDescription)。原恢复文件已保留；本次不会自动覆盖它。"
        }
    }
}
