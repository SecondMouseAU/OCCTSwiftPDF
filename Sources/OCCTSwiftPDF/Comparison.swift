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
        /// The PDF drawing's samples farther than `tolerance` from the reference's geometry, by
        /// layer and entity type (`"0 SPLINE"`), to tell what the reference does not have.
        public var pdfUncovered: [String: Int]
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
        // In key order, so the robust fit's sampling sees the same list every run.
        var pairs: [(from: DXF.Point2, to: DXF.Point2)] = []
        for key in refUnique.keys.sorted() {
            if let ref = refUnique[key], let pdf = pdfUnique[key] { pairs.append((ref.at, pdf.at)) }
        }
        // Many values repeat on a sheet, so some texts that occur once in each drawing are
        // different texts that happen to match. Take the transform that most anchors agree with:
        // fitted to each pair of anchors, kept where the most land within 2 mm on the paper.
        guard pairs.count >= 2, var fit = Similarity.robustFit(pairs, within: 2) else {
            return nil
        }
        var used = pairs.filter { fit.apply($0.from).distance(to: $0.to) <= 2 }
        if used.count >= 2, let refit = Similarity.fit(used) { fit = refit }
        used = pairs.filter { fit.apply($0.from).distance(to: $0.to) <= 2 }
        guard used.count >= 2 else { return nil }
        let residual = sqrt(
            used.map { pow(fit.apply($0.from).distance(to: $0.to), 2) }.reduce(0, +)
                / Double(used.count))

        let step = 0.25
        let radius = max(tolerance * 10, 2)
        let pdfSegments = segments(drawing, transform: nil)
        let pdfIndex = SegmentIndex(pdfSegments, cell: radius)
        // Texts are placed by different reference points in different formats, so refine the fit
        // on the geometry: match reference samples to their nearest PDF geometry and refit.
        // The reference is in its own units: sample it at the paper step through the fitted scale.
        let refRaw = segments(reference, transform: nil, units: fit.scale)
        let rawSamples = samples(refRaw, step: step / fit.scale)
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
                reference, fit: fit, index: pdfIndex, step: step, tolerance: tolerance),
            pdfUncovered: uncovered(
                drawing, fit: Similarity(scale: 1, rotation: 0, tx: 0, ty: 0), index: refIndex,
                step: step, tolerance: tolerance))
    }

    /// A drawing's samples, placed by `fit`, that are farther than `tolerance` from the geometry in
    /// `index`, entity by entity, keyed by layer and type.
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

    /// The layer an entity is on, for leaving layers out of a comparison.
    public static func describe(layerOf entity: DXF.Entity) -> String { describe(entity).layer }

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

}
