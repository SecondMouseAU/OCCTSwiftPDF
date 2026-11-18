import Foundation
import Testing

@testable import OCCTSwiftPDF

/// The spike's comparison of a PDF drawing with a reference drawing of the same sheet.
@Suite("Comparison")
struct ComparisonTests {
    /// A small sheet: a box, a circle and three texts, in the given units and placement.
    static func sheet(scale: Double, dx: Double, dy: Double) -> DXF.Drawing {
        func p(_ x: Double, _ y: Double) -> DXF.Point { DXF.Point(x * scale + dx, y * scale + dy) }
        var entities: [DXF.Entity] = [
            .polyline(
                vertices: [p(0, 0), p(100, 0), p(100, 60), p(0, 60)].map { DXF.PolyVertex($0) },
                closed: true, layer: "0", color: 7),
            .circle(center: p(50, 30), radius: 10 * scale, layer: "0", color: 7),
        ]
        for (string, x, y) in [("100", 45.0, -8.0), ("60", 105.0, 28.0), ("R10", 62.0, 42.0)] {
            entities.append(
                .text(
                    at: p(x, y), height: 3 * scale, rotationDeg: 0, string: string, layer: "0",
                    color: 7))
        }
        return DXF.Drawing(entities: entities)
    }

    @Test("a full-size reference is placed on the paper and found to match")
    func matchingSheet() throws {
        let paper = Self.sheet(scale: 1, dx: 20, dy: 30)
        let fullSize = Self.sheet(scale: 80, dx: -5000, dy: 1200)
        let result = try #require(PDF.compare(paper, with: fullSize))
        #expect(result.anchors == 3)
        #expect(abs(result.scale - 1.0 / 80) < 1e-9)
        #expect(abs(result.rotationDeg) < 1e-6)
        #expect(result.referenceCovered > 0.999)
        #expect(result.pdfCovered > 0.999)
        #expect(result.textsMatched == 3)
    }

    @Test("a text that matches by coincidence does not throw the fit off")
    func coincidentalMatch() throws {
        var paper = Self.sheet(scale: 1, dx: 0, dy: 0)
        var reference = Self.sheet(scale: 80, dx: 0, dy: 0)
        // A fourth value that occurs once in each, but in different places.
        paper.entities.append(
            .text(
                at: DXF.Point(90, 55), height: 3, rotationDeg: 0, string: "B", layer: "0",
                color: 7))
        reference.entities.append(
            .text(
                at: DXF.Point(800, 400), height: 240, rotationDeg: 0, string: "B", layer: "0",
                color: 7))
        let result = try #require(PDF.compare(paper, with: reference))
        #expect(result.anchors == 4)
        #expect(result.anchorsUsed == 3)
        #expect(abs(result.scale - 1.0 / 80) < 1e-9)
        #expect(result.referenceCovered > 0.999)
    }

    @Test("with more than 80 anchors the fit is sampled, and the same each time")
    func repeatable() throws {
        var paper = Self.sheet(scale: 1, dx: 0, dy: 0)
        var reference = Self.sheet(scale: 80, dx: 0, dy: 0)
        for index in 0..<100 {
            let x = Double(index % 10) * 9
            let y = Double(index / 10) * 5
            paper.entities.append(
                .text(
                    at: DXF.Point(x, y), height: 2, rotationDeg: 0, string: "T\(index)",
                    layer: "0", color: 7))
            reference.entities.append(
                .text(
                    at: DXF.Point(x * 80, y * 80), height: 160, rotationDeg: 0,
                    string: "T\(index)", layer: "0", color: 7))
        }
        let first = try #require(PDF.compare(paper, with: reference))
        let second = try #require(PDF.compare(paper, with: reference))
        #expect(first.anchors == 103)
        #expect(abs(first.scale - 1.0 / 80) < 1e-9)
        #expect(first.scale == second.scale && first.anchorResidual == second.anchorResidual)
    }

    @Test("geometry missing from the PDF lowers the reference's coverage")
    func missingGeometry() throws {
        var paper = Self.sheet(scale: 1, dx: 0, dy: 0)
        paper.entities.removeAll { if case .circle = $0 { true } else { false } }
        let result = try #require(PDF.compare(paper, with: Self.sheet(scale: 1, dx: 0, dy: 0)))
        // The circle is about a fifth of the sheet's drawn length.
        #expect(result.referenceCovered < 0.85)
        #expect(result.pdfCovered > 0.999)
    }

    @Test("without two texts in common there is no comparison")
    func tooFewAnchors() {
        let paper = DXF.Drawing(entities: [
            .line(a: DXF.Point(0, 0), b: DXF.Point(1, 0), layer: "0", color: 7)
        ])
        #expect(PDF.compare(paper, with: Self.sheet(scale: 1, dx: 0, dy: 0)) == nil)
    }
}
