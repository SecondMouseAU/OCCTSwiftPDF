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
    /// tolerance of every vertex and of points sampled along every curve. A drawing from a writer
    /// that flattens or approximates circles fits well inside the defaults; a polygon, an ellipse,
    /// a spiral or a freehand curve does not, and the other limits keep a short run, or a gentle
    /// curve, from being taken for an arc. A run of lines that the polyline carries on past, in
    /// the same curve, is never taken: that is a piece of a longer curve.
    public struct ArcFitting: Sendable, Equatable {
        /// The largest distance a fitted point may be from the circle for a run with Bezier curves
        /// in it, in millimetres on the paper.
        ///
        /// Writers round coordinates and approximate circles by curves, so this allows for that.
        public var tolerance: Double
        /// The same as a fraction of the radius, used where it gives more than ``tolerance``.
        ///
        /// A circle drawn as four Bezier curves strays from a true circle by about 0.03 percent of
        /// its radius, which is more than ``tolerance`` once the circle is big.
        public var relativeTolerance: Double
        /// The largest distance a fitted point may be from the circle for a run of straight
        /// segments only, in millimetres on the paper.
        ///
        /// A flattened circle has no approximation to allow for: its corners are on the circle to
        /// within the writer's rounding. The pieces of a freehand curve, a spiral or an ellipse
        /// are locally round to a hundredth of a millimetre and no better, so this is tighter than
        /// ``tolerance``.
        public var lineTolerance: Double
        /// The smallest sweep an arc may have, in degrees.
        ///
        /// A shorter piece says too little about its radius.
        public var minimumSweepDeg: Double
        /// The largest angle one straight segment may subtend at the circle's centre, in degrees.
        ///
        /// A square, a hexagon and an octagon have their corners on a circle but are not one: the
        /// segments of a flattened circle are short.
        public var maximumLineStepDeg: Double
        /// The fewest straight segments a run with no curves may have.
        ///
        /// Any three points lie on a circle, so a run of lines needs enough of them to test.
        public var minimumLineSegments: Int
        /// The largest sweep of one segment of a run of lines over the smallest.
        ///
        /// A writer that flattens a circle cuts it into equal steps; a piece of a freehand curve is
        /// not cut so.
        public var maximumStepRatio: Double
        /// The smallest radius accepted, in millimetres on the paper.
        public var minimumRadius: Double
        /// The largest radius accepted, in millimetres on the paper.
        public var maximumRadius: Double

        public init(
            tolerance: Double = 0.01, relativeTolerance: Double = 0.0004,
            lineTolerance: Double = 0.003, minimumSweepDeg: Double = 45,
            maximumLineStepDeg: Double = 24, minimumLineSegments: Int = 8,
            maximumStepRatio: Double = 1.5, minimumRadius: Double = 0.05,
            maximumRadius: Double = 2_000
        ) {
            self.tolerance = tolerance
            self.relativeTolerance = relativeTolerance
            self.lineTolerance = lineTolerance
            self.minimumSweepDeg = minimumSweepDeg
            self.maximumLineStepDeg = maximumLineStepDeg
            self.minimumLineSegments = minimumLineSegments
            self.maximumStepRatio = maximumStepRatio
            self.minimumRadius = minimumRadius
            self.maximumRadius = maximumRadius
        }
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
        /// The points are the vertices, and samples along curves. Straight segments are fitted by
        /// their ends, so the distance of a chord's middle from the circle is not in this.
        public var maxResidual: Double
        /// The root mean square of the same distances, in millimetres on the paper.
        public var rmsResidual: Double
        /// The largest sweep of one segment over the smallest.
        ///
        /// A writer that flattens or splits a circle cuts it into equal steps, so this is near 1
        /// for a circle it drew.
        public var stepRatio: Double
        /// The number of segments (lines and curves) the run replaced.
        public var segments: Int
        /// The operators that drew them, in order, each once.
        public var sources: [Source]
        /// The width the path was stroked with, in millimetres on the paper: that of the stroke drawn
        /// first, where a circle was drawn in several.
        public var lineWidth: Double

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
            fits.first { $0.entityIndex == index }
        }
    }
}
