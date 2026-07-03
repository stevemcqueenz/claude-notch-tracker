import SwiftUI

/// The notch silhouette: flush with the top screen edge, with small *concave* flared top corners
/// (so the black blends into the menu bar exactly like the hardware notch) and larger rounded
/// bottom corners. Animating the two radii morphs the shape smoothly between the closed pill and
/// the open panel, so it reads as the notch itself growing.
///
/// Approach adapted from pookify (MIT, github.com/eyadhammouda/pookify).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = max(0, min(topRadius, r.height / 2))
        let b = max(0, min(bottomRadius, r.width / 2 - t, r.height - t))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        // top-left: concave flare from the top edge down into the left wall
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t),
                       control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        // bottom-left rounded corner
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY),
                       control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        // bottom-right rounded corner
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b),
                       control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        // top-right: concave flare back up to the top edge
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}
