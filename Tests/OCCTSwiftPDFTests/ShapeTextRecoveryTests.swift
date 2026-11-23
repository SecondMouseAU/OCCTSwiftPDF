import CoreGraphics
import Foundation
import SwiftDXF
import Testing

@testable import OCCTSwiftPDF

/// The whole path (render, recognise, validate, emit) with a recogniser that reads the ink it is
/// shown, so what is under test is the geometry round the recogniser, on every platform.
@Suite("Shape text recovery")
struct ShapeTextRecoveryTests {
    static let origin = CGPoint(x: 100, y: 100)

    static func recover(
        _ content: String, recogniser: some TextRecogniser, options: PDF.ShapeTextOptions = .init(),
        resources: String = "<< >>", mediaBox: String = "[0 0 612 792]"
    ) throws -> (document: PDF.Document, recovery: PDF.ShapeTextRecovery) {
        let document = try ShapeTextFixtures.document(
            content, resources: resources, mediaBox: mediaBox)
        let recovery = try document.recoveringShapeText(options: options, recogniser: recogniser)
        return (document, recovery)
    }

    /// A recogniser whose box runs past the ink as Vision's does.
    static func visionLike(_ text: String) -> InkRecogniser {
        let recogniser = InkRecogniser(text)
        recogniser.grow = 0.1
        return recogniser
    }

    @Test(
        "accepted text is a run marked OCR, placed by the shapes, and the page it came from is kept"
    )
    func accepted() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let (document, recovery) = try Self.recover(
            text.content, recogniser: Self.visionLike("10,439"))
        let report = try #require(recovery.reports[1])
        #expect(report.regions == 1)
        #expect(report.accepted == 1)
        #expect(report.rejectedCount == 0)
        #expect(report.decisions.count == 1)
        #expect(report.decisions.first?.outcome == .accepted)

