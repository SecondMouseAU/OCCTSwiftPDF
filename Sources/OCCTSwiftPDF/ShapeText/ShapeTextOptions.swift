// ShapeTextOptions.swift
// OCCTSwiftPDF
//
// What recovering text drawn as shapes (filled outlines, strokes) is allowed to accept, in one
// place: every tolerance the validation uses is here, with its default.

import Foundation

extension PDF {
    /// How text drawn as shapes is recovered by OCR, and how closely the result must agree with
    /// the geometry to be accepted.
    ///
    /// A wrong string is worse than no string, so the defaults are strict. Every tolerance is
    /// applied to a recognised line and the cluster of shapes it was found for, both measured in
    /// the line's own frame (along the reading direction, and across it).
    public struct ShapeTextOptions: Sendable {
        /// What to do where the page already has text over the shapes.
        public enum ExistingText: Sendable {
            /// Leave a cluster alone where a text run (visible or invisible) already covers it,
            /// and count it as already read. The default: nothing is recognised twice.
            case skip
            /// Recognise it as well, for a check: the result is in the report (with the text
            /// already read) and is not added to the page.
            case compare
        }

        /// What to do where the page already has text over the shapes.
        public var existingText: ExistingText = .skip

        /// The least confidence the recogniser may report for a line.
        ///
        /// From 0 to 1; default 0.5. Vision's accurate level reports 1.0 for nearly everything it
        /// reads, so this rarely decides.
        public var minimumConfidence = 0.5

        /// The least intersection over union of the recognised line's box and the cluster's box.
        ///
        /// Default 0.5. The recogniser's box runs a little past the ink, about 5 percent along the
        /// line and 10 to 30 percent across it, which this allows for.
        public var minimumOverlap = 0.5

        /// The recognised box's height as a multiple of the cluster's measured height.
        ///
        /// Default 0.6 to 1.8.
        public var heightRatio: ClosedRange<Double> = 0.6...1.8

        /// The most the recognised line may be turned from the reading direction, in degrees.
        ///
        /// Default 8: the geometry gives the direction, so a line that is not along it is another
        /// thing than the shapes.
        public var maximumDirectionError = 8.0

        /// The cluster's length per character as a multiple of its height, spaces counted, for a
        /// string of two or more characters.
        ///
        /// Default 0.2 to 1.8: Latin text advances about 0.4 to 1.1 of its cap height per
        /// character.
        public var advance: ClosedRange<Double> = 0.2...1.8

        /// The fewest glyph-sized pieces a cluster needs to be looked at.
        ///
        /// Default 2: a single character cannot be checked against its geometry.
        public var minimumGlyphs = 2

        /// The longest side, in page units, of a shape that may be part of a glyph.
        ///
        /// Default 64.
        public var maximumShapeSize = 64.0

        /// The most clusters recognised on a page; the rest are counted as over budget.
        ///
        /// Default 3,000.
        public var maximumRegions = 3_000

        /// The heights, in pixels, a cluster is rendered at, one reading each.
        ///
        /// Default 40, 64 and 96. A cluster is accepted only if every reading is accepted and they
        /// give the same characters, so a misreading that depends on the size (a look-alike at one
        /// size) is caught, and one that does not (a slash read as a `V` at every size) is not. A
        /// cluster a reading rejects is not read again. One height reads each cluster once, at a
        /// third of the cost, and lets more wrong strings through
        /// (`okf/experiments/option-1-spike.md` has the figures).
        public var readingPixels: [Double] = [40, 64, 96]

        public init() {}
    }
}
