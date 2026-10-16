import LinseCore

/// 一次可撤销编辑的完整值；强度依赖 matched，必须与实际参数一起恢复。
struct EditorSnapshot: Equatable {
    var params = Params()
    var matched: Params?
    var strength = 100.0
    var summary: Summary?

    func removingLUT(_ id: String) -> Self {
        var result = self
        if result.params.lut?.id == id { result.params.lut = nil; result.summary = nil }
        if result.matched?.lut?.id == id {
            result.matched = nil
            result.strength = 100
            result.summary = nil
        }
        return result
    }
}

struct EditHistory {
    private var entries = [EditorSnapshot()]
    private var index = 0

    mutating func record(_ state: EditorSnapshot) {
        guard entries[index] != state else { return }
        entries.removeSubrange((index + 1)..<entries.count)
        entries.append(state)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }

    mutating func undo() -> EditorSnapshot? {
        guard index > 0 else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func redo() -> EditorSnapshot? {
        guard index + 1 < entries.count else { return nil }
        index += 1
        return entries[index]
    }

    mutating func removeLUT(_ id: String) {
        var kept: [EditorSnapshot] = []
        var newIndex = 0
        for (i, entry) in entries.enumerated() {
            let clean = entry.removingLUT(id)
            if kept.last != clean { kept.append(clean) }
            if i == index { newIndex = kept.count - 1 }
        }
        entries = kept
        index = newIndex
    }

    mutating func invalidateMatchSummaries() {
        for i in entries.indices {
            if let summary = entries[i].summary, !summary.source.hasPrefix("预设") { entries[i].summary?.stale = true }
        }
    }
}
