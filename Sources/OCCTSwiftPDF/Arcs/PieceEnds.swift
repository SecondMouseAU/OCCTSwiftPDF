// PieceEnds.swift
// OCCTSwiftPDF
//
// Spike tooling: where drawn pieces stop and which way they leave, to see what meets the ends of an
// arc. A line that leaves an arc's end in the arc's own direction is a fillet's neighbour.

import Foundation
import SwiftDXF

extension PDF {
    /// The place where a drawn piece stops: the point, the direction the piece leaves it in, and the
    /// piece's other end.
    struct PieceEnd {
        var point: DXF.Point2
        var direction: DXF.Point2
        var far: DXF.Point2
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
                guard let x = Self.index(end.point.x, cell: cell),
                    let y = Self.index(end.point.y, cell: cell)
                else { continue }
                buckets[Self.key(x, y), default: []].append(position)
            }
        }

        /// The cell `value` is in, or `nil` where it is not finite or too far out to count cells.
        static func index(_ value: Double, cell: Double) -> Int? {
            let floor: Double = (value / cell).rounded(.down)
            guard floor.isFinite, abs(floor) < 1e9 else { return nil }
            return Int(floor)
        }

        static func key(_ x: Int, _ y: Int) -> Int64 {
            Int64(x) &* 4_000_000_007 &+ Int64(y)
        }

        /// The ends within `radius` of `p`.
        func near(_ p: DXF.Point2, within radius: Double) -> [PieceEnd] {
            guard radius.isFinite, radius >= 0, radius <= 1_000,
                let cx = Self.index(p.x, cell: cell), let cy = Self.index(p.y, cell: cell)
            else { return [] }
            var found: [PieceEnd] = []
            let reach: Int = max(1, Int((radius / cell).rounded(.up)))
            for dx in -reach...reach {
                for dy in -reach...reach {
                    guard let list = buckets[Self.key(cx + dx, cy + dy)] else { continue }
                    for position in list where ends[position].point.distance(to: p) <= radius {
                        found.append(ends[position])
                    }
                }
            }
            return found
        }
    }

    /// The ends of every line, polyline, spline and arc of `drawing`, placed by `transform`.
    ///
    /// Every vertex of a polyline counts, since a line, an arc and a line are often stroked as one
    /// polyline and the arc's neighbour is then the next segment of it; a segment with a bulge is
    /// left out. A spline's direction is that of its first or last control polygon edge.
    static func pieceEnds(_ drawing: DXF.Drawing, transform: Similarity?) -> [PieceEnd] {
        var ends: [PieceEnd] = []
        func place(_ q: DXF.Point) -> DXF.Point2 {
            let r = DXF.Point2(q.x, q.y)
            return transform?.apply(r) ?? r
        }
        func add(_ at: DXF.Point2, toward: DXF.Point2, far: DXF.Point2) {
            let dx: Double = toward.x - at.x
            let dy: Double = toward.y - at.y
            let length: Double = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9, length.isFinite, at.x.isFinite, at.y.isFinite else { return }
            ends.append(
                PieceEnd(point: at, direction: DXF.Point2(dx / length, dy / length), far: far))
        }
        for entity in drawing.entities {
            switch entity {
            case .line(let a, let b, _, _):
                add(place(a), toward: place(b), far: place(b))
                add(place(b), toward: place(a), far: place(a))
            case .polyline(let vertices, let closed, _, _):
                guard vertices.count >= 2 else { continue }
                let n: Int = vertices.count
                for i in 0..<n {
                    let here = place(vertices[i].point)
                    if i + 1 < n || closed, abs(vertices[i].bulge) < 1e-12 {
                        let there = place(vertices[(i + 1) % n].point)
                        add(here, toward: there, far: there)
                    }
                    let before = (i + n - 1) % n
                    if i > 0 || closed, abs(vertices[before].bulge) < 1e-12 {
                        let there = place(vertices[before].point)
                        add(here, toward: there, far: there)
                    }
                }
            case .spline(let spline):
                let points: [DXF.Point2] = spline.controlPoints.map(place)
                guard let first = points.first, let last = points.last, points.count >= 2 else {
                    continue
                }
                if let next = points.dropFirst().first(where: { $0.distance(to: first) > 1e-9 }) {
                    add(first, toward: next, far: last)
                }
                if let before = points.dropLast().reversed().first(where: {
                    $0.distance(to: last) > 1e-9
                }) {
                    add(last, toward: before, far: first)
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
                    PieceEnd(point: start, direction: DXF.Point2(-sin(s), cos(s)), far: end))
                ends.append(
                    PieceEnd(point: end, direction: DXF.Point2(sin(e), -cos(e)), far: start))
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
        in index: PieceEndIndex, join: Double
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
                startDeg: fit.startDeg, endDeg: fit.endDeg, in: index, join: join)
        }
    }
}
