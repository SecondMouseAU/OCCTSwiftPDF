// DimensionRecovery.swift
// OCCTSwiftPDF
//
// What rebuilding a page's dimensions gives, and the options it takes. See `PDF.Page` in
// PageDimensions.swift for the rebuild itself.

import CoreGraphics
import Foundation
import SwiftDXF

extension PDF {
    /// What a dimension rebuild may be told.
    public struct DimensionOptions: Equatable, Sendable {
        /// How the drawing writes numbers, as for SwiftDXF's `DimensionRebuild.Options.numbers`:
        /// `nil` reads a comma every way it can be read and lets the geometry choose.
        ///
        /// A Jw_cad drawing (the TECS PDFs) writes `1,829` for one thousand eight hundred and
        /// twenty-nine: say `.commaSeparatesThousands` and it is never read as 1.829. Left `nil`,
        /// the geometry chooses, which holds while the scale is not in doubt.
        public var numbers: DXF.DimensionText.NumberConvention?
        /// How far apart two pieces may be and still meet, in millimetres on the paper, as for
        /// SwiftDXF's `DimensionRebuild.Options.tolerance` (3 percent of the value texts' height by
        /// default).
        public var tolerance: Double?
        /// A scale to use instead of inferring one.
        ///
        /// The real value per millimetre on the paper, `80` for a sheet at 1:80. Anything but a
        /// positive number is none. Views are not asked for scales of their own then.
        public var scale: Double?
        /// The scales that count as credible for a sheet of paper.
        ///
        /// Real value per millimetre on the paper: `0.1` is 10:1 and `300` is 1:300. A scale outside
        /// it is not used even where values agree on it, and the values are listed as not
        /// explained. Few values agree with a very large scale by chance, and on the TECS sheets
        /// every scale above 1:300 was wrong (`okf/experiments/dimensions-and-scale.md`). Default
        /// `0.1...300`.
        public var scaleRange: ClosedRange<Double>
        /// Whether a filled triangle with no stroke, which is how most CAD writers draw an
        /// arrowhead, ends a dimension line that nothing else ends (default `true`).
        public var arrowheads: Bool
        /// Whether the page is split into views, each asked for a scale of its own (default
        /// `true`).
        ///
        /// A view is asked to report where it disagrees with the sheet's. Off, the whole sheet is
        /// one view.
        public var separateViews: Bool
        /// The size of the cells views are made of, in millimetres on the paper.
        ///
        /// Two pieces are one view when a run of touching cells joins them, so views are parted by
        /// a clear gap of between this and twice this. `nil` is twice the median text height.
        public var viewGap: Double?

        public init(
            numbers: DXF.DimensionText.NumberConvention? = nil, tolerance: Double? = nil,
            scale: Double? = nil, scaleRange: ClosedRange<Double> = 0.1...300,
            arrowheads: Bool = true, separateViews: Bool = true, viewGap: Double? = nil
        ) {
            self.numbers = numbers
            self.tolerance = tolerance
            self.scale = scale
            self.scaleRange = scaleRange
            self.arrowheads = arrowheads
            self.separateViews = separateViews
            self.viewGap = viewGap
        }
    }

    /// A scale a view's own values favour against the sheet's, and what it would give.
    public struct DimensionAlternative: Sendable {
        /// The scale (the real value per millimetre on the paper) and the values of the view that
        /// support and contradict it.
        public var scale: DXF.DimensionRebuild.ScaleEstimate
        /// The dimensions of the view rebuilt at that scale.
        ///
        /// They are not in the recovery's ``DimensionRecovery/dimensions``: nothing is applied that
        /// the evidence does not settle.
        public var dimensions: [DXF.Dimension]
    }

    /// One view of a page: a group of pieces that lie together, apart from the others.
    public struct DimensionView: Sendable {
        /// The view's number, from 1, in the order of its first piece on the page.
        public var number: Int
        /// The extent of the view's pieces, in millimetres on the paper.
        public var bounds: CGRect
        /// The scale of the sheet, which the view's ``dimensions`` are at, or `nil` when the sheet
        /// has none (in which case the view has no dimensions).
        public var scale: Double?
        /// The value texts of the view that ``scale`` explains, each a dimension of the view.
        public var supporting: Int
        /// The value texts of the view that have a dimension line beside them but that ``scale``
        /// does not explain.
        public var contradicting: Int
        /// The dimensions rebuilt in the view, in the order of their value texts.
        public var dimensions: [DXF.Dimension]
        /// Each value text of the view that no dimension explains, and each diameter or radius
        /// symbol the geometry does not bear out.
        public var warnings: [DXF.DimensionRebuild.Warning]
        /// A scale the view's own values favour that differs from the sheet's by more than 10
        /// percent, when they favour it with at least six values and four fifths of those that
        /// vote; or `nil`.
        public var alternative: DimensionAlternative?
    }

    /// Dimensions rebuilt from a page's loose pieces, and the evidence for the scale of each view.
    ///
    /// Made by ``Page/recoveringDimensions(_:)``. It is an inference, and says what it rests on:
    /// every dimension has `rebuilt` set (so it is told from a dimension the file stores), and each
    /// view says how many of its values the sheet's scale explains, how many it does not, each
    /// value it could not explain, and any other scale its own values favour. Nothing is scaled: a
    /// page's drawing stays at the paper's millimetres, and a scale is for the caller to apply once
    /// it has looked at the evidence.
    public struct DimensionRecovery: Sendable {
        /// The scale of the sheet, the one that explains the most values over the whole page (the
        /// real value per millimetre on the paper, `80` for 1:80), and what supports it; or `nil`
        /// when no credible scale explains enough values.
        ///
        /// With a scale given in the options it is that scale and what supports it, which can be
        /// nothing.
        public var sheet: DXF.DimensionRebuild.ScaleEstimate?
        /// The views that have value texts, in the order of their first piece on the page.
        public var views: [DimensionView]
        /// Every warning of every view, then, when a view's own values favour another scale,
        /// `scalesDisagree` with the sheet's and each such view's (none is averaged).
        public var warnings: [DXF.DimensionRebuild.Warning]

        /// The sheet's scale: the real value per millimetre on the paper, or `nil`.
        public var scale: Double? { sheet?.scale }

        /// The dimensions of every view, in the order of the views, all at the sheet's scale.
        public var dimensions: [DXF.Dimension] { views.flatMap(\.dimensions) }

        /// The result as SwiftDXF's `DimensionRebuild`, which is what a rebuild of any other
        /// drawing gives (its scale group is `sheet`).
        public var rebuild: DXF.DimensionRebuild {
            DXF.DimensionRebuild(
                dimensions: dimensions, scales: sheet.map { [$0] } ?? [], warnings: warnings)
        }

        /// `drawing` with the rebuilt dimensions added after its entities, each with its `rebuilt`
        /// set; see `DimensionRebuild.applied(to:)`.
        ///
        /// A dimension's `rebuilt.pieces` name entities of the page's `drawing()`, except an
        /// arrowhead's tip: `drawing()` leaves the filled path out (`skipped["FILL"]`), so its
        /// identity (`p1:op12:0`) is the path's and has no entity there.
        public func applied(to drawing: DXF.Drawing) -> DXF.Drawing {
            rebuild.applied(to: drawing)
        }
    }
}
