// Comparison.swift
// OCCTSwiftPDF
//
// Spike tooling: how closely a PDF page's drawing matches the DXF of the same drawing, by
// coordinates. The DXF is placed on the paper by a similarity transform fitted to the texts the
// two have in common, then each drawing's geometry is sampled and measured against the other's.

import Foundation
import SwiftDXF

extension PDF {
    /// How a PDF drawing compares with a reference drawing of the same sheet.
    public struct Comparison: Sendable {
        /// Texts that occur exactly once in each drawing, used to place the reference.
        public var anchors: Int
        /// Anchors kept after outliers were dropped.
        public var anchorsUsed: Int
        /// Reference units to paper millimetres.
        public var scale: Double
        public var rotationDeg: Double
        /// Root mean square distance of the kept anchors after the text fit, in paper millimetres.
        public var anchorResidual: Double
        /// Root mean square distance of the matched geometry after the fit is refined on it.
        public var geometryResidual: Double
        /// The fraction of the reference's sampled geometry within `tolerance` of the PDF's.
        public var referenceCovered: Double
        /// The fraction of the PDF's sampled geometry within `tolerance` of the reference's.
        public var pdfCovered: Double
        /// Distances from reference samples to the PDF geometry, at the 50th, 90th and 99th
        /// percentiles, in paper millimetres (capped at the search radius).
        public var referenceDistances: [Double]
        public var tolerance: Double
        /// Reference texts whose string is found in the PDF within 2 mm of the placed position.
        public var textsMatched: Int
        public var referenceTexts: Int
        public var referenceSamples: Int
        public var pdfSamples: Int
        /// Reference samples farther than `tolerance` from the PDF's geometry, by the layer and
        /// entity type they come from (`"15 LINE"`), to tell what the PDF is missing.
        public var uncovered: [String: Int]
    }

