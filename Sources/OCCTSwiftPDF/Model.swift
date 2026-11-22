// Model.swift
// OCCTSwiftPDF
//
// What a PDF page is made of, in the page's own coordinates (PDF points), before it becomes a
// DXF.Drawing.

import CoreGraphics
import Foundation

extension PDF {
    /// Where something on a page came from in the file.
    public struct Source: Hashable, Sendable, CustomStringConvertible {
        /// The page number, from 1.
        public var page: Int
        /// The position of the operator that painted or showed it, among the operators this
        /// reader interprets on the page, counted through any Form XObjects in the order they run.
        public var operatorIndex: Int
        /// The Form XObjects it was reached through, outermost first, as `name#n` where `n` counts
        /// the invocations on the page from 1.
        public var forms: [String]

        public init(page: Int, operatorIndex: Int, forms: [String] = []) {
            self.page = page
            self.operatorIndex = operatorIndex
            self.forms = forms
        }

        /// `p3:op120`, or `p3/Fm0#1:op120` for an operator inside a Form XObject.
        public var description: String {
            (["p\(page)"] + forms).joined(separator: "/") + ":op\(operatorIndex)"
        }
    }

    /// One piece of a subpath, ending at `to`; it starts where the piece before it ends.
    public enum Segment: Equatable, Sendable {
        case line(to: CGPoint)
        /// A cubic Bezier curve.
        case curve(control1: CGPoint, control2: CGPoint, to: CGPoint)

        public var end: CGPoint {
            switch self {
            case .line(let to), .curve(_, _, let to): to
            }
        }
    }

    /// A connected run of segments.
    public struct Subpath: Equatable, Sendable {
        public var start: CGPoint
        public var segments: [Segment]
        /// Closed by `h`, `s`, `b` or `re`; the closing line, when it has length, is the last
        /// segment.
        public var isClosed: Bool

        public init(start: CGPoint, segments: [Segment] = [], isClosed: Bool = false) {
            self.start = start
            self.segments = segments
            self.isClosed = isClosed
        }
    }

    /// How a path was painted.
    public enum Paint: String, Sendable {
        case stroke, fill, fillAndStroke
    }

