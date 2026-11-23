import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The agreement rules, on arithmetic alone: a recognised line and the shapes it was found for.
@Suite("Shape text validation")
struct ShapeTextValidatorTests {
    /// Six glyphs, 29 long and 8.5 high, as "10,439" is at 10 points.
    static let region = ShapeTextRegion(
        direction: CGPoint(x: 1, y: 0), origin: .zero, length: 29, height: 8.5, glyphs: 6,
        mostlyStroked: false, canReverse: false, paths: [0])

    /// A line with a box that runs a little past the ink, as Vision's does.
    static func line(
        _ text: String = "10,439", confidence: Double = 1, box: CGRect? = nil
    ) -> FramedLine {
        let box = box ?? CGRect(x: -1.5, y: -1.5, width: 32, height: 11)
        return FramedLine(
            text: text, confidence: confidence,
            corners: [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
            ])
    }

    static func verdict(
        _ lines: [FramedLine], region: ShapeTextRegion = region,
        options: PDF.ShapeTextOptions = .init()
    ) -> ShapeTextValidator.Verdict {
        ShapeTextValidator.validate(lines, in: region, options: options)
    }

    static func rejection(_ verdict: ShapeTextValidator.Verdict) -> PDF.ShapeTextRejection? {
        if case .rejected(let reason, _) = verdict { return reason }
        return nil
    }

