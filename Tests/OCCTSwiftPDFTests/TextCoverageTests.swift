import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Which lines of shapes a page's own text covers, on boxes alone.
@Suite("Text coverage")
struct TextCoverageTests {
    /// A 20 by 5 box at the origin, read along the x axis.
    static let region = ShapeTextRegion(
        direction: CGPoint(x: 1, y: 0), origin: .zero, length: 20, height: 5, glyphs: 5,
        mostlyStroked: false, canReverse: false, paths: [0])

    /// A run with a box `x0` to `x1` along and `y0` to `y1` across.
    static func run(
        _ text: String, x0: Double, x1: Double, y0: Double = 0, y1: Double = 5,
        clockwise: Bool = false
    ) -> PDF.TextRun {
        var quad = [
            CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1),
            CGPoint(x: x0, y: y1),
        ]
        if clockwise { quad.reverse() }
        return PDF.TextRun(
            codes: [], codeCount: text.count, text: text, decoding: .toUnicode, ownText: text,
            pdfKitText: nil, origin: quad[0], rotationDeg: 0, height: y1 - y0, width: x1 - x0,
            quad: quad, fontName: "", fontSubtype: "", isInvisible: true, layer: nil,
            source: PDF.Source(page: 1, operatorIndex: 0))
    }

    static func text(over runs: [PDF.TextRun]) -> String? {
        TextCoverage(runs).text(over: region)
    }

    @Test("a run over the region covers it, and gives its text")
    func covered() {
        #expect(Self.text(over: [Self.run("10,439", x0: -1, x1: 21)]) == "10,439")
        // The run's corners can run either way round.
        #expect(Self.text(over: [Self.run("10,439", x0: -1, x1: 21, clockwise: true)]) == "10,439")
    }

    @Test("a run over less than half of it does not")
    func partlyCovered() {
        #expect(Self.text(over: [Self.run("AB", x0: 0, x1: 8)]) == nil)
        // Nor does one beside it, or above it.
        #expect(Self.text(over: [Self.run("AB", x0: 30, x1: 50)]) == nil)
        #expect(Self.text(over: [Self.run("AB", x0: 0, x1: 20, y0: 6, y1: 11)]) == nil)
    }

    @Test("runs that together cover most of it do, in reading order")
    func together() {
        let right = Self.run("439", x0: 11, x1: 21)
        let left = Self.run("10,", x0: -1, x1: 10)
        #expect(Self.text(over: [right, left]) == "10, 439")
    }

    @Test("runs that overlap one another are not counted twice")
    func overlapping() {
        // Each covers 40 percent; they lie on the same 40 percent (text drawn twice for bold).
        let first = Self.run("AB", x0: 0, x1: 8)
        let second = Self.run("AB", x0: 0, x1: 8)
        #expect(Self.text(over: [first, second]) == nil)
        // Offset from one another they cover 60 percent together.
        let shifted = Self.run("CD", x0: 4, x1: 12)
        #expect(Self.text(over: [first, shifted]) != nil)
    }

    @Test("a run much bigger or smaller than the shapes is not their text")
    func differentSize() {
        // A watermark (100 high) over a 5-high region, and a 1-high label inside it.
        #expect(Self.text(over: [Self.run("WATERMARK", x0: -50, x1: 90, y0: -40, y1: 60)]) == nil)
        #expect(Self.text(over: [Self.run("tiny", x0: -1, x1: 21, y0: 2, y1: 3)]) == nil)
        // A font size a little over the ink's height is the shapes' own text.
        #expect(Self.text(over: [Self.run("10,439", x0: -1, x1: 21, y0: -1, y1: 6.5)]) != nil)
    }

    @Test("a run with no characters covers nothing")
    func noCharacters() {
        var empty = Self.run("X", x0: -1, x1: 21)
        empty.text = nil
        #expect(Self.text(over: [empty]) == nil)
    }
}
