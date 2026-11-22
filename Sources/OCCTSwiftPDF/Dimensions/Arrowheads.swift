// Arrowheads.swift
// OCCTSwiftPDF
//
// The arrowheads of a PDF's dimension lines are filled paths with no stroke, which `drawing()`
// leaves out (they are `skipped["FILL"]`). The dimension rebuild can use them: an arrowhead's tip
// is where a dimension line ends when nothing else marks the end. Here a filled path that is
// nothing but small triangles gives each triangle's tip as a point, which SwiftDXF's rebuild takes
// as the end of a dimension line, wherever no other piece already ends it.

import CoreGraphics
import Foundation
import SwiftDXF

extension PDF.Page {
    /// The longest side an arrowhead may have, in millimetres on the paper.
    ///
    /// SwiftDXF then takes only those no longer than twice the median value text height.
    static let largestArrowhead = 10.0

    /// How near a piece that crosses the dimension line must pass to a tip for the end to be
    /// marked already, in millimetres on the paper.
    static let arrowheadSupport = 0.5

    /// An arrowhead: where it points to, and the way it points.
    struct Arrowhead {
        var tip: DXF.Point2
        /// The unit vector from the base of the arrowhead to its tip.
        var direction: DXF.Point2
    }

    /// The working drawing of a dimension rebuild: the page's `drawing()` and, with `arrowheads`,
    /// the tip of each arrowhead that is the only mark of its end, added as a point.
    ///
    /// An arrowhead is a triangle of a filled-only path. A path counts only when every one of its
    /// subpaths is such a triangle, so the outlines of glyphs a writer drew as shapes (whose
    /// counters can be triangles) are not taken for arrowheads. The triangle is as the page draws
    /// it: three corners, with a vertex that lies on the line between its neighbours (the dart some
    /// writers draw has one on its base) dropped. The tip is the corner between its two longer,
    /// nearly equal sides; a triangle that is not narrow like an arrow has none and is left out.
    ///
    /// A tip is added only where no piece that crosses its line passes near it. Where an extension
    /// line, or an edge of the part, already ends the dimension line, the arrowhead says nothing
    /// new, and an extra mark there only gives the rebuild more spans to explain a value by chance.
    func workingDrawing(arrowheads: Bool) -> DXF.Drawing {
        var out = drawing()
        guard arrowheads else { return out }
        let transform = toPaper
        var found: [(Arrowhead, PDF.Path, Int)] = []
        for path in paths where path.paint == .fill {
            let triangles = path.subpaths.map { Self.triangle($0, transform) }
            guard !triangles.isEmpty, triangles.allSatisfy({ $0 != nil }) else { continue }
            for (piece, corners) in triangles.enumerated() {
                if let corners, let arrowhead = Self.arrowhead(of: corners) {
                    found.append((arrowhead, path, piece))
                }
            }
        }
        guard !found.isEmpty else { return out }
        let crossing = Self.straightPieces(out)
        // Setting `entities` clears the parallel arrays, so both are set together at the end.
        var entities = out.entities
        var identities = out.identities
        for (arrowhead, path, piece) in found
        where !Self.isMarked(arrowhead, by: crossing) {
            entities.append(
                .point(
                    at: DXF.Point(arrowhead.tip.x, arrowhead.tip.y), layer: path.layer ?? "0",
                    color: Self.aci(path.fillColour)))
            let source = path.source
            identities.append(
                DXF.Identity(
                    locator: "p\(source.page):op\(source.operatorIndex):\(piece)",
                    via: source.forms,
                    blocks: source.forms.map { String($0.split(separator: "#").first ?? "") }))
            out.counts.point += 1
        }
        out.entities = entities
        out.identities = identities
        return out
    }