    @Test("a line that agrees is accepted, with its confidence")
    func accepted() {
        #expect(
            Self.verdict([Self.line(confidence: 0.8)]) == .accepted(text: "10,439", confidence: 0.8)
        )
    }

    @Test("nothing recognised is rejected as no text")
    func noText() {
        #expect(Self.rejection(Self.verdict([])) == .noText)
    }

    @Test("a line under the least confidence is rejected")
    func confidence() {
        #expect(Self.rejection(Self.verdict([Self.line(confidence: 0.3)])) == .lowConfidence)
        var options = PDF.ShapeTextOptions()
        options.minimumConfidence = 0.2
        #expect(Self.rejection(Self.verdict([Self.line(confidence: 0.3)], options: options)) == nil)
    }

    @Test(
        "characters that are not text are rejected",
        arguments: [
            "---", "|||", "\u{FFFD}12", "1\u{0007}2", "  ", "\u{0410}PPLICABLE", "\u{0406}V*",
            "1\u{0E3F}/9/73", "12\u{4E2D}",
        ])
    func characters(text: String) {
        #expect(Self.rejection(Self.verdict([Self.line(text)])) == .characters)
    }

    @Test("another script is refused unless its block is allowed")
    func extraBlocks() {
        let japanese = Self.line("\u{65E5}\u{672C}\u{8A9E}")
        #expect(Self.rejection(Self.verdict([japanese])) == .characters)
        var options = PDF.ShapeTextOptions()
        options.additionalCharacterBlocks = [0x3000...0x9FFF]
        #expect(Self.rejection(Self.verdict([japanese], options: options)) == nil)
    }

    @Test("a word wholly in Cyrillic, or Greek letters beside Latin ones, is not a look-alike")
    func scripts() {
        // Cyrillic throughout is a Russian drawing; Greek letters are used in engineering.
        #expect(
            Self.rejection(Self.verdict([Self.line("\u{0414}\u{0412}\u{0415}\u{0420}\u{042C}")]))
                == nil)
        #expect(Self.rejection(Self.verdict([Self.line("\u{0394}T 129")])) == nil)
        // The symbols of a drawing are not refused: diameter, plus or minus, degree, a fraction.
        #expect(Self.rejection(Self.verdict([Self.line("\u{00D8}1 \u{00B1}0\u{00B0}")])) == nil)
        #expect(Self.rejection(Self.verdict([Self.line("\u{2300}20 5\u{00BD}")])) == nil)
    }

    @Test("text where the shapes are not is rejected as a position")
    func position() {
        // Beside the shapes, and then only partly overlapping them.
        let beside = CGRect(x: 40, y: 0, width: 30, height: 8.5)
        #expect(Self.rejection(Self.verdict([Self.line(box: beside)])) == .position)
        let long = CGRect(x: -1, y: -1, width: 75, height: 10)
        #expect(Self.rejection(Self.verdict([Self.line(box: long)])) == .position)
    }

    @Test("a line turned from the reading direction is rejected")
    func direction() {
        let width = 29.0
        let height = 8.5
        let angle = 12.0 * .pi / 180
        func corner(_ x: Double, _ y: Double) -> CGPoint {
            let dx = x - width / 2
            let dy = y - height / 2
            let turnedX = dx * cos(angle) - dy * sin(angle)
            let turnedY = dx * sin(angle) + dy * cos(angle)
            return CGPoint(x: width / 2 + turnedX, y: height / 2 + turnedY)
        }
        let turned = FramedLine(
            text: "10,439", confidence: 1,
            corners: [corner(0, 0), corner(width, 0), corner(width, height), corner(0, height)])
        #expect(Self.rejection(Self.verdict([turned])) == .direction)
        var options = PDF.ShapeTextOptions()
        options.maximumDirectionError = 15
        #expect(Self.rejection(Self.verdict([turned], options: options)) == nil)
    }

    @Test("a line nearly twice as tall as the shapes is rejected as a height")
    func height() {
        let tall = CGRect(x: 0, y: -0.5, width: 29, height: 15.5)
        #expect(Self.rejection(Self.verdict([Self.line(box: tall)])) == .height)
    }

    @Test("a count of characters that the shapes cannot draw is rejected")
    func glyphCount() {
        // Six outlines cannot be thirteen characters, nor one.
        #expect(Self.rejection(Self.verdict([Self.line("10,439 AND MORE")])) == .glyphCount)
        #expect(Self.rejection(Self.verdict([Self.line("1")])) == .glyphCount)
        // But they can be eight (two dotted letters) or three (a few pieces each).
        #expect(Self.rejection(Self.verdict([Self.line("ii,iiiii")])) == nil)
        // Strokes are several to a character.
        var strokes = Self.region
        strokes.glyphs = 14
        strokes.mostlyStroked = true
        #expect(Self.rejection(Self.verdict([Self.line("10,4")], region: strokes)) == nil)
        strokes.mostlyStroked = false
        #expect(Self.rejection(Self.verdict([Self.line("10,4")], region: strokes)) == .glyphCount)
    }

    @Test("a length that does not fit the characters is rejected")
    func advance() {
        var short = Self.region
        short.length = 15
        let box = CGRect(x: -1, y: -1, width: 17, height: 10.5)
        #expect(
            Self.rejection(Self.verdict([Self.line("1 2 3 4 5 6 7 8", box: box)], region: short))
                == .advance)
        // The same text over a long enough line is fine.
        #expect(Self.rejection(Self.verdict([Self.line("1 2 3 4 5 6 7 8")])) == nil)
    }

    @Test("a neighbour in the margin is ignored; two lines in the box are ambiguous")
    func neighbours() {
        let neighbour = Self.line("ABOVE", box: CGRect(x: 0, y: 12, width: 29, height: 8.5))
        #expect(
            Self.verdict([neighbour, Self.line()]) == .accepted(text: "10,439", confidence: 1))
        var tall = Self.region
        tall.height = 20
        let lower = Self.line("10,4", box: CGRect(x: 0, y: 0, width: 29, height: 9))
        let upper = Self.line("39", box: CGRect(x: 0, y: 11, width: 29, height: 9))
        #expect(Self.rejection(Self.verdict([lower, upper], region: tall)) == .ambiguous)
    }

    @Test("a line cut in pieces along one baseline is one line")
    func pieces() {
        let left = Self.line("10,", box: CGRect(x: -1, y: -1, width: 14, height: 10.5))
        let right = Self.line("439", box: CGRect(x: 14, y: -1, width: 16, height: 10.5))
        #expect(
            Self.verdict([right, left]) == .accepted(text: "10, 439", confidence: 1))
        // Overlapping pieces are not.
        let overlapping = Self.line("439", box: CGRect(x: 8, y: -1, width: 22, height: 10.5))
        #expect(Self.rejection(Self.verdict([left, overlapping])) == .ambiguous)
    }
}
