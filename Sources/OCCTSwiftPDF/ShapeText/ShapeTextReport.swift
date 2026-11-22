// ShapeTextReport.swift
// OCCTSwiftPDF
//
// What happened to every cluster of shapes looked at: accepted, or rejected and why.

import CoreGraphics
import Foundation

extension PDF {
    /// Why a cluster of shapes was not turned into text.
    public enum ShapeTextRejection: String, Sendable, CaseIterable {
        /// More clusters than ``ShapeTextOptions/maximumRegions``: not recognised.
        case overBudget
        /// A text run already covers it (``ShapeTextOptions/ExistingText/skip``): not recognised.
        case alreadyRead
        /// Its area could not be rendered (it would need a bitmap of over 48 million pixels).
        case notRendered
        /// The recogniser failed on it.
        case recognitionFailed
        /// The recogniser found no text in it.
        case noText
        /// The recogniser's confidence was under ``ShapeTextOptions/minimumConfidence``.
        case lowConfidence
        /// The recognised characters are implausible: none is a letter or a digit, or one is a
        /// replacement or control character.
        case characters
        /// The recogniser found text, but not where the shapes are: its box overlaps theirs by
        /// less than ``ShapeTextOptions/minimumOverlap``.
        case position
        /// More than one line was recognised in it, and they are not one line split in pieces.
        case ambiguous
        /// The recognised line runs in another direction than the shapes do.
        case direction
        /// The recognised line's height disagrees with the shapes'
        /// (``ShapeTextOptions/heightRatio``).
        case height
        /// The number of characters is implausible for the number of shapes.
        case glyphCount
        /// The line's length does not fit its number of characters (``ShapeTextOptions/advance``).
        case advance
        /// One reading passed, and another (at another size, ``ShapeTextOptions/readingPixels``)
        /// was rejected or read other characters.
        case inconsistent
    }

    /// What became of one cluster of shapes.
    public enum ShapeTextOutcome: Sendable, Equatable {
        case accepted
        case rejected(ShapeTextRejection)
    }

    /// One cluster of shapes, with what was recognised in it and whether that was accepted.
    public struct ShapeTextDecision: Sendable {
        /// The cluster's box along its line, in page coordinates: baseline start, baseline end,
        /// top end, top start.
        public var quad: [CGPoint]
        /// The number of glyph-sized pieces (a letter's outer and inner outlines count once).
        public var glyphs: Int
        /// What the recogniser read in it, even where that was rejected.
        public var recognised: String?
        public var confidence: Double?
        public var outcome: ShapeTextOutcome
        /// The text the page already had there, where ``ShapeTextOptions/existingText`` is
        /// ``ShapeTextOptions/ExistingText/compare`` and a run covers the cluster.
        public var readText: String?
    }

    /// What recovering text drawn as shapes did on one page.
    ///
    /// Every cluster looked at is in ``decisions`` and counted once in ``accepted`` or in
    /// ``rejected``, so `accepted + rejectedCount == regions`.
    public struct ShapeTextReport: Sendable {
        /// The page number, from 1.
        public var page: Int
        /// The small filled or stroked subpaths considered, grouped into glyph-sized pieces.
        public var shapes: Int
        /// The shapes left out because they sit in a blob of more than 5,000 pieces (a hatch, a
        /// dense symbol), which is not looked at.
        public var shapesInDenseBlobs: Int
        /// The clusters of shapes, each one line of at least ``ShapeTextOptions/minimumGlyphs``
        /// pieces.
        public var regions: Int
        /// Clusters of fewer pieces than that, which are not looked at.
        public var tooSmall: Int
        /// The clusters accepted as text and added to the page.
        public var accepted: Int
        /// The clusters not turned into text, by why.
        public var rejected: [ShapeTextRejection: Int]
        public var decisions: [ShapeTextDecision]

        /// The number of clusters not turned into text.
        public var rejectedCount: Int { rejected.values.reduce(0, +) }
    }

    /// A document with the text recovered from shapes added, and a report for each page.
    public struct ShapeTextRecovery: Sendable {
        /// The document with the accepted OCR text added.
        ///
        /// Each page's accepted runs (``TextDecoding/ocr``) are added to its `texts`. The original
        /// document is not changed.
        public var document: Document
        /// The report for each page read, by page number.
        public var reports: [Int: ShapeTextReport]
    }
}