    /// Compare `drawing` (from a PDF page, in paper millimetres) with `reference` (the same sheet
    /// from a DXF, JWW or DWG, in any units), or `nil` when fewer than two texts are in common.
    public static func compare(
        _ drawing: DXF.Drawing, with reference: DXF.Drawing, tolerance: Double = 0.2
    ) -> Comparison? {
        let pdfTexts = texts(drawing)
        let refTexts = texts(reference)
        let pdfUnique = Dictionary(grouping: pdfTexts, by: \.key).compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }
        let refUnique = Dictionary(grouping: refTexts, by: \.key).compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }
        var pairs: [(from: DXF.Point2, to: DXF.Point2)] = []
        for (key, ref) in refUnique {
            if let pdf = pdfUnique[key] { pairs.append((ref.at, pdf.at)) }
        }
        guard pairs.count >= 2, var fit = Similarity.fit(pairs) else { return nil }
        var used = pairs
        // Drop anchors far from the fit (text placed by different alignment points), twice.
        for _ in 0..<2 {
            let residuals = used.map { fit.apply($0.from).distance(to: $0.to) }
            let median = residuals.sorted()[residuals.count / 2]
            let kept = zip(used, residuals).filter { $0.1 <= max(3 * median, 0.5) }.map(\.0)
            guard kept.count >= 2, let refit = Similarity.fit(kept) else { break }
            used = kept
            fit = refit
        }
        let residual = sqrt(
            used.map { pow(fit.apply($0.from).distance(to: $0.to), 2) }.reduce(0, +)
                / Double(used.count))

        let step = 0.25
        let radius = max(tolerance * 10, 2)
        let pdfSegments = segments(drawing, transform: nil)
        let pdfIndex = SegmentIndex(pdfSegments, cell: radius)
        // Texts are placed by different reference points in different formats, so refine the fit
        // on the geometry: match reference samples to their nearest PDF geometry and refit.
        let refRaw = segments(reference, transform: nil)
        let rawSamples = samples(refRaw, step: step)
        let stride = max(1, rawSamples.count / 20_000)
        let probe = Swift.stride(from: 0, to: rawSamples.count, by: stride).map { rawSamples[$0] }
        var refinedResidual = residual
        for pass in 0..<6 {
            let reach = pass < 2 ? 1.0 : 0.5
            var matched: [(from: DXF.Point2, to: DXF.Point2)] = []
            for sample in probe {
                if let near = pdfIndex.nearest(from: fit.apply(sample), within: reach) {
                    matched.append((sample, near))
                }
            }
            guard matched.count >= 10, let refit = Similarity.fit(matched) else { break }
            fit = refit
            refinedResidual = sqrt(
                matched.map { pow(refit.apply($0.from).distance(to: $0.to), 2) }.reduce(0, +)
                    / Double(matched.count))
        }
        let refSegments = segments(reference, transform: fit)
        let refIndex = SegmentIndex(refSegments, cell: radius)
        let refSamples = samples(refSegments, step: step)
        let pdfSamples = samples(pdfSegments, step: step)
        let refDistances = refSamples.map { pdfIndex.distance(from: $0, within: radius) }
        let pdfDistances = pdfSamples.map { refIndex.distance(from: $0, within: radius) }

        var matched = 0
        let pdfByKey = Dictionary(grouping: pdfTexts, by: \.key)
        for ref in refTexts {
            let placed = fit.apply(ref.at)
            if pdfByKey[ref.key]?.contains(where: { $0.at.distance(to: placed) <= 2 }) == true {
                matched += 1
            }
        }
        let sorted = refDistances.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return Comparison(
            anchors: pairs.count, anchorsUsed: used.count, scale: fit.scale,
            rotationDeg: fit.rotation * 180 / .pi, anchorResidual: residual,
            geometryResidual: refinedResidual,
            referenceCovered: fraction(refDistances, tolerance),
            pdfCovered: fraction(pdfDistances, tolerance),
            referenceDistances: [percentile(0.5), percentile(0.9), percentile(0.99)],
            tolerance: tolerance, textsMatched: matched, referenceTexts: refTexts.count,
            referenceSamples: refSamples.count, pdfSamples: pdfSamples.count,
            uncovered: uncovered(
                reference, fit: fit, index: pdfIndex, step: step, tolerance: tolerance))
    }

    /// The reference's uncovered samples, entity by entity, keyed by layer and type.
    static func uncovered(
        _ reference: DXF.Drawing, fit: Similarity, index: SegmentIndex, step: Double,
        tolerance: Double
    ) -> [String: Int] {
        var out: [String: Int] = [:]
        for entity in reference.entities {
            let (layer, type) = describe(entity)
            let one = DXF.Drawing(entities: [entity])
            let missing = samples(segments(one, transform: fit), step: step)
                .filter { index.distance(from: $0, within: tolerance * 2) > tolerance }.count
            if missing > 0 { out["\(layer) \(type)", default: 0] += missing }
        }
        return out
    }

    static func describe(_ entity: DXF.Entity) -> (layer: String, type: String) {
        switch entity {
        case .line(_, _, let layer, _): (layer, "LINE")
        case .circle(_, _, let layer, _): (layer, "CIRCLE")
        case .arc(_, _, _, _, let layer, _): (layer, "ARC")
        case .ellipse(_, _, _, _, _, let layer, _): (layer, "ELLIPSE")
        case .polyline(_, _, let layer, _): (layer, "POLYLINE")
        case .spline(let spline): (spline.layer, "SPLINE")
        case .text(_, _, _, _, let layer, _): (layer, "TEXT")
        case .point(_, let layer, _): (layer, "POINT")
        default: ("?", "OTHER")
        }
    }

    private static func fraction(_ distances: [Double], _ tolerance: Double) -> Double {
        distances.isEmpty
            ? 0 : Double(distances.filter { $0 <= tolerance }.count) / Double(distances.count)
    }

    struct PlacedText {
        var key: String
        var at: DXF.Point2
    }

    /// Texts with their whitespace removed, so the same value written differently still pairs.
    static func texts(_ drawing: DXF.Drawing) -> [PlacedText] {
        drawing.entities.compactMap { entity in
            guard case .text(let at, _, _, let string, _, _) = entity else { return nil }
            let key = string.filter { !$0.isWhitespace }
            return key.isEmpty ? nil : PlacedText(key: key, at: DXF.Point2(at.x, at.y))
        }
    }

    /// Every drawn piece as straight segments: arcs, circles, bulges and splines are sampled.
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
        return out
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

    /// A 2D similarity transform: scale, rotation and translation.
    struct Similarity: Sendable {
        var scale: Double
        var rotation: Double
        var tx: Double
        var ty: Double

        func apply(_ p: DXF.Point2) -> DXF.Point2 {
            let c = cos(rotation) * scale
            let s = sin(rotation) * scale
            return DXF.Point2(c * p.x - s * p.y + tx, s * p.x + c * p.y + ty)
        }

        /// The least-squares similarity taking each `from` to its `to` (Umeyama, in 2D).
        static func fit(_ pairs: [(from: DXF.Point2, to: DXF.Point2)]) -> Similarity? {
            let n = Double(pairs.count)
            let fx = pairs.map(\.from.x).reduce(0, +) / n
            let fy = pairs.map(\.from.y).reduce(0, +) / n
            let tx = pairs.map(\.to.x).reduce(0, +) / n
            let ty = pairs.map(\.to.y).reduce(0, +) / n
            var sxx = 0.0
            var sxy = 0.0
            var spread = 0.0
            for (from, to) in pairs {
                let ax = from.x - fx
                let ay = from.y - fy
                let bx = to.x - tx
                let by = to.y - ty
                sxx += ax * bx + ay * by
                sxy += ax * by - ay * bx
                spread += ax * ax + ay * ay
            }
            guard spread > 1e-12 else { return nil }
            let rotation = atan2(sxy, sxx)
            let scale = hypot(sxx, sxy) / spread
            let c = cos(rotation) * scale
            let s = sin(rotation) * scale
            return Similarity(
                scale: scale, rotation: rotation, tx: tx - (c * fx - s * fy),
                ty: ty - (s * fx + c * fy))
        }
    }

    /// Segments bucketed by the cells their bounding boxes touch.
    struct SegmentIndex {
        let cell: Double
        let segments: [(DXF.Point2, DXF.Point2)]
        var buckets: [Int64: [Int]] = [:]

        init(_ segments: [(DXF.Point2, DXF.Point2)], cell: Double) {
            self.cell = cell
            self.segments = segments
            for (index, (a, b)) in segments.enumerated() {
                let x0 = Int64(floor(min(a.x, b.x) / cell))
                let x1 = Int64(floor(max(a.x, b.x) / cell))
                let y0 = Int64(floor(min(a.y, b.y) / cell))
                let y1 = Int64(floor(max(a.y, b.y) / cell))
                guard (x1 - x0 + 1) * (y1 - y0 + 1) < 100_000 else { continue }
                for x in x0...x1 {
                    for y in y0...y1 { buckets[Self.key(x, y), default: []].append(index) }
                }
            }
        }

        static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 ^ (y & 0xFFFF_FFFF) }

        /// The nearest point on any segment, when one is within `radius`.
        func nearest(from p: DXF.Point2, within radius: Double) -> DXF.Point2? {
            var best = radius
            var found: DXF.Point2?
            let cx = Int64(floor(p.x / cell))
            let cy = Int64(floor(p.y / cell))
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
            var best = radius
            let cx = Int64(floor(p.x / cell))
            let cy = Int64(floor(p.y / cell))
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
