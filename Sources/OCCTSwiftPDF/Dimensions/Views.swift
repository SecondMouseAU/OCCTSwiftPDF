// Views.swift
// OCCTSwiftPDF
//
// Splits a page's drawing into views: groups of pieces that lie together on the sheet, apart from
// the other groups. A sheet can hold views at different scales (a detail beside the main view), and
// a PDF has no layer groups to say so, so the scale of each is looked for among its own values.

import Foundation
import SwiftDXF

extension PDF {
    /// The views of a drawing: for each entity the view it belongs to, and each view's extent.
    struct Views: Sendable {
        /// The view of each entity of the drawing, numbered from 0 in order of first entity.
        var of: [Int]
        /// The extent of each view's pieces, in the drawing's units.
        var bounds: [DXF.Box2]

        var count: Int { bounds.count }

        /// Entities whose cells touch (8-connected cells of `cell` units) are one view, so views
        /// are told apart by a clear gap between `cell` and twice `cell` wide.
        ///
        /// A line is covered by points at most half a cell apart, so it marks a connected run of
        /// cells; a text is its baseline. The cost is the number of such points, whatever the
        /// drawing's size. With `merged` the whole drawing is one view.
        init(_ drawing: DXF.Drawing, cell: Double, merged: Bool = false) {
            let size = cell > 0 && cell.isFinite ? cell : 1
            var parent = Array(0..<drawing.entities.count)
            func find(_ i: Int) -> Int {
                var i = i
                while parent[i] != i {
                    parent[i] = parent[parent[i]]
                    i = parent[i]
                }
                return i
            }
            var owner: [Int64: Int] = [:]
            func key(_ x: Int, _ y: Int) -> Int64 { SegmentIndex.key(Int64(x), Int64(y)) }
            func cellIndex(_ v: Double) -> Int {
                Int(max(-2e9, min(2e9, (v / size).rounded(.down))))
            }
            var lo = [DXF.Point2](
                repeating: DXF.Point2(.infinity, .infinity), count: drawing.entities.count)
            var hi = [DXF.Point2](
                repeating: DXF.Point2(-.infinity, -.infinity), count: drawing.entities.count)
            for (index, entity) in drawing.entities.enumerated() {
                for p in Self.ink(entity, step: size / 2) where p.x.isFinite && p.y.isFinite {
                    lo[index] = DXF.Point2(min(lo[index].x, p.x), min(lo[index].y, p.y))
                    hi[index] = DXF.Point2(max(hi[index].x, p.x), max(hi[index].y, p.y))
                    let (cx, cy) = (cellIndex(p.x), cellIndex(p.y))
                    if owner[key(cx, cy)] == nil { owner[key(cx, cy)] = index }
                    for dx in -1...1 {
                        for dy in -1...1 {
                            if let other = owner[key(cx + dx, cy + dy)] {
                                parent[find(index)] = find(other)
                            }
                        }
                    }
                }
            }
            if merged {
                for index in drawing.entities.indices.dropFirst() { parent[find(index)] = find(0) }
            }
            var number: [Int: Int] = [:]
            var of: [Int] = []
            var extent: [DXF.Box2] = []
            for index in drawing.entities.indices {
                let root = find(index)
                let view = number[root] ?? number.count
                if number[root] == nil {
                    number[root] = view
                    extent.append(
                        DXF.Box2(
                            min: DXF.Point2(.infinity, .infinity),
                            max: DXF.Point2(-.infinity, -.infinity)))
                }
                of.append(view)
                extent[view].min = DXF.Point2(
                    min(extent[view].min.x, lo[index].x), min(extent[view].min.y, lo[index].y))
                extent[view].max = DXF.Point2(
                    max(extent[view].max.x, hi[index].x), max(extent[view].max.y, hi[index].y))
            }
            self.of = of
            self.bounds = extent
        }

        /// Points along an entity at most `step` apart, which is where it leaves ink.
        ///
        /// A segment longer than 4,096 steps is covered more coarsely, so a stray huge coordinate
        /// cannot make the work unbounded.
        static func ink(_ entity: DXF.Entity, step: Double) -> [DXF.Point2] {
            func along(_ a: DXF.Point2, _ b: DXF.Point2) -> [DXF.Point2] {
                let length = a.distance(to: b)
                guard length.isFinite else { return [] }
                // The count is capped before it is an `Int`, which a huge length would trap on.
                let n = Int(min(4_096, max(1, (length / step).rounded(.up))))
                return (0...n).map {
                    let t = Double($0) / Double(n)
                    return DXF.Point2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                }
            }
            func chain(_ points: [DXF.Point2], closed: Bool) -> [DXF.Point2] {
                var out: [DXF.Point2] = []
                for i in 0..<max(0, points.count - 1) { out += along(points[i], points[i + 1]) }
                if closed, points.count > 2 { out += along(points[points.count - 1], points[0]) }
                return out
            }
            switch entity {
            case .line(let a, let b, _, _):
                return along(DXF.Point2(a.x, a.y), DXF.Point2(b.x, b.y))
            case .point(let at, _, _):
                return [DXF.Point2(at.x, at.y)]
            case .polyline(let vertices, let closed, _, _):
                return chain(vertices.map { DXF.Point2($0.point.x, $0.point.y) }, closed: closed)
            case .spline(let spline):
                return chain(spline.controlPoints.map { DXF.Point2($0.x, $0.y) }, closed: false)
            case .text(let at, let height, let rotation, let string, _, _):
                let radians = rotation * .pi / 180
                let length = Double(string.count) * 0.6 * height
                let start = DXF.Point2(at.x, at.y)
                let end = DXF.Point2(
                    at.x + cos(radians) * length, at.y + sin(radians) * length)
                return along(start, end)
            default:
                return []
            }
        }
    }
}
