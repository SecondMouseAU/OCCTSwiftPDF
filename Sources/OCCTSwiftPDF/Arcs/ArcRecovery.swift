// ArcRecovery.swift
// OCCTSwiftPDF
//
// Finds the runs of a subpath that are one circle or arc: consecutive straight segments and Bezier
// curves, in millimetres on the paper, that one circle passes within the tolerance of everywhere.

import Foundation

/// One straight segment or Bezier curve of a subpath, in millimetres on the paper.
enum ArcElement: Equatable, Sendable {
    case line(SIMD2<Double>, SIMD2<Double>)
    case curve(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)

    var start: SIMD2<Double> {
        switch self {
        case .line(let a, _): a
        case .curve(let a, _, _, _): a
        }
    }

    var end: SIMD2<Double> {
        switch self {
        case .line(_, let b): b
        case .curve(_, _, _, let d): d
        }
    }

    var isCurve: Bool {
        if case .curve = self { true } else { false }
    }

    /// The direction the element leaves its start in, or `nil` if it has no length.
    var startDirection: SIMD2<Double>? {
        switch self {
        case .line(let a, let b): Self.direction(from: a, to: b)
        case .curve(let a, let b, let c, let d):
            Self.direction(from: a, to: b) ?? Self.direction(from: a, to: c)
                ?? Self.direction(from: a, to: d)
        }
    }

    /// The direction the element arrives at its end in, or `nil` if it has no length.
    var endDirection: SIMD2<Double>? {
        switch self {
        case .line(let a, let b): Self.direction(from: a, to: b)
        case .curve(let a, let b, let c, let d):
            Self.direction(from: c, to: d) ?? Self.direction(from: b, to: d)
                ?? Self.direction(from: a, to: d)
        }
    }

    private static func direction(from a: SIMD2<Double>, to b: SIMD2<Double>) -> SIMD2<Double>? {
        let d = b - a
        let length = (d.x * d.x + d.y * d.y).squareRoot()
        return length > 1e-12 ? d / length : nil
    }

    /// Curve samples per Bezier curve, the last being its end.
    static let curveSamples = 8

    /// The points the fit is made over after the start: a line's end, and for a curve points along
    /// it at equal steps of the parameter, ending at its end.
    var samples: [SIMD2<Double>] {
        switch self {
        case .line(_, let b):
            return [b]
        case .curve(let p0, let p1, let p2, let p3):
            var out: [SIMD2<Double>] = []
            for k in 1...Self.curveSamples {
                let t = Double(k) / Double(Self.curveSamples)
                let u: Double = 1 - t
                // The Bernstein weights, then the sum in steps, so the compiler has little to infer.
                let w0: Double = u * u * u
                let w1: Double = 3 * u * u * t
                let w2: Double = 3 * u * t * t
                let w3: Double = t * t * t
                var point = w0 * p0
                point += w1 * p1
                point += w2 * p2
                point += w3 * p3
                out.append(point)
            }
            return out
        }
    }
}

/// A run of consecutive elements that one circle fits.
struct RecoveredArc: Equatable, Sendable {
    /// The positions in the subpath's elements.
    var range: Range<Int>
    var circle: Circle
    /// The angle of the run's first point about the centre, in radians.
    var startAngle: Double
    /// The signed sweep in radians: positive counterclockwise.
    var sweep: Double
    /// Whether the run closes on itself and goes all the way round.
    var isCircle: Bool
    var maxResidual: Double
    var rmsResidual: Double
    var curves: Int
    var lines: Int
    /// The largest sweep of one element over the smallest: 1 for a run cut into equal steps, as a
    /// writer that flattens a circle cuts it.
    var stepRatio: Double
    /// The points the circle was fitted over, in the order the run went.
    var points: [SIMD2<Double>] = []

    /// The angles of the first and last points, in degrees from 0 to 360.
    var firstDeg: Double { Self.degrees(startAngle) }
    var lastDeg: Double { Self.degrees(startAngle + sweep) }

    private static func degrees(_ radians: Double) -> Double {
        let d = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
}

enum ArcRecovery {
    /// How one stretch of elements fared against the circle fitted over it.
    private enum Evaluation {
        /// Too little to fit yet: a single straight segment.
        case provisional
        /// No acceptable circle, so no longer stretch will do either.
        case infeasible
        case feasible(RecoveredArc)
    }

