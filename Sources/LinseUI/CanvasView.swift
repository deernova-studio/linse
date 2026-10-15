import LinseCore
import MetalKit
import SwiftUI

/// 中间的画布：MTKView 直接把调色管线画到屏幕上，按比例适配；对比模式左边原图、右边结果
#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct CanvasView: PlatformViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(state) }

    func makeView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: state.display.device)
        v.delegate = context.coordinator
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.framebufferOnly = true
        v.colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.layer?.isOpaque = false
        #else
        v.isOpaque = false
        v.backgroundColor = .clear
        #endif
        context.coordinator.view = v
        return v
    }

    func updateView(_ v: MTKView, context: Context) {
        context.coordinator.state = state
        #if os(macOS)
        v.needsDisplay = true
        #else
        v.setNeedsDisplay()
        #endif
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { makeView(context: context) }
    func updateNSView(_ v: MTKView, context: Context) { updateView(v, context: context) }
    #else
    func makeUIView(context: Context) -> MTKView { makeView(context: context) }
    func updateUIView(_ v: MTKView, context: Context) { updateView(v, context: context) }
    #endif

    final class Coordinator: NSObject, MTKViewDelegate {
        var state: AppState
        weak var view: MTKView?
        init(_ s: AppState) { state = s }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            #if os(macOS)
            view.needsDisplay = true
            #else
            view.setNeedsDisplay()
            #endif
        }

        @MainActor
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let cb = state.display.makeCommandBuffer() else { return }
            #if os(macOS)
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scale = view.window?.backingScaleFactor ?? 2
            #else
            let dark = view.traitCollection.userInterfaceStyle == .dark
            let scale = view.contentScaleFactor
            #endif
            let bg = dark ? MTLClearColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1) : MTLClearColor(red: 0.957, green: 0.957, blue: 0.965, alpha: 1)
            let target = drawable.texture
            let fit = Self.fitRect(image: state.display.imageSize, in: CGSize(width: target.width, height: target.height), inset: state.canvasInset * scale)
            // 先清屏
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = bg
            rp.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            if state.display.image != nil, fit.width > 0 {
                let vp = MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1)
                let showMask = state.showMaskOverlay ? (state.selectedMaskIndex ?? -1) : -1
                switch state.effectiveView {
                case .result:
                    try? state.display.encode(state.params, into: target, commandBuffer: cb, opts: RenderOptions(showMask: showMask), viewport: vp)
                case .original:
                    try? state.display.encode(state.params, into: target, commandBuffer: cb, opts: RenderOptions(bypass: true), viewport: vp)
                case .split:
                    let sx = Int(fit.minX + fit.width * state.split)
                    let left = MTLScissorRect(x: Int(fit.minX), y: Int(fit.minY), width: max(0, sx - Int(fit.minX)), height: Int(fit.height))
                    let right = MTLScissorRect(x: sx, y: Int(fit.minY), width: max(0, Int(fit.maxX) - sx), height: Int(fit.height))
                    if left.width > 0 { try? state.display.encode(state.params, into: target, commandBuffer: cb, opts: RenderOptions(bypass: true), viewport: vp, scissor: left) }
                    if right.width > 0 { try? state.display.encode(state.params, into: target, commandBuffer: cb, opts: RenderOptions(showMask: showMask), viewport: vp, scissor: right) }
                }
            }
            cb.present(drawable)
            cb.commit()
        }

        static func fitRect(image: CGSize, in box: CGSize, inset: CGFloat) -> CGRect {
            guard image.width > 0, image.height > 0 else { return .zero }
            let W = box.width - inset * 2, H = box.height - inset * 2
            let k = min(W / image.width, H / image.height)
            let w = (image.width * k).rounded(), h = (image.height * k).rounded()
            return CGRect(x: ((box.width - w) / 2).rounded(), y: ((box.height - h) / 2).rounded(), width: w, height: h)
        }
    }
}

