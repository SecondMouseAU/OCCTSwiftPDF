import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Circles and arcs recovered from real drawings in the corpus, which is not in the repository.
///
/// The corpus is `PDF_CORPUS`, or `~/Projects/OCCTDesignLoop/drawingfiles` when that is unset.
/// Each test is skipped where its files are absent, as in CI.
@Suite("Arc corpus")
struct ArcCorpusTests {
    @Test(
        "a MicroArts sheet's circles and arcs have the radius and centre of its DXF's, to 0.01 mm",
        .enabled(if: CorpusTests.exists("tecs-pairs/gas.pdf")))
    func gasAgainstItsDXF() throws {
        let page = try #require(
            try PDF.read(contentsOf: CorpusTests.file("tecs-pairs/gas.pdf"), maximumPages: 1)
                .pages.first)
        let reference = try PDF.readReference(at: CorpusTests.file("tecs-pairs/gas_dxf.zip"))
        let placement = try #require(PDF.compare(page.drawing(), with: reference))
        let fitted = page.fittedDrawing()
        let result = PDF.compareArcs(fitted, with: reference, placedBy: placement.placement)
        // Every circle and arc of the drawing has a fit, and every fit a circle or arc.
        #expect(result.referenceCount > 0)
        #expect(result.matches.count == fitted.fits.count)
        #expect(result.unmatchedFits.isEmpty && result.unmatchedReference.isEmpty)
        // 0.01 mm at full size is 0.002 mm on the sheet, drawn at 1:5.
        for match in result.matches {
            #expect(abs(match.radiusError) / placement.scale < 0.01)
            #expect(match.centreError / placement.scale < 0.01)
        }
    }

    @Test(
        "the circles of a Fowler sheet drawn as two halves in two strokes are whole",
        .enabled(if: CorpusTests.exists("PDFs/Fowler 1/Cylinders.pdf")))
    func halvesJoined() throws {
        let page = try #require(
            try PDF.read(contentsOf: CorpusTests.file("PDFs/Fowler 1/Cylinders.pdf")).pages.first)
        let fitted = page.fittedDrawing()
        // Two circles of radius 1 mm about (142.140, 123.519) and (142.140, 117.519), each drawn
        // as a half of three curves and a half of two.
        for y in [123.519, 117.519] {
            let circle = fitted.fits.first {
                $0.shape == .circle && abs($0.center.x - 142.140) < 0.01
                    && abs($0.center.y - y) < 0.01
            }
            if let circle {
                #expect(abs(circle.radius - 1) < 0.005 && circle.sources.count == 2)
            } else {
                Issue.record("no circle at y = \(y)")
            }
        }
    }

    @Test(
        "the SOLIDWORKS thread of a McMaster nut, a spiral of chords, is not cut into arcs",
        .enabled(if: CorpusTests.exists("PDFs/McMaster/94353A325_Right-Hand Acme Flange Nut.PDF")))
    func threadIsNotArcs() throws {
        let page = try #require(
            try PDF.read(
                contentsOf: CorpusTests.file(
                    "PDFs/McMaster/94353A325_Right-Hand Acme Flange Nut.PDF"
                )
            ).pages.first)
        #expect(page.fittedDrawing().fits.isEmpty)
    }
}
