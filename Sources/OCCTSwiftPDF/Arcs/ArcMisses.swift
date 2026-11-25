// ArcMisses.swift
// OCCTSwiftPDF
//
// Spike tooling: why the reference's circles and arcs went unrecovered, and what lies at the ends of
// an arc. The reference arcs no fit matched are looked at on both sides: what the reference itself
// has at their ends (a line leaving smoothly is a fillet), and what the PDF drew along them (curves,
// chords or nothing) and at their ends.

import Foundation
import SwiftDXF

extension PDF {
    /// The place where a drawn piece stops: the point, the direction the piece leaves it in, and the
    /// piece's other end.
    struct PieceEnd {
        var point: DXF.Point2
        var direction: DXF.Point2
        var far: DXF.Point2
        var piece: Int
    }

    /// Piece ends bucketed by position.
    struct PieceEndIndex {
        let ends: [PieceEnd]
        let cell: Double
        var buckets: [Int64: [Int]] = [:]

        init(_ ends: [PieceEnd], cell: Double = 2) {
            self.ends = ends
            self.cell = cell
            for (position, end) in ends.enumerated() {
                guard let key = Self.key(end.point, cell: cell) else { continue }
                buckets[key, default: []].append(position)
            }
        }

        static func key(_ p: DXF.Point2, cell: Double) -> Int64? {
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let fx: Double = (p.x / cell).rounded(.down)
            let fy: Double = (p.y / cell).rounded(.down)
            guard abs(fx) < 1e9, abs(fy) < 1e9 else { return nil }
            return Int64(fx) &* 4_000_000_007 &+ Int64(fy)
        }

        /// The ends within `radius` of `p`.
        func near(_ p: DXF.Point2, within radius: Double) -> [PieceEnd] {
            guard p.x.isFinite, p.y.isFinite else { return [] }
            var found: [PieceEnd] = []
            let reach: Int = max(1, Int((radius / cell).rounded(.up)))
            let cx: Int = Int((p.x / cell).rounded(.down))
            let cy: Int = Int((p.y / cell).rounded(.down))
            for dx in -reach...reach {
                for dy in -reach...reach {
                    let probe = DXF.Point2(
                        (Double(cx + dx) + 0.5) * cell, (Double(cy + dy) + 0.5) * cell)
                    guard let key = Self.key(probe, cell: cell), let list = buckets[key] else {
                        continue
                    }
                    for position in list where ends[position].point.distance(to: p) <= radius {
                        found.append(ends[position])
                    }
                }
            }
            return found
        }
    }

