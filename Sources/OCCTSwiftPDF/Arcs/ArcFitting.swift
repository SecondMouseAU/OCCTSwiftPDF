// ArcFitting.swift
// OCCTSwiftPDF
//
// The public face of arc and circle recovery: the options, and what a fit reports.

import Foundation
import SwiftDXF

extension PDF {
    /// How `Page.fittedDrawing(_:)` decides that a run of curves, or of short straight lines, is one
    /// circle or arc.
    ///
    /// A run is accepted only if one circle, fitted over the whole run, passes within the
    /// tolerance of every vertex, of points sampled along every curve and of the middle of every
    /// chord in a run that has curves. The other limits keep polygons, ellipses, spirals and
    /// freehand curves from being taken for arcs; see the experiment page.
    public struct ArcFitting: Sendable, Equatable {
        /// The largest distance of a point of a run with curves from the circle, in millimetres
        /// on the paper.
        public var tolerance: Double
        /// The same as a fraction of the radius, used where it gives more than ``tolerance``.
        public var relativeTolerance: Double
        /// The same for a run of chords only, in millimetres on the paper.
        public var lineTolerance: Double
        /// The smallest sweep an arc may have, in degrees.
        ///
        /// It holds for a run of straight chords, and for one that has both chords and curves.
        public var minimumSweepDeg: Double
        /// The smallest sweep an arc of Bezier curves only may have, in degrees.
        ///
        /// Curves are held to less than chords, because a circle's curves are exact and a short
        /// arc of them is rarely a piece of something else: against the paired drawings, 96
        /// percent of the arcs of curves from 25 degrees lie within 0.5 mm of a reference arc,
        /// where arcs of chords under 45 degrees do in under 60. The arc is the right one, but
        /// its radius is rough where the writer's coordinates are on a coarse grid: for Acrobat
        /// Distiller (0.021 mm) the median radius error is 0.07 mm on the paper at 25 to 45
        /// degrees and 0.01 at 60 to 90. It is never larger than ``minimumSweepDeg``, which a
        /// smaller value there lowers as well.
        public var minimumCurveSweepDeg: Double
        /// The largest angle one chord may subtend at the circle's centre, in degrees.
        public var maximumLineStepDeg: Double
        /// The fewest chords a run with no curves may have.
        public var minimumLineSegments: Int
        /// The largest sweep of one chord of a run of chords over the smallest.
        public var maximumStepRatio: Double
        /// The smallest radius accepted, in millimetres on the paper.
        public var minimumRadius: Double
        /// The largest radius accepted, in millimetres on the paper.
        public var maximumRadius: Double

        public init(
            tolerance: Double = 0.01, relativeTolerance: Double = 0.0004,
            lineTolerance: Double = 0.003, minimumSweepDeg: Double = 45,
            minimumCurveSweepDeg: Double = 25, maximumLineStepDeg: Double = 24,
            minimumLineSegments: Int = 8, maximumStepRatio: Double = 1.5,
            minimumRadius: Double = 0.05, maximumRadius: Double = 2_000
        ) {
            self.tolerance = tolerance
            self.relativeTolerance = relativeTolerance
            self.lineTolerance = lineTolerance
            self.minimumSweepDeg = minimumSweepDeg
            self.minimumCurveSweepDeg = minimumCurveSweepDeg
            self.maximumLineStepDeg = maximumLineStepDeg
            self.minimumLineSegments = minimumLineSegments
            self.maximumStepRatio = maximumStepRatio
            self.minimumRadius = minimumRadius
            self.maximumRadius = maximumRadius
        }

        /// The smallest sweep, in degrees, of an arc of curves only: ``minimumCurveSweepDeg``, or
        /// ``minimumSweepDeg`` where that is smaller.
        var curveFloorDeg: Double { min(minimumCurveSweepDeg, minimumSweepDeg) }
    }

    /// A circle or arc recovered from a run of curves or of short lines, with how well it fits.
    public struct ArcFit: Sendable, Equatable {
        /// A whole circle, or an arc of one.
        public enum Shape: String, Sendable {
            case circle, arc
        }

        /// What the run was made of.
        public enum Input: String, Sendable {
            /// Bezier curves only.
            case curves
            /// Straight segments only (a flattened circle).
            case lines
            /// Both.
            case mixed
        }

        /// The provenance a ledger records for a value read from this fit.
        ///
        /// It is fitted, never drawn, so it can not grade its own source.
        public static let provenance = "FITTED"

        /// The index of the circle or arc in the drawing's `entities`.
        public var entityIndex: Int
        public var shape: Shape
        public var input: Input
        /// The centre, in millimetres on the paper.
        public var center: DXF.Point
        /// The radius over the whole run, in millimetres on the paper.
        public var radius: Double
        /// For an arc, where it starts, in degrees from 0 to 360; 0 for a circle.
        ///
        /// The arc sweeps counterclockwise from here to ``endDeg``, as a DXF `ARC` does, whichever
        /// way it was drawn.
        public var startDeg: Double
        /// For an arc, where it ends, in degrees; 360 for a circle.
        public var endDeg: Double
        /// The largest distance of the fitted points from the circle, in millimetres on the paper.
        ///
        /// The points are the vertices and samples along curves, and, for a run with curves, the
        /// middles of its chords. The middle of a chord of a run of chords only is not counted:
        /// such a run is a polygon on the circle.
        public var maxResidual: Double
        /// The root mean square of the distances of the vertices and curve samples, in
        /// millimetres on the paper.
        public var rmsResidual: Double
        /// The largest sweep of one segment over the smallest, near 1 for a circle cut in equal
        /// steps.
        public var stepRatio: Double
        /// The number of segments (lines and curves) the run replaced.
        public var segments: Int
        /// The operators that drew them, in order, each once.
        public var sources: [Source]
        /// The width the path was stroked with, in millimetres on the paper: that of the stroke drawn
        /// first, where a circle was drawn in several.
        public var lineWidth: Double

        /// The point of the circle at `degrees` counterclockwise from the x axis, in millimetres
        /// on the paper.
        public func point(atDeg degrees: Double) -> DXF.Point {
            let angle: Double = degrees * Double.pi / 180
            return DXF.Point(center.x + radius * cos(angle), center.y + radius * sin(angle))
        }

        /// The sweep in degrees: 360 for a circle.
        public var sweepDeg: Double {
            shape == .circle ? 360 : (endDeg - startDeg + 720).truncatingRemainder(dividingBy: 360)
        }
    }

    /// A page as a drawing, with the circles and arcs recovered in it.
    public struct FittedDrawing: Sendable {
        /// The drawing, with the circles and arcs in place of the curves or lines they replaced.
        ///
        /// Each one's identity locator ends in `:FITTED`.
        public var drawing: DXF.Drawing
        /// One per circle or arc recovered, in the order of their entities.
        public var fits: [ArcFit]
        /// The number of Bezier curves the recovered circles and arcs replaced.
        public var curvesReplaced: Int
        /// The number of straight segments the recovered circles and arcs replaced.
        public var linesReplaced: Int

        /// The fit behind the entity at `index`, or `nil` when that entity was drawn as it is.
        public func fit(atEntity index: Int) -> ArcFit? {
            // ``fits`` are in the order of their entities, so look for the index by halving.
            var low = 0
            var high = fits.count
            while low < high {
                let middle = (low + high) / 2
                if fits[middle].entityIndex < index { low = middle + 1 } else { high = middle }
            }
            return low < fits.count && fits[low].entityIndex == index ? fits[low] : nil
        }
    }
}