        let before = try #require(document.pages.first)
        let page = try #require(recovery.document.pages.first)
        // The document read is not changed.
        #expect(before.texts.isEmpty)
        #expect(page.texts.count == 1)
        let run = try #require(page.texts.first)
        #expect(run.text == "10,439")
        #expect(run.decoding == .ocr)
        #expect(run.confidence == 1)
        #expect(run.codes.isEmpty && run.ownText == nil && run.pdfKitText == nil)
        #expect(!run.isInvisible)
        #expect(abs(run.rotationDeg) < 0.5)
        // Placed by the shapes, not the recogniser's looser box, and on the baseline the text was
        // drawn on, not at the bottom of its comma.
        #expect(abs(run.origin.x - text.ink.minX) < 0.1)
        #expect(abs(run.origin.y - Self.origin.y) < 0.1)
        #expect(text.ink.minY < Self.origin.y - 1)
        #expect(abs(run.width - text.ink.width) < 0.1)
        // Its height is that of the ink above the baseline.
        #expect(abs(run.height - (text.ink.maxY - Self.origin.y)) < 0.1)
        #expect(run.quad.count == 4 && abs(run.quad[0].y - Self.origin.y) < 0.1)
        // Its source is the first glyph's path, and the others are its parts.
        #expect(run.source == before.paths[0].source)
        #expect(run.parts == before.paths.dropFirst().map(\.source))
    }

    @Test("text read from the file has no confidence and is not OCR")
    func readTextIsNotOCR() throws {
        let url = try MiniPDF(
            content: "BT /F1 12 Tf 100 100 Td (Hello) Tj ET",
            resources: ShapeTextFixtures.helveticaResources
        ).file()
        let page = try #require(
            try PDF.read(contentsOf: url, maximumPages: nil, crossCheck: false).pages.first)
        let run = try #require(page.texts.first)
        #expect(run.decoding != .ocr)
        #expect(run.confidence == nil)
    }

    @Test("drawing() draws the OCR text, identifies it as OCR, and the default is unchanged")
    func drawing() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let (document, recovery) = try Self.recover(
            text.content, recogniser: Self.visionLike("10,439"))
        let plain = try #require(document.pages.first).drawing()
        let recovered = try #require(recovery.document.pages.first).drawing()
        // As read: six filled outlines, drawn as nothing.
        #expect(plain.counts.text == 0)
        #expect(plain.skipped["FILL"] == 6)
        #expect(plain.entities.isEmpty)
        // Recovered: the text, and the outlines still counted as skipped.
        #expect(recovered.counts.text == 1)
        #expect(recovered.skipped["FILL"] == 6)
        let entity = try #require(recovered.entities.first)
        if case .text(_, _, _, let string, _, _) = entity {
            #expect(string == "10,439")
        } else {
            Issue.record("not a text entity")
        }
        let identity = try #require(recovered.identities.first)
        #expect(identity.locator.hasSuffix(":ocr0"))
        #expect(identity.locator.hasPrefix("p1:op"))
    }

    @Test("text with a page that is offset and has its own crop box is placed all the same")
    func offsetPage() throws {
        let text = OutlineText.drawn("SCALE 1:50", at: CGPoint(x: 150, y: 150))
        let (_, recovery) = try Self.recover(
            text.content, recogniser: Self.visionLike("SCALE 1:50"), mediaBox: "[100 100 400 300]")
        let report = try #require(recovery.reports[1])
        #expect(report.accepted == 1)
        let run = try #require(recovery.document.pages.first?.texts.first)
        #expect(abs(run.origin.x - text.ink.minX) < 0.1)
        #expect(abs(run.origin.y - 150) < 0.15)
    }

    @Test("text turned a quarter turn is read along its own direction")
    func turned() throws {
        let text = OutlineText.drawn(
            "SECTION", at: CGPoint(x: 300, y: 300), rotationDegrees: 90)
        let (_, recovery) = try Self.recover(
            text.content, recogniser: Self.visionLike("SECTION"))
        let report = try #require(recovery.reports[1])
        #expect(report.accepted == 1)
        let run = try #require(recovery.document.pages.first?.texts.first)
        #expect(abs(run.rotationDeg - 90) < 1)
        #expect(abs(run.width - OutlineText.drawn("SECTION", at: .zero).ink.width) < 0.5)
        // The baseline starts at the bottom of the vertical line of ink, on the line x = 300 the
        // text was drawn along.
        #expect(abs(run.origin.y - text.ink.minY) < 0.5)
        #expect(abs(run.origin.x - 300) < 0.15)
    }

    @Test("a recogniser's characters that cannot be text are counted, with why, and not added")
    func rejectedForCharacters() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let (_, recovery) = try Self.recover(text.content, recogniser: Self.visionLike("---"))
        let report = try #require(recovery.reports[1])
        #expect(report.accepted == 0)
        #expect(report.rejected == [.characters: 1])
        #expect(report.accepted + report.rejectedCount == report.regions)
        #expect(report.decisions.first?.recognised == "---")
        #expect(recovery.document.pages.first?.texts.isEmpty == true)
    }

    @Test("a recognised box that is not where the shapes are is rejected as a position")
    func rejectedForPosition() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let recogniser = InkRecogniser("10,439")
        recogniser.grow = 1.2
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser)
        #expect(recovery.reports[1]?.rejected == [.position: 1])
    }

    @Test("a line turned from the shapes' direction is rejected, after the other way is tried")
    func rejectedForDirection() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let recogniser = InkRecogniser("10,439")
        recogniser.turnDegrees = 12
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser)
        #expect(recovery.reports[1]?.rejected == [.direction: 1])
        // The recogniser said the text runs another way, so it was asked about the other way too.
        #expect(recogniser.calls == 2)
    }

    /// Reads the ink as upside down the first time a reading asks, as Vision does for text that runs
    /// the other way, and the right way up the second time, with `text`.
    final class UpsideDownFirst: TextRecogniser {
        let ink: InkRecogniser
        var calls = 0

        init(_ text: String) { ink = InkRecogniser(text) }

        func lines(in image: CGImage) throws -> [RecognisedLine] {
            calls += 1
            var lines = try ink.lines(in: image)
            if calls % 2 == 1 {
                lines = lines.map { line in
                    var turned = line
                    let c = line.corners
                    turned.corners = [c[2], c[3], c[0], c[1]]
                    return turned
                }
            }
            return lines
        }
    }

    @Test("text that reads upside down in the first crop is read the other way round")
    func upsideDown() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let recogniser = UpsideDownFirst("10,439")
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser)
        // Two crops for each of the three readings.
        #expect(recogniser.calls == 6)
        let report = try #require(recovery.reports[1])
        #expect(report.accepted == 1)
        // The shapes were then read at half a turn: the baseline starts at the ink's top right.
        let run = try #require(recovery.document.pages.first?.texts.first)
        #expect(abs(run.rotationDeg - 180) < 0.5)
        #expect(abs(run.origin.x - text.ink.maxX) < 0.1)
        #expect(abs(run.origin.y - text.ink.maxY) < 0.1)
    }

    @Test("if the other way round fails too, the reason is the second reading's")
    func upsideDownThenImplausible() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        // One character for six shapes.
        let (_, recovery) = try Self.recover(text.content, recogniser: UpsideDownFirst("1"))
        #expect(recovery.reports[1]?.rejected == [.glyphCount: 1])
    }

    /// Reads `texts` in turn, one for each time it is asked, at the confidence it is given.
    final class Sequence: TextRecogniser {
        let ink = InkRecogniser("")
        var texts: [String]
        var confidences: [Double]
        var calls = 0

        init(_ texts: [String], confidences: [Double] = []) {
            self.texts = texts
            self.confidences = confidences
            ink.grow = 0.1
        }

        func lines(in image: CGImage) throws -> [RecognisedLine] {
            ink.text = texts[min(calls, texts.count - 1)]
            ink.confidence =
                confidences.isEmpty ? 1 : confidences[min(calls, confidences.count - 1)]
            calls += 1
            return try ink.lines(in: image)
        }
    }

    @Test("a cluster is read at each size, and accepted if every reading agrees")
    func readingsAgree() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let recogniser = Sequence(["10,439"], confidences: [1, 0.7, 0.9])
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser)
        #expect(recogniser.calls == 3)
        #expect(recovery.reports[1]?.accepted == 1)
        // The least of the readings' confidences.
        #expect(recovery.document.pages.first?.texts.first?.confidence == 0.7)
        // One reading is one call.
        var once = PDF.ShapeTextOptions()
        once.readingPixels = [40]
        let single = Sequence(["10,439"])
        _ = try Self.recover(text.content, recogniser: single, options: once)
        #expect(single.calls == 1)
    }

    @Test("a cluster the readings read differently is rejected as inconsistent")
    func readingsDisagree() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        // The second reading sees another character, as a look-alike at one size would give.
        let (_, recovery) = try Self.recover(
            text.content, recogniser: Sequence(["10,439", "10,430", "10,439"]))
        let report = try #require(recovery.reports[1])
        #expect(report.rejected == [.inconsistent: 1])
        #expect(report.decisions.first?.recognised == "10,439")
        #expect(recovery.document.pages.first?.texts.isEmpty == true)
        // The same characters with other spacing agree.
        let (_, spaced) = try Self.recover(
            text.content, recogniser: Sequence(["10,439", "10, 439", "10,439"]))
        #expect(spaced.reports[1]?.accepted == 1)
    }

    @Test("a cluster a later reading rejects is rejected as inconsistent")
    func laterReadingRejects() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let (_, recovery) = try Self.recover(
            text.content, recogniser: Sequence(["10,439", "10,439", "---"]))
        #expect(recovery.reports[1]?.rejected == [.inconsistent: 1])
    }

    @Test("a low confidence is rejected, and the least confidence is an option")
    func rejectedForConfidence() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let recogniser = Self.visionLike("10,439")
        recogniser.confidence = 0.4
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser)
        #expect(recovery.reports[1]?.rejected == [.lowConfidence: 1])
        var options = PDF.ShapeTextOptions()
        options.minimumConfidence = 0.3
        let (_, allowed) = try Self.recover(
            text.content, recogniser: recogniser, options: options)
        #expect(allowed.reports[1]?.accepted == 1)
        #expect(allowed.document.pages.first?.texts.first?.confidence == 0.4)
    }

    @Test("a recogniser that finds nothing gives no text")
    func rejectedForNoText() throws {
        // Ink is there, but the recogniser reports no line: a recogniser that sees nothing.
        final class Blind: TextRecogniser {
            func lines(in image: CGImage) throws -> [RecognisedLine] { [] }
        }
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let document = try ShapeTextFixtures.document(text.content)
        let recovery = try document.recoveringShapeText(options: .init(), recogniser: Blind())
        #expect(recovery.reports[1]?.rejected == [.noText: 1])
    }

    @Test("a recogniser that fails is counted, not thrown")
    func recogniserFails() throws {
        struct Broken: TextRecogniser {
            func lines(in image: CGImage) throws -> [RecognisedLine] {
                throw PDF.RecognitionError.failed("no model")
            }
        }
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let document = try ShapeTextFixtures.document(text.content)
        let recovery = try document.recoveringShapeText(options: .init(), recogniser: Broken())
        #expect(recovery.reports[1]?.rejected == [.recognitionFailed: 1])
        // The recogniser's own message is kept, since a recogniser that cannot run fails on all.
        #expect(recovery.reports[1]?.recognitionError == "no model")
    }

    @Test(
        "shapes over the size limit are not pieces, and a cluster of too few glyphs is not looked at"
    )
    func sizeAndGlyphLimits() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        var small = PDF.ShapeTextOptions()
        small.maximumShapeSize = 5
        let recogniser = Self.visionLike("10,439")
        let (_, tiny) = try Self.recover(text.content, recogniser: recogniser, options: small)
        #expect((tiny.reports[1]?.shapes ?? 99) < 6)
        #expect(tiny.reports[1]?.regions == 0)
        var many = PDF.ShapeTextOptions()
        many.minimumGlyphs = 7
        let (_, few) = try Self.recover(text.content, recogniser: recogniser, options: many)
        #expect(few.reports[1]?.regions == 0)
        #expect(few.reports[1]?.tooSmall == 1)
        #expect(recogniser.calls == 0)
    }

    @Test("an empty list of reading sizes reads once")
    func noReadingSizes() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        var options = PDF.ShapeTextOptions()
        options.readingPixels = []
        let recogniser = Self.visionLike("10,439")
        let (_, recovery) = try Self.recover(text.content, recogniser: recogniser, options: options)
        #expect(recovery.reports[1]?.accepted == 1)
        #expect(recogniser.calls == 1)
    }

    @Test("a document already recovered is not recovered again: its OCR text is text the page has")
    func recoveredTwice() throws {
        let text = OutlineText.drawn("10,439", at: Self.origin)
        let (_, first) = try Self.recover(text.content, recogniser: Self.visionLike("10,439"))
        #expect(first.reports[1]?.accepted == 1)
        let recogniser = Self.visionLike("10,439")
        let second = try first.document.recoveringShapeText(
            options: .init(), recogniser: recogniser)
        #expect(second.reports[1]?.rejected == [.alreadyRead: 1])
        #expect(recogniser.calls == 0)
        #expect(second.document.pages.first?.texts.count == 1)
    }

    @Test("clusters over the budget are counted and not recognised")
    func budget() throws {
        let first = OutlineText.drawn("BALISE", at: Self.origin)
        let second = OutlineText.drawn("ID PLATE", at: CGPoint(x: 100, y: 60))
        var options = PDF.ShapeTextOptions()
        options.maximumRegions = 1
        let recogniser = Self.visionLike("BALISE")
        let (_, recovery) = try Self.recover(
            first.content + second.content, recogniser: recogniser, options: options)
        let report = try #require(recovery.reports[1])
        #expect(report.regions == 2)
        #expect(report.rejected[.overBudget] == 1)
        #expect(recogniser.calls == options.readingPixels.count)
    }

    // MARK: Text the page already has

    /// Outlines with the same text laid invisibly over them (render mode 3), as some writers do.
    static func outlinesWithInvisibleText() -> String {
        let text = OutlineText.drawn("10,439", at: origin)
        return text.content + "BT /F1 10 Tf 3 Tr 100 100 Td (10,439) Tj ET\n"
    }

    @Test("where the page has the text already, the region is left alone")
    func alreadyRead() throws {
        let recogniser = Self.visionLike("10,439")
        let (document, recovery) = try Self.recover(
            Self.outlinesWithInvisibleText(), recogniser: recogniser,
            resources: ShapeTextFixtures.helveticaResources)
        let report = try #require(recovery.reports[1])
        #expect(document.pages.first?.texts.count == 1)
        #expect(report.regions == 1)
        #expect(report.rejected == [.alreadyRead: 1])
        #expect(report.decisions.first?.readText == "10,439")
        #expect(recogniser.calls == 0)
        #expect(recovery.document.pages.first?.texts.count == 1)
    }

    @Test("a text run across the page covers the shapes on it, not those in its bounding box")
    func diagonalRun() throws {
        // A long line of text at 45 degrees, of about the size of the outlines: its bounding
        // rectangle takes in the corner where they are, which it does not cross.
        let outlines = OutlineText.drawn("10,439", at: CGPoint(x: 300, y: 130))
        let words = String(repeating: "DIAGONAL ", count: 9)
        let content =
            outlines.content
            + "BT /F1 9 Tf 3 Tr 0.7071 0.7071 -0.7071 0.7071 100 100 Tm (\(words)) Tj ET\n"
        let recogniser = Self.visionLike("10,439")
        let (document, recovery) = try Self.recover(
            content, recogniser: recogniser, resources: ShapeTextFixtures.helveticaResources)
        let run = try #require(document.pages.first?.texts.first)
        #expect(run.rotationDeg > 44 && run.rotationDeg < 46)
        // The outlines are inside the run's bounding rectangle.
        let xs = run.quad.map(\.x)
        let ys = run.quad.map(\.y)
        let x0 = try #require(xs.min())
        let x1 = try #require(xs.max())
        let y0 = try #require(ys.min())
        let y1 = try #require(ys.max())
        #expect(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).contains(outlines.ink))
        #expect(recovery.reports[1]?.accepted == 1)
        #expect(recovery.reports[1]?.rejected[.alreadyRead] == nil)
    }

    @Test("compared with the text the page has, the OCR is reported and not added")
    func comparedWithRead() throws {
        var options = PDF.ShapeTextOptions()
        options.existingText = .compare
        let recogniser = Self.visionLike("10,439")
        let (_, recovery) = try Self.recover(
            Self.outlinesWithInvisibleText(), recogniser: recogniser, options: options,
            resources: ShapeTextFixtures.helveticaResources)
        let report = try #require(recovery.reports[1])
        #expect(recogniser.calls == PDF.ShapeTextOptions().readingPixels.count)
        #expect(report.accepted == 1)
        let decision = try #require(report.decisions.first)
        #expect(decision.recognised == "10,439")
        #expect(decision.readText == "10,439")
        // The page's own text stands; nothing is added next to it.
        #expect(recovery.document.pages.first?.texts.count == 1)
        #expect(recovery.document.pages.first?.texts.first?.decoding != .ocr)
    }

    @Test("the report counts every region once")
    func reportAddsUp() throws {
        let first = OutlineText.drawn("BALISE", at: Self.origin)
        let second = OutlineText.drawn("ID PLATE", at: CGPoint(x: 100, y: 60))
        let third = OutlineText.drawn("DETAIL", at: CGPoint(x: 300, y: 100))
        var options = PDF.ShapeTextOptions()
        options.maximumRegions = 2
        let (_, recovery) = try Self.recover(
            first.content + second.content + third.content, recogniser: Self.visionLike("X1"),
            options: options)
        let report = try #require(recovery.reports[1])
        #expect(report.regions == 3)
        #expect(report.decisions.count == 3)
        #expect(report.accepted + report.rejectedCount == report.regions)
    }
}
