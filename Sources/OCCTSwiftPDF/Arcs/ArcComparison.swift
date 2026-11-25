// ArcComparison.swift
// OCCTSwiftPDF
//
// Spike tooling: how the circles and arcs recovered from a PDF compare with the circles and arcs
// of a reference drawing of the same sheet (a DXF, or a JWW read as one), by coordinates: the
// reference is placed on the paper by the same similarity `compare` fitted, and each fit is matched
// to the reference circle or arc nearest it in centre and radius.

import Foundation
import SwiftDXF

extension PDF {
    /// A recovered circle or arc paired with the reference circle or arc it stands for.
    public struct ArcMatch: Sendable {
        /// Position in ``FittedDrawing/fits``.
        public var fit: Int
        /// Position in the reference drawing's `entities`.
        public var reference: Int
        /// The fit's radius less the reference's, in millimetres on the paper.
        public var radiusError: Double
        /// The distance between the centres, in millimetres on the paper.
        public var centreError: Double
        /// The reference is a whole circle.
        public var referenceIsCircle: Bool
        /// For two arcs, the larger distance between their start points and between their end
        /// points, in millimetres on the paper; `nil` when either is a whole circle.
        public var endpointError: Double?
    }

    /// A circle or arc of the reference, placed on the paper.
    public struct ReferenceRound: Sendable {
        /// Position in the reference drawing's `entities`.
        public var index: Int
        public var center: DXF.Point
        public var radius: Double
        /// Counterclockwise from the first to the second, in degrees; `nil` for a whole circle.
        public var spanDeg: [Double]?
    }

    /// Recovered circles and arcs against the reference's.
    public struct ArcComparison: Sendable {
        /// Matched pairs: the centres and the radii agree within the bound asked for, and for arcs
        /// the angles overlap.
        public var matches: [ArcMatch]
        /// Positions in ``FittedDrawing/fits`` of circles centred on a `POINT` of the reference.
        ///
        /// Jw_cad prints each point as a small circle, so these are circles the PDF has and the
        /// reference holds as points.
        public var pointMarkers: [Int]
        /// Positions in ``FittedDrawing/fits`` of fits with no such reference circle or arc.
        ///
        /// A fit the reference does not have, so possibly a circle that was never there.
        public var unmatchedFits: [Int]
        /// Circles and arcs in the reference.
        public var referenceCount: Int
        /// For each fit, in order, the fraction of points along it that lie within 0.1 mm (on the
        /// paper) of any geometry of the reference, whatever its type: near 1 for a circle the
        /// reference draws as a polyline or a spline, near 0 for one it does not have.
        public var support: [Double]
        /// The reference's circles and arcs no fit matched, placed on the paper.
        public var unmatchedReference: [ReferenceRound]
        /// The bound used, in millimetres on the paper.
        public var bound: Double
    }