    /// The three corners, in millimetres on the paper, of a subpath that is a small triangle, or
    /// `nil`.
    ///
    /// Straight segments only; closed by `h` or by the fill. A last point equal to the first is the
    /// closing line, and a vertex on the line between its neighbours is dropped.
    static func triangle(_ subpath: PDF.Subpath, _ transform: CGAffineTransform) -> [DXF.Point]? {
        var corners = [subpath.start.applying(transform)]
        for segment in subpath.segments {
            guard case .line(let to) = segment else { return nil }
            corners.append(to.applying(transform))
        }
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= 1e-6 }
        // The closing line: a point equal to the start at the end, and runs of equal points.
        var distinct: [CGPoint] = []
        for corner in corners where distinct.last.map({ !same($0, corner) }) ?? true {
            distinct.append(corner)
        }
        if distinct.count > 1, let first = distinct.first, let last = distinct.last,
            same(first, last)
        {
            distinct.removeLast()
        }
        // A vertex on the straight line between its neighbours is not a corner.
        var changed = true
        while changed, distinct.count > 3 {
            changed = false
            for i in distinct.indices {
                let a = distinct[(i + distinct.count - 1) % distinct.count]
                let b = distinct[i]
                let c = distinct[(i + 1) % distinct.count]
                let base = hypot(c.x - a.x, c.y - a.y)
                let area = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
                if base > 0, area / base <= 1e-3 {
                    distinct.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        guard distinct.count == 3 else { return nil }
        let sides = (0..<3).map {
            hypot(
                distinct[$0].x - distinct[($0 + 1) % 3].x, distinct[$0].y - distinct[($0 + 1) % 3].y
            )
        }
        guard let longest = sides.max(), longest > 1e-6, longest <= largestArrowhead else {
            return nil
        }
        return distinct.map { DXF.Point($0.x, $0.y) }
    }

    /// The arrowhead whose corners are `corners`: the tip is the corner between the two longest
    /// sides when they are within 15 percent of each other and the third, the base, is at most 0.8
    /// of them; otherwise `nil`.
    static func arrowhead(of corners: [DXF.Point]) -> Arrowhead? {
        guard corners.count == 3 else { return nil }
        let sides = (0..<3).map {
            hypot(
                corners[$0].x - corners[($0 + 1) % 3].x, corners[$0].y - corners[($0 + 1) % 3].y)
        }
        // Side `base` joins corners `base` and `base + 1`, so the tip is corner `base + 2`.
        guard let base = sides.indices.min(by: { sides[$0] < sides[$1] }) else { return nil }
        let legs = [sides[(base + 1) % 3], sides[(base + 2) % 3]]
        guard let long = legs.max(), let short = legs.min(), long > 0,
            short >= 0.85 * long, sides[base] <= 0.8 * short
        else { return nil }
        let tip = corners[(base + 2) % 3]
        let a = corners[base]
        let b = corners[(base + 1) % 3]
        let middle = DXF.Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
        let length = hypot(tip.x - middle.x, tip.y - middle.y)
        guard length > 0 else { return nil }
        return Arrowhead(
            tip: DXF.Point2(tip.x, tip.y),
            direction: DXF.Point2((tip.x - middle.x) / length, (tip.y - middle.y) / length))
    }

    /// The straight pieces of a drawing (lines and the straight edges of polylines), indexed by
    /// place.
    ///
    /// Curves are left out: SwiftDXF takes an end from a straight piece that crosses the dimension
    /// line, and an arrowhead beside a curve is still the only mark of its end.
    static func straightPieces(_ drawing: DXF.Drawing) -> PDF.SegmentIndex {
        var pieces: [(DXF.Point2, DXF.Point2)] = []
        for entity in drawing.entities {
            switch entity {
            case .line(let a, let b, _, _):
                pieces.append((DXF.Point2(a.x, a.y), DXF.Point2(b.x, b.y)))
            case .polyline(let vertices, let closed, _, _):
                let points = vertices.map { DXF.Point2($0.point.x, $0.point.y) }
                for i in 0..<max(0, points.count - 1) where vertices[i].bulge == 0 {
                    pieces.append((points[i], points[i + 1]))
                }
                if closed, points.count > 2, vertices[points.count - 1].bulge == 0 {
                    pieces.append((points[points.count - 1], points[0]))
                }
            default:
                break
            }
        }
        return PDF.SegmentIndex(pieces, cell: 5)
    }

    /// Whether a piece that crosses the arrowhead's line (its angle to the way the arrowhead points
    /// at least about 17 degrees: the dimension line itself runs that way) passes near the tip.
    static func isMarked(_ arrowhead: Arrowhead, by pieces: PDF.SegmentIndex) -> Bool {
        pieces.passes(near: arrowhead.tip, within: arrowheadSupport) { a, b in
            let length = a.distance(to: b)
            guard length > 1e-9 else { return false }
            let ux = (b.x - a.x) / length
            let uy = (b.y - a.y) / length
            return abs(ux * arrowhead.direction.y - uy * arrowhead.direction.x) >= 0.3
        }
    }
}
