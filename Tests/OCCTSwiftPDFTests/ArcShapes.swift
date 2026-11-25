import Foundation

@testable import OCCTSwiftPDF

/// Hand-made runs of elements, in millimetres, for the arc recovery tests.
///
/// Built with plain statements and loops, so an older compiler does not choke on a large literal.
enum ArcShapes {
    typealias P = SIMD2<Double>

    static func point(_ centre: P, _ radius: Double, _ degrees: Double) -> P {
        let angle = degrees * .pi / 180
        return P(centre.x + radius * cos(angle), centre.y + radius * sin(angle))
    }

    /// An arc of a circle as `curves` equal Bezier curves.
    ///
    /// The usual circle is four curves of 90 degrees. A negative `sweep` goes clockwise.
    static func bezierArc(
        centre: P, radius: Double, from start: Double = 0, sweep: Double = 360,
        curves: Int = 4
    ) -> [ArcElement] {
        var out: [ArcElement] = []
        let each = sweep / Double(curves)
        let theta = each * .pi / 180
        // The control arm of a circular arc of angle theta.
        let k = 4.0 / 3.0 * tan(theta / 4)
        for index in 0..<curves {
            let a = start + each * Double(index)
            let b = a + each
            let p0 = point(centre, radius, a)
            let p3 = point(centre, radius, b)
            let t0 = P(-sin(a * .pi / 180), cos(a * .pi / 180))
            let t3 = P(-sin(b * .pi / 180), cos(b * .pi / 180))
            out.append(.curve(p0, p0 + k * radius * t0, p3 - k * radius * t3, p3))
        }
        return out
    }

    /// An arc of a circle as straight chords with their ends on the circle, equal in angle.
    static func flattened(
        centre: P, radius: Double, from start: Double = 0, sweep: Double = 360, segments: Int
    ) -> [ArcElement] {
        var out: [ArcElement] = []
        for index in 0..<segments {
            let a = start + sweep * Double(index) / Double(segments)
            let b = start + sweep * Double(index + 1) / Double(segments)
            out.append(.line(point(centre, radius, a), point(centre, radius, b)))
        }
        return out
    }

    /// An ellipse with semi-axes `a` (along x) and `b`, from `start` to `start + sweep` degrees
    /// of its parameter, as chords of equal parameter step.
    static func ellipse(
        centre: P, a: Double, b: Double, from start: Double = 0, sweep: Double = 360,
        segments: Int
    ) -> [ArcElement] {
        func at(_ degrees: Double) -> P {
            let t = degrees * .pi / 180
            return P(centre.x + a * cos(t), centre.y + b * sin(t))
        }
        var out: [ArcElement] = []
        for index in 0..<segments {
            let s = start + sweep * Double(index) / Double(segments)
            let e = start + sweep * Double(index + 1) / Double(segments)
            out.append(.line(at(s), at(e)))
        }
        return out
    }

    /// An ellipse of semi-axes `a` along x and `b` as four Bezier curves, the way a writer draws
    /// one by scaling a circle.
    static func ellipseCurves(centre: P, a: Double, b: Double) -> [ArcElement] {
        let k = 0.5522847498
        let east = P(centre.x + a, centre.y)
        let north = P(centre.x, centre.y + b)
        let west = P(centre.x - a, centre.y)
        let south = P(centre.x, centre.y - b)
        var out: [ArcElement] = []
        out.append(
            .curve(east, P(east.x, east.y + b * k), P(north.x + a * k, north.y), north))
        out.append(
            .curve(north, P(north.x - a * k, north.y), P(west.x, west.y + b * k), west))
        out.append(
            .curve(west, P(west.x, west.y - b * k), P(south.x - a * k, south.y), south))
        out.append(
            .curve(south, P(south.x + a * k, south.y), P(east.x, east.y - b * k), east))
        return out
    }

    /// A regular polygon with `sides` corners on a circle.
    static func polygon(centre: P, radius: Double, sides: Int) -> [ArcElement] {
        flattened(centre: centre, radius: radius, segments: sides)
    }
}
