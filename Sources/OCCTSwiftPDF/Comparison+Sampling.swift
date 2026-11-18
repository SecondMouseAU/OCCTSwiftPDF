// Comparison+Sampling.swift
// OCCTSwiftPDF
//
// Spike tooling: drawings as straight segments, and points along them at a fixed step.

import Foundation
import SwiftDXF

extension PDF {
    /// Every drawn piece as straight segments: arcs, circles, bulges and splines are sampled.
    ///
    /// Segments with a coordinate that is not finite are left out. SwiftDXF's own
    /// `SegmentExtractor` does this sampling for contours but is internal; this spike tooling keeps
    /// its own copy until the comparison moves out of the package or SwiftDXF makes it public.
    static func segments(_ drawing: DXF.Drawing, transform: Similarity?) -> [(
        DXF.Point2, DXF.Point2
    )] {
        var out: [(DXF.Point2, DXF.Point2)] = []
        func p(_ point: DXF.Point) -> DXF.Point2 {
            let q = DXF.Point2(point.x, point.y)
            return transform?.apply(q) ?? q
        }
        func chain(_ points: [DXF.Point2]) {
            for (a, b) in zip(points, points.dropFirst()) { out.append((a, b)) }
        }
        func arc(_ c: DXF.Point, _ r: Double, _ start: Double, _ sweep: Double) {
            let n = max(8, Int(abs(sweep) / (.pi / 90)))
            chain(
                (0...n).map { i in
                    let t = start + sweep * Double(i) / Double(n)
                    return p(DXF.Point(c.x + r * cos(t), c.y + r * sin(t)))
                })
        }
        for entity in drawing.entities {
            switch entity {
            case .line(let a, let b, _, _):
                out.append((p(a), p(b)))
            case .circle(let c, let r, _, _):
                arc(c, r, 0, 2 * .pi)
            case .arc(let c, let r, let s, let e, _, _):
                var sweep = (e - s).truncatingRemainder(dividingBy: 360)
                if sweep <= 0 { sweep += 360 }
                arc(c, r, s * .pi / 180, sweep * .pi / 180)
            case .polyline(let vertices, let closed, _, _):
                let ring = closed && vertices.count > 2 ? vertices + [vertices[0]] : vertices
                for (v, w) in zip(ring, ring.dropFirst()) {
                    if abs(v.bulge) < 1e-12 {
                        out.append((p(v.point), p(w.point)))
                    } else {
                        bulge(v.point, w.point, v.bulge, into: &out, p)
                    }
                }
            case .spline(let spline):
                chain(spline.flattened(tolerance: 0.01).map(p))
            case .ellipse(let c, let major, let ratio, let s, let e, _, _):
                let a = hypot(major.x, major.y)
                let angle = atan2(major.y, major.x)
                var sweep = e - s
                if sweep <= 0 { sweep += 2 * .pi }
                let n = max(16, Int(sweep / (.pi / 90)))
                chain(
                    (0...n).map { i in
                        let t = s + sweep * Double(i) / Double(n)
                        let x = a * cos(t)
                        let y = a * ratio * sin(t)
                        return p(
                            DXF.Point(
                                c.x + x * cos(angle) - y * sin(angle),
                                c.y + x * sin(angle) + y * cos(angle)))
                    })
            default:
                break
            }
        }
        return out.filter { a, b in
            a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite
        }
    }

    private static func bulge(
        _ a: DXF.Point, _ b: DXF.Point, _ bulge: Double, into out: inout [(DXF.Point2, DXF.Point2)],
        _ p: (DXF.Point) -> DXF.Point2
    ) {
        // The sweep is signed, counterclockwise positive; the centre sits off the chord's midpoint
        // along its left normal by (chord / 2) / tan(sweep / 2), which changes side past a half
        // turn and for a clockwise arc.
        let sweep = 4 * atan(bulge)
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord > 1e-12 else { return }
        let r = abs(chord / (2 * sin(sweep / 2)))
        let offset = chord / 2 / tan(sweep / 2)
        let nx = -(b.y - a.y) / chord
        let ny = (b.x - a.x) / chord
        let c = DXF.Point((a.x + b.x) / 2 + nx * offset, (a.y + b.y) / 2 + ny * offset)
        let start = atan2(a.y - c.y, a.x - c.x)
        let n = max(4, Int(abs(sweep) / (.pi / 90)))
        var previous = p(a)
        for i in 1...n {
            let t = start + sweep * Double(i) / Double(n)
            let next = p(DXF.Point(c.x + r * cos(t), c.y + r * sin(t)))
            out.append((previous, next))
            previous = next
        }
    }

    /// Points every `step` along the segments, carried on from one segment to the next where
    /// they join, so a curve drawn as many short segments is sampled as densely as a long line.
    static func samples(_ segments: [(DXF.Point2, DXF.Point2)], step: Double) -> [DXF.Point2] {
        var out: [DXF.Point2] = []
        var next = step / 2
        var previousEnd: DXF.Point2?
        for (a, b) in segments {
            if let end = previousEnd, end.distance(to: a) > 1e-9 { next = step / 2 }
            let length = a.distance(to: b)
            while next < length {
                let t = next / length
                out.append(DXF.Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                next += step
            }
            next -= length
            previousEnd = b
        }
        return out
    }

}
