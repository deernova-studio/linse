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
            let scale = view.window?.backingScaleFactor ?? 2
            #else
            let scale = view.contentScaleFactor
            #endif
            // Match the opaque Deernova canvas using its sRGB components.
            #if os(macOS)
            var paper = NSColor.black
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                paper = NSColor(Color.canvas).usingColorSpace(.sRGB)!
            }
            let bg = MTLClearColor(red: paper.redComponent, green: paper.greenComponent, blue: paper.blueComponent, alpha: 1)
            #else
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(Color.canvas).resolvedColor(with: view.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let bg = MTLClearColor(red: red, green: green, blue: blue, alpha: 1)
            #endif
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
                    Text("原图  |  结果").font(AppTypography.ui(10.5)).foregroundStyle(Color.inkSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(.ultraThinMaterial)
                        .position(x: x, y: fit.minY + 14)
                    Color.clear.contentShape(Rectangle()).frame(width: 24, height: fit.height).position(x: x, y: fit.midY)
                        .gesture(DragGesture().onChanged { g in state.split = min(1, max(0, (g.location.x - fit.minX) / fit.width)) })
                        .hoverCursor(.resizeLeftRight)
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 2).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).padding(12)
                    Text(state.source != nil && state.target == nil ? "松开导入为目标风格" : "松开导入为原图").font(AppTypography.ui(13))
                }
                if let b = state.busy {
                    Color.scrim
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(b).font(AppTypography.ui(12)).multilineTextAlignment(.center)
                        if state.canCancel { Button("取消") { state.cancelBusy() }.controlSize(.small).keyboardShortcut(.cancelAction) }
                    }
                        .padding(18).background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Deernova.cardRadius))
                }
            }
            .onChange(of: state.split) { state.redrawTick &+= 1 }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            let kinds: [AppState.SlotKind] = providers.count >= 2 ? [.source, .target] : [state.source != nil && state.target == nil ? .target : .source]
            return state.importDroppedImages(providers, into: kinds)
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
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Color.inkTertiary)
                    .accessibilityHidden(true)
                Text("从参考照片开始调色").font(AppTypography.guideTitle)
                    .foregroundStyle(Color.ink).multilineTextAlignment(.center)
                Text("先导入原图，再选择喜欢的参考图，匹配色彩后继续微调。")
                    .font(AppTypography.ui(13)).foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { importActions }
                    VStack(spacing: 8) { importActions }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .frame(maxWidth: 600)
    }

    @ViewBuilder private var importActions: some View {
        Button("导入原图", systemImage: "plus") { state.open(.source) }
            // Native buttons own foreground contrast, including inactive-window
            // fills where AppKit deliberately does not use the requested tint.
            .buttonStyle(.borderedProminent).tint(Color.brandAccent)
            .controlSize(.large)
        Button("选择参考图") { state.open(.target) }
            .buttonStyle(.bordered).controlSize(.large)
    }
}