    /// The arcs in `elements`, from the left, each the longest run that one circle fits, with the
    /// elements none of them took left as they are.
    ///
    /// A run with curves in it needs only `curveSweepDeg` of sweep, which is the minimum by
    /// default: a caller that will join arcs sets it lower and applies the minimum afterwards, so
    /// that a circle drawn in pieces is found from pieces that are each short.
    static func recover(
        _ elements: [ArcElement], _ options: PDF.ArcFitting, curveSweepDeg: Double? = nil
    ) -> [RecoveredArc] {
        let curveCount = elements.filter(\.isCurve).count
        guard elements.count >= 1, curveCount > 0 || elements.count >= options.minimumLineSegments
        else { return [] }
        let samples = elements.map(\.samples)
        var found: [RecoveredArc] = []
        var first = 0
        while first < elements.count {
            if let best = longest(
                from: first, elements, samples, options, curveSweepDeg: curveSweepDeg)
            {
                found.append(best)
                first = best.range.upperBound
            } else {
                first += 1
            }
        }
        return found
    }

    /// The longest run from `first` that one circle fits and that is taken as an arc, or `nil`.
    ///
    /// A run that fits has every shorter run from the same start fitting too, so the longest is
    /// found by doubling the length until a run does not fit and then halving the gap, which
    /// takes a handful of fits where trying every length would take one for each element: a
    /// finely flattened ellipse of a few hundred chords fits over most of its length from every
    /// start. The longest run is taken if it is an arc, and otherwise a few shorter ones are tried.
    private static func longest(
        from first: Int, _ elements: [ArcElement], _ samples: [[SIMD2<Double>]],
        _ options: PDF.ArcFitting, curveSweepDeg: Double?
    ) -> RecoveredArc? {
        let limit = min(elements.count, first + maximumRun)
        // A run of straight segments is tested from the fewest an arc may have: a few points of a
        // finely flattened arc are too close to straight for their circle to mean anything.
        var length = 1
        let wanted = max(1, options.minimumLineSegments)
        if first + wanted <= limit, !elements[first..<(first + wanted)].contains(where: \.isCurve) {
            length = wanted
        }
        var good = 0
        var arcs: [Int: RecoveredArc] = [:]
        var bad: Int?
        func probe(_ length: Int) -> Bool {
            switch evaluate(elements, samples, first..<(first + length), options) {
            case .infeasible:
                return false
            case .provisional:
                return true
            case .feasible(let arc):
                arcs[length] = arc
                return true
            }
        }
        while first + length <= limit {
            if probe(length) {
                good = length
                if first + length == limit { break }
                length = min(length * 2, limit - first)
            } else {
                bad = length
                break
            }
        }
        if let failed = bad {
            var low = good
            var high = failed
            while high - low > 1 {
                let middle = (low + high) / 2
                if probe(middle) { low = middle } else { high = middle }
            }
            good = low
        }
        // The longest run that fits, or one of the few just under it.
        var tried = 0
        var candidate = good
        while candidate >= 1, tried < 4 {
            if arcs[candidate] == nil, candidate < good { _ = probe(candidate) }
            if let arc = arcs[candidate], accepts(arc, options, curveSweepDeg: curveSweepDeg),
                !carriesOn(elements, arc)
            {
                return arc
            }
            candidate -= 1
            tried += 1
        }
        return nil
    }

    /// The most elements one run is tried over, which bounds the work on a long polyline.
    private static let maximumRun = 4_096

    private static func accepts(
        _ arc: RecoveredArc, _ options: PDF.ArcFitting, curveSweepDeg: Double?
    ) -> Bool {
        let minimum =
            arc.curves == 0 ? options.minimumSweepDeg : curveSweepDeg ?? options.minimumSweepDeg
        if abs(arc.sweep) < minimum * .pi / 180 - 1e-9 { return false }
        if arc.curves == 0 {
            // A flattened circle is cut into equal steps; the chords of a freehand or elliptical
            // curve are not.
            return arc.lines >= options.minimumLineSegments
                && arc.stepRatio <= options.maximumStepRatio
        }
        return true
    }