    /// The ends of every line, open polyline, spline and arc of `drawing`, placed by `transform`.
    ///
    /// A polyline's end counts only where its end segment is straight, and a spline's direction is
    /// that of its first or last control polygon edge.
    static func pieceEnds(_ drawing: DXF.Drawing, transform: Similarity?) -> [PieceEnd] {
        var ends: [PieceEnd] = []
        func place(_ q: DXF.Point) -> DXF.Point2 {
            let r = DXF.Point2(q.x, q.y)
            return transform?.apply(r) ?? r
        }
        func add(_ at: DXF.Point2, toward: DXF.Point2, far: DXF.Point2, piece: Int) {
            let dx: Double = toward.x - at.x
            let dy: Double = toward.y - at.y
            let length: Double = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9, length.isFinite, at.x.isFinite, at.y.isFinite else { return }
            ends.append(
                PieceEnd(
                    point: at, direction: DXF.Point2(dx / length, dy / length), far: far,
                    piece: piece))
        }
        for (index, entity) in drawing.entities.enumerated() {
            switch entity {
            case .line(let a, let b, _, _):
                add(place(a), toward: place(b), far: place(b), piece: index)
                add(place(b), toward: place(a), far: place(a), piece: index)
            case .polyline(let vertices, let closed, _, _):
                guard vertices.count >= 2 else { continue }
                // Every vertex is a place another piece can leave from: a line, an arc and a line
                // are often stroked as one polyline, so the arc's neighbour is the next segment of
                // the same polyline. A segment with a bulge is left out.
                let n: Int = vertices.count
                for i in 0..<n {
                    let here = place(vertices[i].point)
                    if i + 1 < n || closed {
                        let next = (i + 1) % n
                        if abs(vertices[i].bulge) < 1e-12 {
                            let there = place(vertices[next].point)
                            add(here, toward: there, far: there, piece: index)
                        }
                    }
                    if i > 0 || closed {
                        let before = (i + n - 1) % n
                        if abs(vertices[before].bulge) < 1e-12 {
                            let there = place(vertices[before].point)
                            add(here, toward: there, far: there, piece: index)
                        }
                    }
                }
            case .spline(let spline):
                let points: [DXF.Point2] = spline.controlPoints.map(place)
                guard let first = points.first, let last = points.last, points.count >= 2 else {
                    continue
                }
                if let next = points.dropFirst().first(where: { $0.distance(to: first) > 1e-9 }) {
                    add(first, toward: next, far: last, piece: index)
                }
                if let before = points.dropLast().reversed().first(where: {
                    $0.distance(to: last) > 1e-9
                }) {
                    add(last, toward: before, far: first, piece: index)
                }
            case .arc(let c, let r, let a, let b, _, _):
                let turn: Double = transform.map { $0.rotation * 180 / Double.pi } ?? 0
                let scale: Double = transform?.scale ?? 1
                let centre = place(c)
                let radius: Double = r * scale
                let s: Double = (a + turn) * Double.pi / 180
                let e: Double = (b + turn) * Double.pi / 180
                let start = DXF.Point2(centre.x + radius * cos(s), centre.y + radius * sin(s))
                let end = DXF.Point2(centre.x + radius * cos(e), centre.y + radius * sin(e))
                ends.append(
                    PieceEnd(
                        point: start, direction: DXF.Point2(-sin(s), cos(s)), far: end, piece: index
                    ))
                ends.append(
                    PieceEnd(
                        point: end, direction: DXF.Point2(sin(e), -cos(e)), far: start, piece: index
                    ))
            default:
                break
            }
        }
        return ends
    }

    /// How many of an arc's two ends meet another piece, and how many of those meet it smoothly.
    public struct EndContacts: Sendable, Equatable {
        /// Ends where another piece starts within the join distance.
        public var met: Int
        /// Of those, ends where the piece leaves in the arc's own direction, within 3 degrees.
        public var tangent: Int
    }

    /// The contacts at the two ends of the arc from `startDeg` to `endDeg` (counterclockwise).
    ///
    /// A piece whose far end lies on the same circle is the arc continuing, not a neighbour.
    static func endContacts(
        centre: DXF.Point2, radius: Double, startDeg: Double, endDeg: Double,
        in index: PieceEndIndex, excluding piece: Int?, join: Double
    ) -> EndContacts {
        let cosLimit: Double = cos(3 * Double.pi / 180)
        var met = 0
        var tangent = 0
        for forward in [false, true] {
            let degrees: Double = forward ? endDeg : startDeg
            let angle: Double = degrees * Double.pi / 180
            let point = DXF.Point2(centre.x + radius * cos(angle), centre.y + radius * sin(angle))
            // Beyond the end of the arc, the way it was going.
            let outward: DXF.Point2 =
                forward ? DXF.Point2(-sin(angle), cos(angle)) : DXF.Point2(sin(angle), -cos(angle))
            var touched = false
            var smooth = false
            for end in index.near(point, within: join) {
                if let piece, end.piece == piece { continue }
                let off: Double = abs(end.far.distance(to: centre) - radius)
                if off <= 0.05 { continue }
                touched = true
                let dot: Double = end.direction.x * outward.x + end.direction.y * outward.y
                if dot >= cosLimit { smooth = true }
            }
            if touched { met += 1 }
            if smooth { tangent += 1 }
        }
        return EndContacts(met: met, tangent: tangent)
    }

