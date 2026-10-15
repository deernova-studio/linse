import LinseCore
import SwiftUI

/// 曲线编辑：点击空白处加点，拖动调整，双击删除（端点不可删）
struct CurveEditor: View {
    @Binding var points: [[Double]]
    let others: [[[Double]]]
    let color: Color
    @State private var dragIdx: Int?

    var body: some View {
        GeometryReader { g in
            let s = g.size
            Canvas { ctx, size in
                // 网格
                var grid = Path()
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.18)), lineWidth: 1)
                var diag = Path(); diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(diag, with: .color(.primary.opacity(0.1)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                for o in others where !Curve.isIdentity(o) { ctx.stroke(curvePath(o, size), with: .color(.primary.opacity(0.18)), lineWidth: 1) }
                ctx.stroke(curvePath(points, size), with: .color(color), lineWidth: 1.2)
                for p in points {
                    let c = toView(p, size)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(Color.appBackground))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragIdx == nil {
                        if let i = hit(v.startLocation, s) { dragIdx = i } else { dragIdx = insert(fromView(v.startLocation, s)) }
                    }
                    guard let i = dragIdx else { return }
                    var p = fromView(v.location, s)
                    let pts = points
                    if i == 0 { p[0] = min(p[0], pts[1][0] - 1) } else if i == pts.count - 1 { p[0] = max(p[0], pts[i - 1][0] + 1) }
                    else { p[0] = min(max(p[0], pts[i - 1][0] + 1), pts[i + 1][0] - 1) }
                    var np = pts; np[i] = p; points = np
                }
                .onEnded { _ in dragIdx = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                if let i = hit(v.location, s), i > 0, i < points.count - 1 { var np = points; np.remove(at: i); points = np }
            })
        }
    }

    func toView(_ p: [Double], _ s: CGSize) -> CGPoint { CGPoint(x: CGFloat(p[0]) / 255 * s.width, y: (1 - CGFloat(p[1]) / 255) * s.height) }
    func fromView(_ c: CGPoint, _ s: CGSize) -> [Double] {
        [Double(min(255, max(0, (c.x / s.width * 255).rounded()))), Double(min(255, max(0, ((1 - c.y / s.height) * 255).rounded())))]
    }
    func hit(_ c: CGPoint, _ s: CGSize) -> Int? {
        var best: Int?, bd: CGFloat = 10
        for (i, p) in points.enumerated() {
            let v = toView(p, s)
            let d = hypot(v.x - c.x, v.y - c.y)
            if d < bd { bd = d; best = i }
        }
        return best
    }
    func insert(_ p: [Double]) -> Int? {
        guard points.count < 14, let i = points.firstIndex(where: { $0[0] > p[0] }), i > 0, points[i - 1][0] < p[0] else { return nil }
        var np = points; np.insert(p, at: i); points = np
        return i
    }
    func curvePath(_ pts: [[Double]], _ s: CGSize) -> Path {
        var path = Path()
        let ys = Curve.evaluate(pts, n: 65)
        for i in 0...64 {
            let c = CGPoint(x: CGFloat(i) / 64 * s.width, y: (1 - CGFloat(ys[i])) * s.height)
            if i == 0 { path.move(to: c) } else { path.addLine(to: c) }
        }
        return path
    }
}
