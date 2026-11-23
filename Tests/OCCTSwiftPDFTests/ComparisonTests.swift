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
        // The reference's origin on the paper: a reference point p is at p / 80 + (82.5, 15), since
        // the reference's (-5000, 1200) is the paper's (20, 30).
        #expect(abs(result.translation.x - 82.5) < 1e-6)
        #expect(abs(result.translation.y - 15) < 1e-6)
        #expect(result.referenceCovered > 0.999)
        #expect(result.pdfCovered > 0.999)
        #expect(result.textsMatched == 3)
    }

    @Test(
        "a reference turned and scaled is placed by the fit: place(_:) maps its points to the paper"
    )
    func placedPoints() throws {
        let paper = Self.sheet(scale: 1, dx: 20, dy: 30)
        // The same sheet at full size, turned 30 degrees about the origin and moved.
        let turn = 30.0 * Double.pi / 180
        func rotate(_ p: DXF.Point) -> DXF.Point {
            DXF.Point(
                cos(turn) * p.x - sin(turn) * p.y - 900, sin(turn) * p.x + cos(turn) * p.y + 400)
        }
        var entities: [DXF.Entity] = []
        for entity in Self.sheet(scale: 80, dx: 0, dy: 0).entities {
            switch entity {
            case .polyline(let vertices, let closed, let layer, let color):
                entities.append(
                    .polyline(
                        vertices: vertices.map { DXF.PolyVertex(rotate($0.point)) }, closed: closed,
                        layer: layer, color: color))
            case .circle(let center, let radius, let layer, let color):
                entities.append(
                    .circle(center: rotate(center), radius: radius, layer: layer, color: color))
            case .text(let at, let height, _, let string, let layer, let color):
                entities.append(
                    .text(
                        at: rotate(at), height: height, rotationDeg: 30, string: string,
                        layer: layer,
                        color: color))
            default:
                break
            }
        }
        let reference = DXF.Drawing(entities: entities)
        let result = try #require(PDF.compare(paper, with: reference))
        #expect(abs(result.scale - 1.0 / 80) < 1e-6)
        #expect(abs(abs(result.rotationDeg) - 30) < 1e-3)
        // The box's corner (0, 0) of the sheet is on the paper at (20, 30), and (100, 60) at (120, 90).
        let (a, b) = (rotate(DXF.Point(0, 0)), rotate(DXF.Point(100 * 80, 60 * 80)))
        let first = result.place(DXF.Point2(a.x, a.y))
        let second = result.place(DXF.Point2(b.x, b.y))
        #expect(abs(first.x - 20) < 0.01 && abs(first.y - 30) < 0.01)
        #expect(abs(second.x - 120) < 0.01 && abs(second.y - 90) < 0.01)
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

    @Test("a closed polyline of two bulged vertices is sampled all round")
    func twoVertexCircle() {
        let circle = DXF.Drawing(entities: [
            .polyline(
                vertices: [
                    DXF.PolyVertex(DXF.Point(-10, 0), bulge: 1),
                    DXF.PolyVertex(DXF.Point(10, 0), bulge: 1),
                ], closed: true, layer: "0", color: 7)
        ])
        let length = PDF.segments(circle, transform: nil).reduce(0.0) {
            $0 + $1.0.distance(to: $1.1)
        }
        // Chords fall a little short of the arc; half a circle would be 31.4 short.
        #expect(abs(length - 20 * Double.pi) < 0.1)
    }

    @Test("a large arc is cut finely enough to stay within 0.01 mm of the curve")
    func largeArc() {
        let radius = 3000.0
        let n = PDF.pieces(sweep: .pi / 2, radius: radius)
        let chordError = radius * (1 - cos(Double.pi / 2 / Double(n) / 2))
        #expect(chordError <= 0.01 + 1e-12)
    }

    @Test("coordinates too large for the grid are passed over, not a crash")
    func hugeCoordinates() {
        var paper = Self.sheet(scale: 1, dx: 0, dy: 0)
        paper.entities.append(
            .line(a: DXF.Point(0, 0), b: DXF.Point(1e20, 1e12), layer: "0", color: 7))
        let result = PDF.compare(paper, with: Self.sheet(scale: 1, dx: 0, dy: 0))
        #expect(result != nil)
    }

    @Test("a long diagonal across a sheet is indexed and covered")
    func longDiagonal() throws {
        var paper = Self.sheet(scale: 1, dx: 0, dy: 0)
        paper.entities.append(
            .line(a: DXF.Point(0, 0), b: DXF.Point(841, 594), layer: "0", color: 7))
        let result = try #require(PDF.compare(paper, with: paper))
        #expect(result.referenceCovered > 0.999)
        #expect(result.pdfCovered > 0.999)
    }

    @Test("an arc with a NaN angle in the reference is passed over, not a crash")
    func nanArc() {
        let drawing = DXF.Drawing(entities: [
            .arc(
                center: DXF.Point(0, 0), radius: 10, startDeg: .nan, endDeg: 90, layer: "0",
                color: 7)
        ])
        #expect(PDF.segments(drawing, transform: nil).isEmpty)
    }
}
