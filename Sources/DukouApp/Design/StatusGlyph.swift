import AppKit

/// The menu bar glyph: the app icon's speech bubble, drawn rather than picked
/// from SF Symbols.
///
/// `tray` / `tray.full` said "an inbox", which is what every second menu bar app
/// says, and neither shape had anything to do with the icon the user settled on
/// (`Resources/AppIcon-artwork.png`: a green bubble with two eyes and a tail at
/// its lower right). One drawn glyph keeps the two in the same visual language,
/// and lets the loaded state be a change of weight rather than a different
/// symbol with a different optical mass.
///
/// Geometry is in points with y running up from the bottom, and every fixed edge
/// lands on an integer or a half — an 18 pt template image is rasterised at 1x
/// on a non-Retina display, and a bubble whose edge sits at y = 4.7 comes out of
/// that as a grey smear next to the crisp system icons beside it.
enum StatusGlyph {
    /// Menu bar template images are 18×18; AppKit scales anything else and the
    /// stroke weight stops matching the neighbours.
    private static let side: CGFloat = 18

    /// The bubble: 15 × 11 (x 1.5–16.5, y 4.5–15.5).
    private static let centre = CGPoint(x: 9, y: 10)
    private static let radius = CGSize(width: 7.5, height: 5.5)
    /// Where the tail leaves the lower-right arc and where it comes back. Angles
    /// rather than points, because the silhouette is one closed path: the arc
    /// between these two is not drawn at all, so the tail has no seam across its
    /// base in either state.
    private static let tailRootAngle: CGFloat = -42.8
    private static let tailHeelAngle: CGFloat = -70.5
    /// The tail's head is two points, not one: a single apex drew a claw at
    /// this size, however the handles were tuned. The icon's tail is a blunt
    /// rounded nub, so the head is a short curve between (16, 4) and (14.6, 3.1)
    /// — its far corner is the (15.5, 3) the design fixes.
    private static let tailHead = (outer: CGPoint(x: 15.86, y: 3.17), inner: CGPoint(x: 15.14, y: 2.83))

    /// The two eyes, diameter 2, on the bubble's own centre line.
    private static let eyeCentres = [CGPoint(x: 7, y: 10), CGPoint(x: 11, y: 10)]
    private static let eyeDiameter: CGFloat = 2
    /// A stroked bubble has to hold its shape at 1x; thinner than this and the
    /// empty state disappears next to a filled system glyph.
    private static let outlineWidth: CGFloat = 1.5

    /// Both states draw the identical bubble in the identical place. Only the
    /// ink moves: loaded is a solid bubble with the eyes knocked out of it,
    /// empty is an outline with the eyes filled in. Nothing shifts, so the
    /// switch does not make the menu bar twitch.
    static func image(loaded: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            if loaded {
                // Even-odd is what makes the eyes transparent rather than
                // white: a template image is a mask, and a white disc inside it
                // would be painted as solid ink of the menu bar's own tint.
                let filled = body
                for centre in eyeCentres { filled.append(eye(at: centre)) }
                filled.windingRule = .evenOdd
                filled.fill()
            } else {
                let outline = body
                outline.lineWidth = outlineWidth
                outline.lineJoinStyle = .round
                outline.stroke()
                for centre in eyeCentres { eye(at: centre).fill() }
            }
            return true
        }
        // Without this the glyph ignores the menu bar's appearance and stays
        // black on a dark menu bar.
        image.isTemplate = true
        return image
    }

    /// The bubble and its tail as **one** closed path.
    ///
    /// Two overlapping subpaths would fill correctly and stroke wrongly — the
    /// ellipse's own arc would draw straight across the base of the tail. So the
    /// arc under the tail is simply never emitted: the path runs out to the tip,
    /// back to the heel, then all the way round the remaining 315° of the
    /// ellipse.
    private static var body: NSBezierPath {
        let path = NSBezierPath()
        let root = point(at: tailRootAngle)
        let heel = point(at: tailHeelAngle)

        path.move(to: root)
        // Down the right, round the head, back along the underside. Every
        // control point sits outside its own chord, so the whole nub is convex
        // — the concave version read as a claw hooked under the bubble.
        path.curve(
            to: tailHead.outer,
            controlPoint1: CGPoint(x: 14.95, y: 5.24),
            controlPoint2: CGPoint(x: 15.41, y: 4.2)
        )
        path.curve(
            to: tailHead.inner,
            controlPoint1: CGPoint(x: 15.7, y: 2.85),
            controlPoint2: CGPoint(x: 15.35, y: 2.75)
        )
        path.curve(
            to: heel,
            controlPoint1: CGPoint(x: 13.93, y: 3.5),
            controlPoint2: CGPoint(x: 12.71, y: 4.16)
        )
        appendArc(to: path, from: tailHeelAngle, to: tailRootAngle - 360)
        path.close()
        return path
    }

    private static func point(at degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: centre.x + radius.width * cos(radians),
            y: centre.y + radius.height * sin(radians)
        )
    }

    /// An elliptical arc as cubics. `NSBezierPath.appendArc` only knows circles,
    /// and scaling a circular arc into place would squash the tail with it, so
    /// the ellipse is parameterised directly. Chunks of at most 90° because the
    /// cubic approximation visibly bulges past that.
    private static func appendArc(to path: NSBezierPath, from start: CGFloat, to end: CGFloat) {
        let steps = max(1, Int((abs(end - start) / 90).rounded(.up)))
        let step = (end - start) / CGFloat(steps)
        for index in 0..<steps {
            let from = start + step * CGFloat(index)
            let to = from + step
            let alpha = 4.0 / 3.0 * tan(step * .pi / 180 / 4)
            path.curve(
                to: point(at: to),
                controlPoint1: offset(point(at: from), by: alpha, at: from),
                controlPoint2: offset(point(at: to), by: -alpha, at: to)
            )
        }
    }

    /// The arc's tangent at `degrees`, scaled — the handle length that makes a
    /// cubic match the ellipse.
    private static func offset(_ origin: CGPoint, by alpha: CGFloat, at degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: origin.x - alpha * radius.width * sin(radians),
            y: origin.y + alpha * radius.height * cos(radians)
        )
    }

    private static func eye(at centre: CGPoint) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(
            x: centre.x - eyeDiameter / 2,
            y: centre.y - eyeDiameter / 2,
            width: eyeDiameter,
            height: eyeDiameter
        ))
    }
}
