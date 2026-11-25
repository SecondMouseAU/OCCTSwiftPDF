// ArcMisses.swift
// OCCTSwiftPDF
//
// Spike tooling: why the reference's circles and arcs went unrecovered. A reference arc no fit
// matched is looked at on both sides: what the reference itself has at its ends (a line leaving
// smoothly is a fillet), and what the PDF drew along it (curves, chords or nothing) and at its
// ends.

import Foundation
import SwiftDXF

extension PDF {
    /// A circle or arc of the reference that no fit matched, with what the reference has at its
    /// ends and what the PDF drew along it and at its ends.
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

        /// The lines, polylines and splines of `drawing`, flattened; anything else is left out.
        static func pieces(of drawing: DXF.Drawing) -> [FlatPiece] {
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
                var piece = FlatPiece(
                    points: points, isCurve: curve, minX: .infinity, minY: .infinity,
                    maxX: -.infinity, maxY: -.infinity)
                for q in points {
                    piece.minX = min(piece.minX, q.x)
                    piece.minY = min(piece.minY, q.y)
                    piece.maxX = max(piece.maxX, q.x)
                    piece.maxY = max(piece.maxY, q.y)
                }
                pieces.append(piece)
            }
            return pieces
        }
    }

    /// Flat pieces in a grid by the cells their boxes cover, for the pieces near an arc.
    private struct PieceGrid {
        let cell = 4.0
        var cells: [Int64: [Int]] = [:]
        /// Pieces whose box covers too many cells to list in each.
        var large: [Int] = []

        init(_ pieces: [FlatPiece]) {
            for (position, piece) in pieces.enumerated() {
                guard let x0 = PieceEndIndex.index(piece.minX, cell: cell),
                    let x1 = PieceEndIndex.index(piece.maxX, cell: cell),
                    let y0 = PieceEndIndex.index(piece.minY, cell: cell),
                    let y1 = PieceEndIndex.index(piece.maxY, cell: cell)
                else { continue }
                if Double(x1 - x0 + 1) * Double(y1 - y0 + 1) > 2_500 {
                    large.append(position)
                    continue
                }
                for x in x0...x1 {
                    for y in y0...y1 {
                        cells[PieceEndIndex.key(x, y), default: []].append(position)
                    }
                }
            }
        }

        /// The pieces in a cell next to a point along the arc, and the large ones.
        func near(centre: DXF.Point2, radius: Double, startDeg: Double, sweepDeg: Double)
            -> Set<Int>
        {
            var found = Set(large)
            let length: Double = sweepDeg * Double.pi / 180 * radius
            guard length.isFinite else { return found }
            let steps = max(2, Int(min(20_000, (length / (cell / 2)).rounded(.up))))
            for step in 0...steps {
                let along: Double = Double(step) / Double(steps)
                let angle: Double = (startDeg + sweepDeg * along) * Double.pi / 180
                let x: Double = centre.x + radius * cos(angle)
                let y: Double = centre.y + radius * sin(angle)
                guard let cx = PieceEndIndex.index(x, cell: cell),
                    let cy = PieceEndIndex.index(y, cell: cell)
                else { continue }
                for dx in -1...1 {
                    for dy in -1...1 {
                        if let list = cells[PieceEndIndex.key(cx + dx, cy + dy)] {
                            found.formUnion(list)
                        }
                    }
                }
            }
            return found
        }
    }

    /// The box of an arc from `startDeg` for `sweepDeg`, in millimetres.
    private static func arcBox(
        centre: DXF.Point2, radius: Double, startDeg: Double, sweepDeg: Double
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var box = (
            minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity,
            maxY: -Double.infinity
        )
        func add(_ degrees: Double) {
            let angle: Double = degrees * Double.pi / 180
            let x: Double = centre.x + radius * cos(angle)
            let y: Double = centre.y + radius * sin(angle)
            box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
        }
        add(startDeg)
        add(startDeg + sweepDeg)
        var quarter: Double = (startDeg / 90).rounded(.up) * 90
        while quarter <= startDeg + sweepDeg {
            add(quarter)
            quarter += 90
        }
        return box
    }

    /// What the pieces `candidates` of `pieces` hold on the circle, inside the arc's span.
    private static func onCircle(
        _ pieces: [FlatPiece], _ candidates: Set<Int>, centre: DXF.Point2, radius: Double,
        startDeg: Double, sweepDeg: Double, isCircle: Bool
    ) -> (covered: Double, curves: Int, lines: Int, widest: Double, longestRun: Int) {
        let box = arcBox(centre: centre, radius: radius, startDeg: startDeg, sweepDeg: sweepDeg)
        // As far off the circle as a fit allows (0.0004 of the radius, where that is more).
        let onTolerance: Double = max(0.05, 0.0004 * radius)
        var intervals: [(Double, Double)] = []
        var curves = 0
        var lines = 0
        var widest = 0.0
        var longestRun = 0
        for position in candidates {
            let piece = pieces[position]
            guard piece.maxX >= box.minX - 0.2, piece.minX <= box.maxX + 0.2,
                piece.maxY >= box.minY - 0.2, piece.minY <= box.maxY + 0.2
            else { continue }
            // Each vertex: on the circle, and where in the span.
            var offsets: [Double] = []
            var usable: [Bool] = []
            for q in piece.points {
                let d: Double = q.distance(to: centre)
                var offset: Double = Page.normalised(
                    atan2(q.y - centre.y, q.x - centre.x) * 180 / Double.pi - startDeg)
                if offset > 359 { offset -= 360 }
                offsets.append(offset)
                usable.append(
                    abs(d - radius) <= onTolerance && (isCircle || offset <= sweepDeg + 1))
            }
            // Each segment lies on the circle when both ends do and, for a straight one, its
            // middle is where a chord of that sweep puts it.
            var onSegment: [Bool] = []
            var sweeps: [Double] = []
            var places: [(from: Double, span: Double)] = []
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
                    on = abs(mid.distance(to: centre) - expected) <= onTolerance
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
                let (from, span) = places[i]
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
        return (min(1, covered / sweepDeg), curves, lines, widest, longestRun)
    }

    /// The reference's circles and arcs that no fit matched, looked at against the page's drawing.
    ///
    /// `comparison` says which they are. `join` is how near another piece's end must be to count as
    /// meeting the arc's end. A piece is counted along an arc where its vertices are within 0.05 mm
    /// (0.0004 of the radius, where that is more) of the circle and inside the span; a whole
    /// circle's span is the circle.
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
        let pieces = FlatPiece.pieces(of: drawing)
        let grid = PieceGrid(pieces)

        var missed: [MissedArc] = []
        for round in comparison.unmatchedReference {
            let centre = DXF.Point2(round.center.x, round.center.y)
            let radius: Double = round.radius
            guard radius.isFinite, radius > 0, centre.x.isFinite, centre.y.isFinite else {
                continue
            }
            let isCircle = round.spanDeg == nil
            let startDeg: Double = round.spanDeg?[0] ?? 0
            let sweep: Double = round.spanDeg.map { Page.normalised($0[1] - $0[0]) } ?? 360
            let sweepDeg: Double = (sweep == 0 && !isCircle) ? 360 : sweep

            var refContacts = EndContacts(met: 0, tangent: 0)
            var pdfContacts = EndContacts(met: 0, tangent: 0)
            if let span = round.spanDeg {
                refContacts = endContacts(
                    centre: centre, radius: radius, startDeg: span[0], endDeg: span[1],
                    in: referenceEnds, join: join)
                pdfContacts = endContacts(
                    centre: centre, radius: radius, startDeg: span[0], endDeg: span[1],
                    in: pdfEnds, join: join)
            }
            let support = Self.support(
                centre: centre, radius: radius, startDeg: startDeg, sweepDeg: sweepDeg, in: index)
            let candidates = grid.near(
                centre: centre, radius: radius, startDeg: startDeg, sweepDeg: sweepDeg)
            let along = onCircle(
                pieces, candidates, centre: centre, radius: radius, startDeg: startDeg,
                sweepDeg: sweepDeg, isCircle: isCircle)
            missed.append(
                MissedArc(
                    reference: round.index, isCircle: isCircle, radius: radius, sweepDeg: sweepDeg,
                    referenceContacts: refContacts, pdfContacts: pdfContacts, support: support,
                    covered: along.covered, curves: along.curves, lines: along.lines,
                    widestPiece: along.widest, longestRun: along.longestRun))
        }
        return missed
    }
}