    /// The contacts at the ends of each fit of `fitted` with the other pieces of the page's own
    /// drawing, in order; a circle has none.
    public static func fitContacts(
        _ fitted: FittedDrawing, on page: Page, join: Double = 0.2
    ) -> [EndContacts] {
        let index = PieceEndIndex(pieceEnds(page.drawing(), transform: nil))
        return fitted.fits.map { fit in
            guard fit.shape == .arc else { return EndContacts(met: 0, tangent: 0) }
            return endContacts(
                centre: DXF.Point2(fit.center.x, fit.center.y), radius: fit.radius,
                startDeg: fit.startDeg, endDeg: fit.endDeg, in: index, excluding: nil, join: join)
        }
    }

    /// A circle or arc of the reference that no fit matched, with what the reference has at its ends
    /// and what the PDF drew along it and at its ends.
    public struct MissedArc: Sendable {
        /// Position in the reference drawing's `entities`.
        public var reference: Int
        /// The reference is a whole circle.
        public var isCircle: Bool
        /// In millimetres on the paper.
        public var radius: Double
        /// 360 for a circle.
        public var sweepDeg: Double
        /// Contacts at its ends with the reference's other pieces.
        public var referenceContacts: EndContacts
        /// Contacts at its ends with the PDF's pieces.
        public var pdfContacts: EndContacts
        /// The fraction of points along it within 0.1 mm of any geometry of the PDF's drawing.
        public var support: Double
        /// The fraction of its sweep covered by pieces of the PDF that lie on its circle.
        public var covered: Double
        /// How many of those pieces are curves.
        public var curves: Int
        /// How many straight segments those pieces hold.
        public var lines: Int
        /// The largest sweep of one curve, or of one straight segment, of those pieces, in degrees.
        public var widestPiece: Double
        /// The most straight segments in a row, in one piece, that lie on the circle.
        public var longestRun: Int
    }

    /// A piece of the PDF's drawing, flattened, with its box.
    private struct FlatPiece {
        var points: [DXF.Point2]
        var isCurve: Bool
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
    }