/// 画布外层：对比分割线、拖放导入、空状态引导、处理中遮罩
struct StageView: View {
    @ObservedObject var state: AppState
    @State private var dropTarget = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CanvasView(state: state)
                if state.source == nil { EmptyGuide(state: state) }
                if state.source != nil, state.effectiveView != .original, let i = state.selectedMaskIndex, [.radial, .linear].contains(state.params.masks[i].type) {
                    MaskHandle(state: state, index: i, fit: CanvasView.Coordinator.fitRect(image: state.display.imageSize, in: geo.size, inset: state.canvasInset))
                }
                if state.effectiveView == .split, state.source != nil {
                    let fit = CanvasView.Coordinator.fitRect(image: state.display.imageSize, in: geo.size, inset: state.canvasInset)
                    let x = fit.minX + fit.width * state.split
                    Rectangle().fill(.white).frame(width: 1, height: fit.height)
                        .shadow(color: .black.opacity(0.4), radius: 0.5)
                        .position(x: x, y: fit.midY)
                    Text("原图  |  结果").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(.ultraThinMaterial)
                        .position(x: x, y: fit.minY + 14)
                    Color.clear.contentShape(Rectangle()).frame(width: 24, height: fit.height).position(x: x, y: fit.midY)
                        .gesture(DragGesture().onChanged { g in state.split = min(1, max(0, (g.location.x - fit.minX) / fit.width)) })
                        .hoverCursor(.resizeLeftRight)
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 2).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).padding(12)
                    Text(state.source != nil && state.target == nil ? "松开导入为目标风格" : "松开导入为原图").font(.system(size: 13))
                }
                if let b = state.busy {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(b).font(.system(size: 12)).multilineTextAlignment(.center)
                        if state.canCancel { Button("取消") { state.cancelBusy() }.controlSize(.small).keyboardShortcut(.cancelAction) }
                    }
                        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .onChange(of: state.split) { _ in state.redrawTick &+= 1 }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            let kinds: [AppState.SlotKind] = providers.count >= 2 ? [.source, .target] : [state.source != nil && state.target == nil ? .target : .source]
            for (p, k) in zip(providers, kinds) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in state.load(url, into: k) } }
                }
            }
            return true
        }
    }
}

/// 选中的径向/线性蒙版：在图上画出位置，拖动重新摆放（径向：按下处为中心、拖出半径；线性：从按下处拖到松开处）
struct MaskHandle: View {
    @ObservedObject var state: AppState
    let index: Int
    let fit: CGRect

    var body: some View {
        let m = state.params.masks[index]
        ZStack {
            Color.clear.contentShape(Rectangle())
            if m.type == .radial {
                Ellipse().stroke(.white.opacity(0.9), lineWidth: 1).shadow(color: .black.opacity(0.5), radius: 0.5)
                    .frame(width: m.rx * 2 * fit.width, height: m.ry * 2 * fit.height)
                    .position(x: m.cx * fit.width, y: m.cy * fit.height)
            } else {
                Path { p in
                    p.move(to: CGPoint(x: m.cx * fit.width, y: m.cy * fit.height))
                    p.addLine(to: CGPoint(x: m.x2 * fit.width, y: m.y2 * fit.height))
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).shadow(color: .black.opacity(0.5), radius: 0.5)
            }
            Circle().fill(.white).frame(width: 6, height: 6).shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: m.cx * fit.width, y: m.cy * fit.height)
        }
        .frame(width: fit.width, height: fit.height)
        .position(x: fit.midX, y: fit.midY)
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let x0 = min(1, max(0, g.startLocation.x / fit.width)), y0 = min(1, max(0, g.startLocation.y / fit.height))
            let x = min(1, max(0, g.location.x / fit.width)), y = min(1, max(0, g.location.y / fit.height))
            var m = state.params.masks[index]
            m.cx = x0; m.cy = y0
            if m.type == .radial {
                if hypot(x - x0, y - y0) > 0.01 { m.rx = max(0.01, abs(x - x0)); m.ry = max(0.01, abs(y - y0)) }
            } else {
                m.x2 = x; m.y2 = hypot(x - x0, y - y0) > 0.01 ? y : min(1, y0 + 0.01)
            }
            state.params.masks[index] = m
        })
        .hoverCursor(.crosshair)
    }
}

struct EmptyGuide: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            step(1, "导入你的照片", "⌘O") { state.open(.source) }
            Divider()
            step(2, "导入目标风格", "⇧⌘O") { state.open(.target) }
            Divider()
            step(3, "匹配", "⌘↩") { state.runMatch() }
        }
        .frame(maxWidth: 720, maxHeight: 140)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(32)
    }

    func step(_ n: Int, _ title: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(n)").font(.system(size: 11)).frame(width: 18, height: 18).overlay(Circle().stroke(Color.secondary.opacity(0.5)))
                Text(title).font(.system(size: 14)).lineLimit(1)
                Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