    /// Match the circles and arcs of `fitted` (from a page of the PDF) with those of `reference`,
    /// which `location` (``Comparison/placement`` from `compare(_:with:)` on the same two drawings)
    /// placed on the paper.
    ///
    /// A fit matches the reference circle or arc whose centre and radius are nearest, if both are
    /// within `bound` millimetres on the paper and, where both are arcs, the angles overlap. The
    /// matching is not one to one: a reference arc that two fits share is matched by both. Every
    /// fit is tried against every reference circle and arc, so the cost is the product of their
    /// numbers: this is spike tooling, not for a sheet of tens of thousands.
    public static func compareArcs(
        _ fitted: FittedDrawing, with reference: DXF.Drawing, placedBy location: Placement,
        within bound: Double = 0.5
    ) -> ArcComparison {
        let placement = Similarity(
            scale: location.scale, rotation: location.rotationDeg * .pi / 180,
            tx: location.translationX, ty: location.translationY)
        struct Round {
            var index: Int
            var centre: DXF.Point2
            var radius: Double
            /// Counterclockwise from `start` to `end`, in degrees; `nil` for a whole circle.
            var span: (start: Double, end: Double)?
        }
        var rounds: [Round] = []
        var points: [DXF.Point2] = []
        for (index, entity) in reference.entities.enumerated() {
            switch entity {
            case .point(let p, _, _):
                points.append(placement.apply(DXF.Point2(p.x, p.y)))
            case .circle(let c, let r, _, _):
                rounds.append(
                    Round(
                        index: index, centre: placement.apply(DXF.Point2(c.x, c.y)),
                        radius: r * placement.scale, span: nil))
            case .arc(let c, let r, let a, let b, _, _):
                let turn = placement.rotation * 180 / .pi
                rounds.append(
                    Round(
                        index: index, centre: placement.apply(DXF.Point2(c.x, c.y)),
                        radius: r * placement.scale,
                        span: (Page.normalised(a + turn), Page.normalised(b + turn))))
            default: break
            }
        }

        /// The counterclockwise angle from `a` to `b`, in degrees from 0 to 360.
        func ccw(_ a: Double, _ b: Double) -> Double { Page.normalised(b - a) }
        /// Whether two counterclockwise spans share an angle.
        func overlap(_ a: (start: Double, end: Double), _ b: (start: Double, end: Double)) -> Bool {
            let lengthB = ccw(b.start, b.end)
            return ccw(b.start, a.start) <= lengthB || ccw(a.start, b.start) <= ccw(a.start, a.end)
        }
        func endPoint(_ centre: DXF.Point2, _ radius: Double, _ deg: Double) -> DXF.Point2 {
            let angle: Double = deg * Double.pi / 180
            let x: Double = centre.x + radius * cos(angle)
            let y: Double = centre.y + radius * sin(angle)
            return DXF.Point2(x, y)
        }
        func endPoint(of fit: ArcFit, _ deg: Double) -> DXF.Point2 {
            let point = fit.point(atDeg: deg)
            return DXF.Point2(point.x, point.y)
        }

        // Points every 0.1 mm along each fit, against all of the reference's geometry.
        let index = SegmentIndex(segments(reference, transform: placement), cell: 1)
        let support: [Double] = fitted.fits.map {
            Self.support(
                centre: DXF.Point2($0.center.x, $0.center.y), radius: $0.radius,
                startDeg: $0.startDeg, sweepDeg: $0.sweepDeg, in: index)
        }

        var matches: [ArcMatch] = []
        var unmatched: [Int] = []
        var markers: [Int] = []
        var matchedReference = Set<Int>()
        for (position, fit) in fitted.fits.enumerated() {
            let centre = DXF.Point2(fit.center.x, fit.center.y)
            var best: (round: Round, score: Double)?
            for round in rounds {
                let centreError = centre.distance(to: round.centre)
                let radiusError = abs(fit.radius - round.radius)
                guard centreError <= bound, radiusError <= bound else { continue }
                if fit.shape == .arc, let span = round.span,
                    !overlap((fit.startDeg, fit.endDeg), span)
                {
                    continue
                }
                let score = centreError + radiusError
                if score < (best?.score ?? .infinity) { best = (round, score) }
            }
            guard let (round, _) = best else {
                if fit.shape == .circle,
                    points.contains(where: { $0.distance(to: centre) <= bound })
                {
                    markers.append(position)
                } else {
                    unmatched.append(position)
                }
                continue
            }
            matchedReference.insert(round.index)
            var endpointError: Double?
            if fit.shape == .arc, let span = round.span {
                let fitStart = endPoint(of: fit, fit.startDeg)
                let fitEnd = endPoint(of: fit, fit.endDeg)
                let refStart = endPoint(round.centre, round.radius, span.start)
                let refEnd = endPoint(round.centre, round.radius, span.end)
                endpointError = max(fitStart.distance(to: refStart), fitEnd.distance(to: refEnd))
            }
            matches.append(
                ArcMatch(
                    fit: position, reference: round.index,
                    radiusError: fit.radius - round.radius,
                    centreError: centre.distance(to: round.centre),
                    referenceIsCircle: round.span == nil, endpointError: endpointError))
        }
        return ArcComparison(
            matches: matches, pointMarkers: markers, unmatchedFits: unmatched,
            referenceCount: rounds.count,
            support: support,
            unmatchedReference: rounds.filter { !matchedReference.contains($0.index) }.map {
                ReferenceRound(
                    index: $0.index, center: DXF.Point($0.centre.x, $0.centre.y), radius: $0.radius,
                    spanDeg: $0.span.map { [$0.start, $0.end] })
            },
            bound: bound)
    }

    /// The fraction of points every 0.1 mm along the arc from `startDeg` for `sweepDeg` that lie
    /// within 0.1 mm of the geometry in `index`.
    static func support(
        centre: DXF.Point2, radius: Double, startDeg: Double, sweepDeg: Double,
        in index: SegmentIndex
    ) -> Double {
        let length: Double = sweepDeg * Double.pi / 180 * radius
        guard length.isFinite else { return 0 }
        let count = max(8, min(2_000, Int((length / 0.1).rounded(.up))))
        var near = 0
        for step in 0..<count {
            let along: Double = (Double(step) + 0.5) / Double(count)
            let angle: Double = (startDeg + sweepDeg * along) * Double.pi / 180
            let point = DXF.Point2(centre.x + radius * cos(angle), centre.y + radius * sin(angle))
            if index.distance(from: point, within: 0.5) <= 0.1 { near += 1 }
        }
        return Double(near) / Double(count)
    }
}
