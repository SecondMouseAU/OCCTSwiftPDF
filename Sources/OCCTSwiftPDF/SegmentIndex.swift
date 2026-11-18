// SegmentIndex.swift
// OCCTSwiftPDF
//
// Spike tooling: segments bucketed by position, for nearest-segment queries.

import Foundation
import SwiftDXF

extension PDF {
    /// Segments bucketed by the cells their bounding boxes touch.
    struct SegmentIndex {
        let cell: Double
        let segments: [(DXF.Point2, DXF.Point2)]
        var buckets: [Int64: [Int]] = [:]

        init(_ segments: [(DXF.Point2, DXF.Point2)], cell: Double) {
            self.cell = cell
            self.segments = segments
            for (index, (a, b)) in segments.enumerated() {
                // A segment off the grid's range, or touching too many cells, is left out.
                guard let x0 = cellIndex(min(a.x, b.x)), let x1 = cellIndex(max(a.x, b.x)),
                    let y0 = cellIndex(min(a.y, b.y)), let y1 = cellIndex(max(a.y, b.y)),
                    Double(x1 - x0 + 1) * Double(y1 - y0 + 1) < 100_000
                else { continue }
                for x in x0...x1 {
                    for y in y0...y1 { buckets[Self.key(x, y), default: []].append(index) }
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
