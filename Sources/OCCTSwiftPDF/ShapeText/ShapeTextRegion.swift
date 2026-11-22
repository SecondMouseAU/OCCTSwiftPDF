// ShapeTextRegion.swift
// OCCTSwiftPDF
//
// One line of shapes that might be text: the geometry the recogniser's result is checked against.

import CoreGraphics
import Foundation

/// A line of glyph-sized shapes, measured along the direction it would be read.
///
/// The line's frame has its origin at the start of the ink box's bottom edge, `a` along the
/// reading direction and `b` across it (counterclockwise from `a`), in page units. Its box is
/// `0...length` by `0...height`.
struct ShapeTextRegion {
    /// The unit vector along the reading direction, in page coordinates.
    var direction: CGPoint
    /// The frame's origin in page coordinates.
    var origin: CGPoint
    /// The ink's extent along the direction.
    var length: Double
    /// The ink's extent across it.
    var height: Double
    /// The number of glyph-sized pieces (a letter's outer and inner outlines count once).
    var glyphs: Int
    /// Most of its pieces are strokes, not filled outlines.
    var mostlyStroked: Bool
    /// The direction is steep enough that its reverse is also a way text may run (up a sheet or
    /// down it), so a reading that fails is tried the other way round.
    var canReverse: Bool
    /// The indices into `Page.paths` of the paths its pieces belong to, in content order, once
    /// each.
    var paths: [Int]
    /// Each glyph's extent across the reading direction, in the frame (0 is the box's bottom).
    var spans: [ClosedRange<Double>] = []

    /// The unit vector across the reading direction.
    var across: CGPoint { CGPoint(x: -direction.y, y: direction.x) }

    /// The reading direction, counterclockwise from the page's x axis, in degrees from 0 to 360.
    var angleDegrees: Double {
        var degrees = atan2(direction.y, direction.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// The point of the frame at (`a`, `b`), in page coordinates.
    func point(a: Double, b: Double) -> CGPoint {
        let n = across
        return CGPoint(
            x: origin.x + direction.x * a + n.x * b, y: origin.y + direction.y * a + n.y * b)
    }

    /// The box's corners in page coordinates: baseline start, baseline end, top end, top start.
    var quad: [CGPoint] {
        [
            point(a: 0, b: 0), point(a: length, b: 0), point(a: length, b: height),
            point(a: 0, b: height),
        ]
    }

    /// The same box read the other way round: turned half a turn about its centre.
    var reversed: ShapeTextRegion {
        var other = self
        other.direction = CGPoint(x: -direction.x, y: -direction.y)
        other.origin = point(a: length, b: height)
        other.canReverse = false
        other.spans = spans.map { (height - $0.upperBound)...(height - $0.lowerBound) }
        return other
    }

    /// Where the baseline is across the box, from its bottom: where most glyphs stand.
    ///
    /// Glyphs are grouped by where they start, each within a tenth of the box's height of the one
    /// before, and the group with the most ink (the sum of its glyphs' heights) is the baseline's,
    /// so a comma or a `g` that hangs below it, and the dot of an `i` that floats above it, do not
    /// move it. The baseline is the highest start in that group: a round glyph dips a little below
    /// the line that a flat one stands on. Zero where the glyphs are not known.
    var baseline: Double {
        let tolerance = 0.1 * height
        var groups: [(top: Double, ink: Double)] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let ink = span.upperBound - span.lowerBound
            if let last = groups.last, span.lowerBound - last.top <= tolerance {
                groups[groups.count - 1] = (span.lowerBound, last.ink + ink)
            } else {
                groups.append((span.lowerBound, ink))
            }
        }
        return groups.max { $0.ink < $1.ink }?.top ?? 0
    }

    /// The box's corners from the baseline up: baseline start, baseline end, top end, top start.
    var quadFromBaseline: [CGPoint] {
        let base = min(baseline, 0.5 * height)
        return [
            point(a: 0, b: base), point(a: length, b: base), point(a: length, b: height),
            point(a: 0, b: height),
        ]
    }

    /// The box's bounding rectangle in page coordinates.
    var bounds: CGRect {
        let corners = quad
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else {
            return .null
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
