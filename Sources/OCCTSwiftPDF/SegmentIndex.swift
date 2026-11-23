// SegmentIndex.swift
// OCCTSwiftPDF
//
// Segments bucketed by position, for nearest-segment queries: the comparison's, and the dimension
// rebuild's, which asks whether a piece passes near the tip of an arrowhead.

import Foundation
import SwiftDXF

extension PDF {
    /// Segments bucketed by the cells they pass through.
    ///
    /// A query looks in the point's cell and the eight around it. With a segment recorded every
    /// half cell along its length, that finds every segment within three quarters of a cell of
    /// the point (1.5 mm for the comparison's 2 mm cells, against its 0.2 mm tolerance and 1 mm
    /// fitting reach); a segment farther off can be missed, which only shows in distances near
    /// the search radius, reported as the radius.
    struct SegmentIndex {
        let cell: Double
        let segments: [(DXF.Point2, DXF.Point2)]
        var buckets: [Int64: [Int]] = [:]

        init(_ segments: [(DXF.Point2, DXF.Point2)], cell: Double) {
            self.cell = cell
            self.segments = segments
            for (index, (a, b)) in segments.enumerated() {
                // The cells along the segment, every half cell: a long diagonal touches a few
                // thousand cells, not every cell of its bounding box. A segment off the grid's
                // range, or longer than a million cells, is left out.
                let length = a.distance(to: b)
                guard length.isFinite, length / cell <= 1_000_000 else { continue }
                let steps = max(1, Int((length / (cell / 2)).rounded(.up)))
                var previous: Int64?
                for step in 0...steps {
                    let t = Double(step) / Double(steps)
                    guard let x = cellIndex(a.x + (b.x - a.x) * t),
                        let y = cellIndex(a.y + (b.y - a.y) * t)
                    else { continue }
                    let key = Self.key(x, y)
                    if key != previous { buckets[key, default: []].append(index) }
                    previous = key
                }
            }
        }

        static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 ^ (y & 0xFFFF_FFFF) }

        /// The cell a coordinate falls in, or `nil` for a coordinate that is not finite or is too
        /// far out for the grid (beyond a billion cells from the origin).
        func cellIndex(_ value: Double) -> Int64? {
            let index = (value / cell).rounded(.down)
            guard index.isFinite, abs(index) < 1e9 else { return nil }
            return Int64(index)
        }

        /// The nearest point on any segment, when one is within `radius`.
        func nearest(from p: DXF.Point2, within radius: Double) -> DXF.Point2? {
            guard let cx = cellIndex(p.x), let cy = cellIndex(p.y) else { return nil }
            var best = radius
            var found: DXF.Point2?
            for x in (cx - 1)...(cx + 1) {
                for y in (cy - 1)...(cy + 1) {
                    for index in buckets[Self.key(x, y)] ?? [] {
                        let (a, b) = segments[index]
                        let q = Self.closest(p, a, b)
                        let d = p.distance(to: q)
                        if d < best {
                            best = d
                            found = q
                        }
                    }
                }
            }
            return found
        }

        /// Whether a segment that `accepts` passes within `radius` of `p`.
        func passes(
            near p: DXF.Point2, within radius: Double,
            where accepts: (DXF.Point2, DXF.Point2) -> Bool
        ) -> Bool {
            guard let cx = cellIndex(p.x), let cy = cellIndex(p.y) else { return false }
            for x in (cx - 1)...(cx + 1) {
                for y in (cy - 1)...(cy + 1) {
                    for index in buckets[Self.key(x, y)] ?? [] {
                        let (a, b) = segments[index]
                        if Self.distance(p, a, b) <= radius, accepts(a, b) { return true }
                    }
                }
            }
            return false
        }

        static func closest(_ p: DXF.Point2, _ a: DXF.Point2, _ b: DXF.Point2) -> DXF.Point2 {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            guard length2 > 1e-18 else { return a }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
            return DXF.Point2(a.x + dx * t, a.y + dy * t)
        }

        /// The distance to the nearest segment, or `radius` when none is that close.
        func distance(from p: DXF.Point2, within radius: Double) -> Double {
            guard let cx = cellIndex(p.x), let cy = cellIndex(p.y) else { return radius }
            var best = radius
            var seen = Set<Int>()
            for x in (cx - 1)...(cx + 1) {
                for y in (cy - 1)...(cy + 1) {
                    for index in buckets[Self.key(x, y)] ?? [] where seen.insert(index).inserted {
                        let (a, b) = segments[index]
                        best = min(best, Self.distance(p, a, b))
                    }
                }
            }
            return best
        }

        static func distance(_ p: DXF.Point2, _ a: DXF.Point2, _ b: DXF.Point2) -> Double {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            guard length2 > 1e-18 else { return p.distance(to: a) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
            return p.distance(to: DXF.Point2(a.x + dx * t, a.y + dy * t))
        }
    }
}