    /// A colour, as red, green and blue from 0 to 1.
    public struct Colour: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let black = Colour(red: 0, green: 0, blue: 0)
    }

    /// A painted path, in page coordinates.
    public struct Path: Sendable {
        public var subpaths: [Subpath]
        public var paint: Paint
        /// The fill rule was even-odd (`f*`, `B*`, `b*`).
        public var evenOdd: Bool
        /// The line width in page units, taking the transform's scale into account.
        public var lineWidth: Double
        /// The dash pattern in page units; empty for a solid line.
        public var dash: [Double]
        public var strokeColour: Colour
        public var fillColour: Colour
        /// The PDF layer (optional content group) it was drawn in, or `nil`.
        public var layer: String?
        public var source: Source
    }

    /// How a text run's characters were found.
    public enum TextDecoding: String, Sendable, CaseIterable {
        /// The font's `ToUnicode` map. A code the map does not cover took the simple font's own
        /// character where its encoding is known, and U+FFFD otherwise.
        case toUnicode
        /// The font's encoding is a Shift-JIS one (`90ms-RKSJ-H` and the like), so the bytes are
        /// Shift-JIS text.
        case shiftJIS
        /// The font's encoding is a Unicode one (`UniJIS-UCS2-H` and the like).
        case unicodeCMap
        /// The embedded TrueType program's own `cmap` table: an `Identity` font that has no
        /// `ToUnicode` map, or an empty one (ODA's entry is a name, not a map). A code is a CID,
        /// the `CIDToGIDMap` gives its glyph, and the font says what character that glyph is. A
        /// code with no character is U+FFFD, except a space the font's subset left out, which is
        /// read as a space where the font shows its CIDs are Unicode.
        case embeddedFont
        /// A simple font's encoding (`WinAnsiEncoding`, `MacRomanEncoding`, `StandardEncoding`, or a
        /// `Differences` array of standard glyph names).
        case simpleEncoding
        /// A symbolic, TrueType, Type 3 or embedded font with no base encoding, whose codes (those
        /// its `Differences` array does not name) were taken as ASCII.
        ///
        /// Such a font's built-in encoding can be anything, so for a run along or across the page
        /// PDFKit's characters replace these when the two differ.
        case asciiGuess
        /// The characters are PDFKit's, found by position: this reader had none, or (for a run
        /// along or across the page) only guessed ASCII that PDFKit contradicted, or a U+FFFD.
        ///
        /// Never on tvOS, where PDFKit is not used.
        case pdfKit
        /// Nothing could decode it: the font has no way back from codes to characters.
        case none
    }

    /// One text-showing operation (`Tj`, `TJ`, `'` or `"`), in page coordinates.
    public struct TextRun: Sendable {
        /// The bytes shown.
        public var codes: [UInt8]
        /// The number of character codes in ``codes``, by the font's code space.
        public var codeCount: Int
        /// The characters, from this reader's own decoding or from PDFKit.
        ///
        /// PDFKit's stand in where this reader has none, and, for a run along or across the page,
        /// where it only guessed ASCII that PDFKit contradicts (``TextDecoding/asciiGuess``) or has
        /// a U+FFFD. U+FFFD stands for a code that nothing decoded.
        public var text: String?
        public var decoding: TextDecoding
        /// This reader's own decoding of ``codes``, or `nil`.
        public var ownText: String?
        /// The characters PDFKit reports inside the run's box, or `nil` when not paired.
        ///
        /// Always `nil` on tvOS, where PDFKit is not used: ``text`` is then this reader's own
        /// decoding alone. That is `nil` (with a ``decoding`` of ``TextDecoding/none``) for a run it
        /// cannot read, and a guess (``TextDecoding/asciiGuess``) or a U+FFFD stays as it is.
        public var pdfKitText: String?
        /// The start of the baseline.
        public var origin: CGPoint
        /// The direction of the baseline, counterclockwise from the page's x axis.
        public var rotationDeg: Double
        /// The font size in page units.
        public var height: Double
        /// The advance along the baseline, in page units.
        public var width: Double
        /// The run's box: baseline start, baseline end, top end, top start.
        public var quad: [CGPoint]
        public var fontName: String
        public var fontSubtype: String
        /// Text render mode 3 (drawn invisibly, as the text layer of a scanned page is) or 7 (used
        /// only to clip).
        public var isInvisible: Bool
        public var layer: String?
        public var source: Source
        /// The sources of the runs joined to this one after the first, when the writer showed the
        /// line in pieces (one character per operation, say).
        public var parts: [Source] = []
    }

    /// An image placed on the page.
    public struct Image: Sendable {
        /// The image's corners on the page.
        public var corners: [CGPoint]
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// The area it covers, in square page units.
        public var area: Double
        public var source: Source
    }

    /// What a page is made of.
    public enum Kind: String, Sendable {
        /// Paths and text, no significant image.
        case vector
        /// Mostly one or more images, as a scanned sheet is.
        case raster
        /// Images and vector content together.
        case mixed
        /// Nothing drawn.
        case empty
    }

    /// One page, read.
    public struct Page: Sendable {
        /// The page number, from 1.
        public var number: Int
        public var mediaBox: CGRect
        public var cropBox: CGRect
        /// The page's `/Rotate`, clockwise, in degrees: 0, 90, 180 or 270.
        public var rotation: Int
        public var paths: [Path]
        public var texts: [TextRun]
        public var images: [Image]
        /// Paths used only to clip (`W n`), which are not drawn.
        public var clipPaths: Int
        /// Form XObjects run on the page.
        public var formInvocations: Int
        /// Inline images and shadings, which are counted and not read.
        public var inlineImages: Int
        public var shadings: Int
        /// The layers (optional content groups) used on the page, in order of first use.
        public var layers: [String]

        /// The fraction of the page's area covered by images, from 0 to 1.
        public var imageCoverage: Double {
            let pageArea = cropBox.width * cropBox.height
            guard pageArea > 0 else { return 0 }
            let covered = images.reduce(0.0) { sum, image in
                sum + Self.clippedArea(image.corners, to: cropBox)
            }
            return min(1, covered / pageArea)
        }

        /// The number of segments in painted paths.
        public var segmentCount: Int {
            paths.reduce(0) { sum, path in
                sum + path.subpaths.reduce(0) { $0 + $1.segments.count }
            }
        }

        /// Whether the page is vector, raster, mixed or empty.
        ///
        /// Raster: images cover at least half the page and fewer than 200 segments are drawn
        /// over them. Vector: images cover under a quarter of the page (a logo or a photograph in
        /// the title block). Mixed: anything else, such as a drawing over a full-page image.
        public var kind: Kind {
            let coverage = imageCoverage
            if coverage >= 0.5 && segmentCount < 200 { return .raster }
            if coverage < 0.25 {
                return segmentCount > 0 || !texts.isEmpty ? .vector : .empty
            }
            return .mixed
        }

        /// The area of the part of a quadrilateral inside `box`, approximated by its bounding
        /// rectangle, which is exact for an image placed without rotation.
        static func clippedArea(_ corners: [CGPoint], to box: CGRect) -> Double {
            guard let first = corners.first else { return 0 }
            var bounds = CGRect(origin: first, size: .zero)
            for corner in corners.dropFirst() {
                bounds = bounds.union(CGRect(origin: corner, size: .zero))
            }
            let inside = bounds.intersection(box)
            return inside.isNull ? 0 : inside.width * inside.height
        }
    }

    /// A PDF document, read.
    public struct Document: Sendable {
        public var url: URL
        /// The number of pages in the file; ``pages`` can hold fewer when a read was limited.
        public var pageCount: Int
        public var pages: [Page]
        /// The names of the layers (optional content groups) the document declares.
        public var layers: [String]
        /// The layers the document's default configuration turns off (`/D /OFF`).
        ///
        /// A watermark layer is often one. Their content is read like any other; this says it
        /// would not be shown.
        public var layersOff: [String]
        public var producer: String?
        public var creator: String?
    }
}
