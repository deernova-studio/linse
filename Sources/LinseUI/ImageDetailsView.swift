import SwiftUI

struct ImageDetailsView: View {
    let slot: Slot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("图片详情").font(.headline)
                ForEach(details) { detail in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(detail.label).font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: detail.value).font(.callout)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }

    private var details: [Detail] {
        let metadata = slot.metadata
        var rows = [Detail(label: "名称", value: slot.name),
                    Detail(label: "尺寸", value: "\(Int(slot.size.width)) × \(Int(slot.size.height)) 像素")]
        if let format = metadata.format { rows.append(Detail(label: "格式", value: metadata.isRAW ? "\(format) · RAW" : format)) }
        if let bytes = metadata.byteCount {
            rows.append(Detail(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let profile = metadata.colorProfile { rows.append(Detail(label: "色彩空间", value: profile)) }
        if let depth = metadata.bitDepth { rows.append(Detail(label: "位深", value: "\(depth) 位 / 通道")) }
        if let camera = metadata.camera { rows.append(Detail(label: "相机", value: camera)) }
        if let lens = metadata.lens { rows.append(Detail(label: "镜头", value: lens)) }
        if let date = metadata.capturedAt { rows.append(Detail(label: "拍摄时间", value: date)) }
        return rows
    }

    private struct Detail: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }
}
