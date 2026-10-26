import Foundation
import CoreGraphics

/// Perspective projection of a 2D plane in 3D, applied to vector geometry (paths, text outlines, clips) so lines stay crisp.
/// Points are rotated about `pivot` (plane-local), translated by (tx, ty, tz) and projected with focal length `focal` (px)
/// toward a vanishing point at the pivot. Straight segments stay straight under projection, so only curves are subdivided.
/// rotationX > 0 tips the top edge away (a floor receding upward); rotationY > 0 swings the right edge away.
/// Nested planes compose. Raster images are drawn unprojected. Geometry crossing behind the camera is clipped at a near plane
/// (depth = 5% of the focal length), so a floor grid may run under the viewer; only an enclosing plane can still drop a path.
public final class Projection {
    public let base: CGAffineTransform, inverse: CGAffineTransform
    public let pivot: CGPoint, rx: Double, ry: Double, tx: Double, ty: Double, tz: Double, focal: Double
    public let outer: Projection?
    public init(base: CGAffineTransform, pivot: CGPoint, rx: Double, ry: Double, tx: Double = 0, ty: Double = 0, tz: Double = 0, focal: Double = 1400, outer: Projection? = nil) {
        self.base = base; inverse = base.inverted(); self.pivot = pivot
        self.rx = rx; self.ry = ry; self.tx = tx; self.ty = ty; self.tz = tz; self.focal = max(1,focal); self.outer = outer
    }
    /// Plane-local point -> camera space: (x, y) about the pivot after rotation and pan, and depth along the view axis.
    public func lift(local p: CGPoint) -> (x: Double, y: Double, depth: Double) {
        let x = p.x-pivot.x, y = p.y-pivot.y
        let x1 = x*cos(ry), z1 = x*sin(ry)
        let y2 = y*cos(rx), z2 = z1-y*sin(rx)
        return (x1+tx,y2+ty,focal+z2+tz)
    }
    public var near: Double { focal*0.05 }
    private func divide(_ q: (x: Double, y: Double, depth: Double)) -> (CGPoint, Double) {
        let s = focal/q.depth
        return (CGPoint(x:pivot.x+q.x*s,y:pivot.y+q.y*s),s)
    }
    /// Plane-local point -> plane-local projected point and its perspective scale; nil behind the near plane.
    public func project(local p: CGPoint) -> (CGPoint, Double)? {
        let q = lift(local:p)
        guard q.depth >= near else { return nil }
        return divide(q)
    }
    /// Clips camera-space points to depth >= near: a closed ring stays one ring (Sutherland-Hodgman), an open polyline
    /// splits into the runs in front of the camera.
    func clipNear(_ pts: [(x: Double, y: Double, depth: Double)], closed: Bool) -> [[(x: Double, y: Double, depth: Double)]] {
        let n = near
        func cut(_ a: (x: Double, y: Double, depth: Double), _ b: (x: Double, y: Double, depth: Double)) -> (x: Double, y: Double, depth: Double) {
            let k = (n-a.depth)/(b.depth-a.depth)
            return (a.x+(b.x-a.x)*k,a.y+(b.y-a.y)*k,n)
        }
        guard pts.contains(where: { $0.depth < n }) else { return [pts] }
        if closed {
            var ring: [(x: Double, y: Double, depth: Double)] = []
            for (i,b) in pts.enumerated() {
                let a = pts[(i+pts.count-1)%pts.count]
                if b.depth >= n { if a.depth < n { ring.append(cut(a,b)) }; ring.append(b) }
                else if a.depth >= n { ring.append(cut(a,b)) }
            }
            return ring.count >= 3 ? [ring] : []
        }
        var runs: [[(x: Double, y: Double, depth: Double)]] = [], run: [(x: Double, y: Double, depth: Double)] = []
        for (i,b) in pts.enumerated() {
            if i > 0 {
                let a = pts[i-1]
                if a.depth >= n && b.depth < n { run.append(cut(a,b)); runs.append(run); run = [] }
                else if a.depth < n && b.depth >= n { run.append(cut(a,b)) }
            }
            if b.depth >= n { run.append(b) }
        }
        if run.count > 1 { runs.append(run) }
        return runs.filter { $0.count > 1 }
    }
    /// Device point -> projected device point (through every enclosing plane) and the accumulated scale.
    public func map(device d: CGPoint) -> (CGPoint, Double)? {
        guard let (p,s) = project(local:d.applying(inverse)) else { return nil }
        let out = p.applying(base)
        guard let outer else { return (out,s) }
        guard let (o,s2) = outer.map(device:out) else { return nil }
        return (o,s*s2)
    }
    /// Projects a path drawn under user transform `ctm`; the result is in the same user space. Returns the mean scale,
    /// or nil when nothing is left in front of the camera.
    public func project(_ path: Path, ctm: CGAffineTransform) -> (Path, Double)? {
        guard abs(ctm.a*ctm.d-ctm.b*ctm.c) > 1e-12 else { return nil }
        let back = ctm.inverted(), out = Path()
        var total = 0.0, count = 0
        for line in path.flattened(steps:24) {
            let lifted = line.points.map { lift(local:$0.applying(ctm).applying(inverse)) }
            for run in clipNear(lifted,closed:line.closed) {
                for (i,q) in run.enumerated() {
                    var (p,s) = divide(q)
                    p = p.applying(base)
                    if let outer { guard let (o,s2) = outer.map(device:p) else { return nil }; p = o; s *= s2 }
                    let u = p.applying(back)
                    if i == 0 { out.move(u.x,u.y) } else { out.line(u.x,u.y) }
                    total += s; count += 1
                }
                if line.closed { out.close() }
            }
        }
        guard count > 0 else { return nil }
        return (out,total/Double(count))
    }
}