    /// The reference's circles and arcs that no fit matched, looked at against the page's drawing.
    ///
    /// `comparison` says which they are. `join` is how near another piece's end must be to count as meeting the arc's end.
    public static func missedArcs(
        on page: Page, comparison: ArcComparison, reference: DXF.Drawing,
        placedBy location: Placement, join: Double = 0.2
    ) -> [MissedArc] {
        let placement = Similarity(
            scale: location.scale, rotation: location.rotationDeg * .pi / 180,
            tx: location.translationX, ty: location.translationY)
        let drawing = page.drawing()
        let referenceEnds = PieceEndIndex(pieceEnds(reference, transform: placement))
        let pdfEnds = PieceEndIndex(pieceEnds(drawing, transform: nil))
        let index = SegmentIndex(segments(drawing, transform: nil), cell: 1)

        // The pieces of the PDF's drawing, flattened, in a grid by their boxes.
        var pieces: [FlatPiece] = []
        for entity in drawing.entities {
            var points: [DXF.Point2] = []
            var curve = false
            switch entity {
            case .line(let a, let b, _, _):
                points = [DXF.Point2(a.x, a.y), DXF.Point2(b.x, b.y)]
            case .polyline(let vertices, let closed, _, _):
                points = vertices.map { DXF.Point2($0.point.x, $0.point.y) }
                if closed, let first = points.first { points.append(first) }
            case .spline(let spline):
                points = spline.flattened(tolerance: 0.01).map { DXF.Point2($0.x, $0.y) }
                curve = true
            default:
                continue
            }
            points = points.filter { $0.x.isFinite && $0.y.isFinite }
            guard points.count >= 2 else { continue }
            var box = FlatPiece(
                points: points, isCurve: curve, minX: .infinity, minY: .infinity,
                maxX: -.infinity, maxY: -.infinity)
            for q in points {
                box.minX = min(box.minX, q.x)
                box.minY = min(box.minY, q.y)
                box.maxX = max(box.maxX, q.x)
                box.maxY = max(box.maxY, q.y)
            }
            pieces.append(box)
        }
        let cell = 4.0
        var grid: [Int64: [Int]] = [:]
        var large: [Int] = []
        for (position, piece) in pieces.enumerated() {
            let x0 = Int((piece.minX / cell).rounded(.down))
            let x1 = Int((piece.maxX / cell).rounded(.down))
            let y0 = Int((piece.minY / cell).rounded(.down))
            let y1 = Int((piece.maxY / cell).rounded(.down))
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 2_500 {
                large.append(position)
                continue
            }
            for x in x0...x1 {
                for y in y0...y1 {
                    let probe = DXF.Point2((Double(x) + 0.5) * cell, (Double(y) + 0.5) * cell)
                    if let key = PieceEndIndex.key(probe, cell: cell) {
                        grid[key, default: []].append(position)
                    }
                }
            }
        }

        func normalised(_ degrees: Double) -> Double {
            var d = degrees.truncatingRemainder(dividingBy: 360)
            if d < 0 { d += 360 }
            return d
        }

        var missed: [MissedArc] = []
        for round in comparison.unmatchedReference {
            let centre = DXF.Point2(round.center.x, round.center.y)
            let radius: Double = round.radius
            guard radius.isFinite, radius > 0, centre.x.isFinite, centre.y.isFinite else {
                continue
            }
            let isCircle = round.spanDeg == nil
            let startDeg: Double = round.spanDeg?[0] ?? 0
            let sweep: Double = round.spanDeg.map { normalised($0[1] - $0[0]) } ?? 360
            let sweepDeg: Double = (sweep == 0 && !isCircle) ? 360 : sweep

            // Contacts at the ends.
            var refContacts = EndContacts(met: 0, tangent: 0)
            var pdfContacts = EndContacts(met: 0, tangent: 0)
            if !isCircle, let span = round.spanDeg {
                refContacts = endContacts(
                    centre: centre, radius: radius, startDeg: span[0], endDeg: span[1],
                    in: referenceEnds, excluding: nil, join: join)
                pdfContacts = endContacts(
                    centre: centre, radius: radius, startDeg: span[0], endDeg: span[1],
                    in: pdfEnds, excluding: nil, join: join)
            }

            // Support along the arc: points every 0.1 mm against the PDF's geometry.
            let length: Double = sweepDeg * Double.pi / 180 * radius
            let count = max(8, min(2_000, Int((length / 0.1).rounded(.up))))
            var near = 0
            for step in 0..<count {
                let along: Double = (Double(step) + 0.5) / Double(count)
                let angle: Double = (startDeg + sweepDeg * along) * Double.pi / 180
                let point = DXF.Point2(
                    centre.x + radius * cos(angle), centre.y + radius * sin(angle))
                if index.distance(from: point, within: 0.5) <= 0.1 { near += 1 }
            }
            let support: Double = Double(near) / Double(count)

            // The pieces of the PDF that lie on this circle, inside the arc's span.
            var lo = centre.x - radius
            var hi = centre.x + radius
            var lo2 = centre.y - radius
            var hi2 = centre.y + radius
            if !isCircle {
                lo = .infinity
                hi = -.infinity
                lo2 = .infinity
                hi2 = -.infinity
                let samples = max(2, Int((sweepDeg / 5).rounded(.up)))
                for i in 0...samples {
                    let angle: Double =
                        (startDeg + sweepDeg * Double(i) / Double(samples)) * .pi / 180
                    let x: Double = centre.x + radius * cos(angle)
                    let y: Double = centre.y + radius * sin(angle)
                    lo = min(lo, x)
                    hi = max(hi, x)
                    lo2 = min(lo2, y)
                    hi2 = max(hi2, y)
                }
            }
            var candidates = Set(large)
            let gx0 = Int(((lo - 0.2) / cell).rounded(.down))
            let gx1 = Int(((hi + 0.2) / cell).rounded(.down))
            let gy0 = Int(((lo2 - 0.2) / cell).rounded(.down))
            let gy1 = Int(((hi2 + 0.2) / cell).rounded(.down))
            if (gx1 - gx0 + 1) * (gy1 - gy0 + 1) <= 250_000 {
                for x in gx0...gx1 {
                    for y in gy0...gy1 {
                        let probe = DXF.Point2((Double(x) + 0.5) * cell, (Double(y) + 0.5) * cell)
                        if let key = PieceEndIndex.key(probe, cell: cell), let list = grid[key] {
                            candidates.formUnion(list)
                        }
                    }
                }
            }

            var intervals: [(Double, Double)] = []
            var curves = 0
            var lines = 0
            var widest = 0.0
            var longestRun = 0
            for position in candidates {
                let piece = pieces[position]
                guard piece.maxX >= lo - 0.2, piece.minX <= hi + 0.2, piece.maxY >= lo2 - 0.2,
                    piece.minY <= hi2 + 0.2
                else { continue }
                // Each vertex: on the circle, and where in the span.
                var offsets: [Double] = []
                var usable: [Bool] = []
                for q in piece.points {
                    let d: Double = q.distance(to: centre)
                    var offset: Double = normalised(
                        atan2(q.y - centre.y, q.x - centre.x) * 180 / Double.pi - startDeg)
                    if offset > 359 { offset -= 360 }
                    offsets.append(offset)
                    usable.append(abs(d - radius) <= 0.05 && (isCircle || offset <= sweepDeg + 1))
                }
                // Each segment lies on the circle when both ends do and, for a straight one, its
                // middle is where a chord of that sweep puts it.
                var onSegment: [Bool] = []
                var sweeps: [Double] = []
                var places: [(Double, Double)] = []
                for i in 0..<(piece.points.count - 1) {
                    var delta: Double = offsets[i + 1] - offsets[i]
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    var on = usable[i] && usable[i + 1]
                    if on && !piece.isCurve {
                        let a = piece.points[i]
                        let b = piece.points[i + 1]
                        let mid = DXF.Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
                        let expected: Double = radius * cos(abs(delta) * Double.pi / 360)
                        on = abs(mid.distance(to: centre) - expected) <= 0.05
                    }
                    onSegment.append(on)
                    sweeps.append(abs(delta))
                    places.append((delta >= 0 ? offsets[i] : offsets[i + 1], abs(delta)))
                }
                // A curve counts whole or not at all; a run of straight segments by its segments.
                if piece.isCurve {
                    guard onSegment.allSatisfy({ $0 }), !onSegment.isEmpty else { continue }
                    curves += 1
                    widest = max(widest, sweeps.reduce(0, +))
                } else {
                    guard onSegment.contains(true) else { continue }
                    var run = 0
                    for (i, on) in onSegment.enumerated() where on {
                        lines += 1
                        widest = max(widest, sweeps[i])
                    }
                    for on in onSegment {
                        run = on ? run + 1 : 0
                        longestRun = max(longestRun, run)
                    }
                }
                for (i, on) in onSegment.enumerated() where on {
                    let from: Double = places[i].0
                    let span: Double = places[i].1
                    if from + span > 360 {
                        intervals.append((from, 360))
                        intervals.append((0, from + span - 360))
                    } else {
                        intervals.append((from, from + span))
                    }
                }
            }
            // The union of the intervals, clipped to the span.
            var covered = 0.0
            var reach = -Double.infinity
            for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
                let s: Double = max(0, start)
                let e: Double = min(sweepDeg, end)
                guard e > s else { continue }
                let from: Double = max(s, reach)
                if e > from { covered += e - from }
                reach = max(reach, e)
            }

            missed.append(
                MissedArc(
                    reference: round.index, isCircle: isCircle, radius: radius, sweepDeg: sweepDeg,
                    referenceContacts: refContacts, pdfContacts: pdfContacts, support: support,
                    covered: min(1, covered / sweepDeg), curves: curves, lines: lines,
                    widestPiece: widest, longestRun: longestRun))
        }
        return missed
    }
}