    /// Whether a run of straight segments is only part of a curve that goes on bending the same
    /// way past either end: a piece of an ellipse, a spiral or a freehand curve is locally round,
    /// and so is the polyline's whole run of them, but an arc ends where the polyline does, at a
    /// corner, or on a line that leaves it tangent (which turns by half a step, not a whole one).
    private static func carriesOn(_ elements: [ArcElement], _ arc: RecoveredArc) -> Bool {
        // A whole circle that the polyline goes on round is still a circle.
        guard arc.curves == 0, arc.lines > 0, !arc.isCircle else { return false }
        let direction: Double = arc.sweep >= 0 ? 1 : -1
        let step = abs(arc.sweep) / Double(arc.lines)
        func turn(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y) * direction
        }
        func bends(_ angle: Double) -> Bool { angle >= 0.75 * step && angle <= 1.35 * step }
        let first = arc.range.lowerBound
        let last = arc.range.upperBound - 1
        if first > 0, let before = elements[first - 1].endDirection,
            let along = elements[first].startDirection, bends(turn(before, along))
        {
            return true
        }
        if last + 1 < elements.count, let along = elements[last].endDirection,
            let after = elements[last + 1].startDirection, bends(turn(along, after))
        {
            return true
        }
        return false
    }

    private static func evaluate(
        _ elements: [ArcElement], _ samples: [[SIMD2<Double>]], _ range: Range<Int>,
        _ options: PDF.ArcFitting
    ) -> Evaluation {
        var points = [elements[range.lowerBound].start]
        var curves = 0
        for index in range {
            points.append(contentsOf: samples[index])
            if elements[index].isCurve { curves += 1 }
        }
        let lines = range.count - curves
        if points.count < 3 { return .provisional }
        guard let circle = Circle.fitting(points),
            circle.radius >= options.minimumRadius, circle.radius <= options.maximumRadius
        else { return .infeasible }
        let tolerance =
            curves == 0
            ? options.lineTolerance
            : max(options.tolerance, options.relativeTolerance * circle.radius)

        var worst = 0.0
        var squares = 0.0
        for point in points {
            let distance = abs(circle.deviation(of: point))
            worst = max(worst, distance)
            squares += distance * distance
        }
        guard worst <= tolerance else { return .infeasible }

        // Walk the points round the centre: the run must go one way, and not more than once round.
        let backwards = 2 * tolerance / circle.radius
        let (total, deltas) = walk(points, about: circle)
        let startAngle = atan2(points[0].y - circle.centre.y, points[0].x - circle.centre.x)
        let direction: Double = total >= 0 ? 1 : -1
        if deltas.contains(where: { $0 * direction < -backwards }) { return .infeasible }
        if abs(total) > 2 * .pi + (1 * .pi / 180) { return .infeasible }
        // A straight segment is one step (the first delta is the start's own), a curve's samples
        // are several.
        var cursor = 0
        let maximumStep = options.maximumLineStepDeg * .pi / 180
        var largest = 0.0
        var smallest = Double.infinity
        for index in range {
            let count = samples[index].count
            if !elements[index].isCurve && abs(deltas[cursor]) > maximumStep { return .infeasible }
            let sweep = abs(deltas[cursor..<(cursor + count)].reduce(0, +))
            largest = max(largest, sweep)
            smallest = min(smallest, sweep)
            cursor += count
        }

        let closes = closed(
            first: points[0], last: points[points.count - 1], sweep: total, tolerance)
        return .feasible(
            RecoveredArc(
                range: range, circle: circle, startAngle: startAngle, sweep: total,
                isCircle: closes, maxResidual: worst,
                rmsResidual: (squares / Double(points.count)).squareRoot(), curves: curves,
                lines: lines, stepRatio: smallest > 1e-12 ? largest / smallest : .infinity,
                points: points))
    }

    /// The angular steps between consecutive points about the circle's centre, each in
    /// (-pi, pi], and their sum.
    static func walk(_ points: [SIMD2<Double>], about circle: Circle) -> (
        total: Double, steps: [Double]
    ) {
        var total = 0.0
        var previous = atan2(points[0].y - circle.centre.y, points[0].x - circle.centre.x)
        var steps: [Double] = []
        steps.reserveCapacity(points.count - 1)
        for point in points.dropFirst() {
            let next = atan2(point.y - circle.centre.y, point.x - circle.centre.x)
            var delta = next - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta <= -.pi { delta += 2 * .pi }
            steps.append(delta)
            total += delta
            previous = next
        }
        return (total, steps)
    }

    /// Whether a run goes all the way round: it ends where it starts, or it is drawn past its start
    /// by a little (a circle overdrawn by a degree is still a circle, not an arc of 361 degrees).
    static func closed(
        first: SIMD2<Double>, last: SIMD2<Double>, sweep: Double, _ tolerance: Double
    ) -> Bool {
        let turn = abs(sweep)
        if turn > 2 * .pi + 1e-4 { return true }
        return distance(first, last) <= 2 * tolerance && turn >= 2 * .pi - (1 * .pi / 180)
    }

    static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }
}
