import Foundation
import Testing

@testable import OCCTSwiftPDF

/// `PDF.compareArcs`: recovered circles and arcs against a reference drawing's, on PDFs and
/// references written by hand, so it runs without the corpus.
@Suite("Arc comparison")
struct ArcComparisonTests {
    typealias P = ArcShapes.P

    /// The page: a circle, an arc of one curve, and a small circle.
    static func fitted() throws -> PDF.FittedDrawing {
        var content = ""
        let circle = ArcShapes.bezierArc(centre: P(200, 200), radius: 30, curves: 4)
        content += FittedDrawingTests.operators(circle) + " S "
        let arc = ArcShapes.bezierArc(
            centre: P(300, 400), radius: 40, from: 30, sweep: 90, curves: 1)
        content += FittedDrawingTests.operators(arc) + " S "
        let small = ArcShapes.bezierArc(centre: P(100, 100), radius: 2, curves: 4)
        content += FittedDrawingTests.operators(small) + " S"
        let page = try FittedDrawingTests.page(content)
        return page.fittedDrawing()
    }

    /// Where a reference lies: 1:100, turned a quarter, moved.
    static let placement = PDF.Placement(
        scale: 0.01, rotationDeg: 90, translationX: 12.5, translationY: -7.25)

    /// The reference's own coordinates of a point on the paper, by undoing the placement.
    static func reference(of paper: DXF.Point) -> DXF.Point {
        let turn = Self.placement.rotationDeg * Double.pi / 180
        let dx = (paper.x - Self.placement.translationX) / Self.placement.scale
        let dy = (paper.y - Self.placement.translationY) / Self.placement.scale
        let x = dx * cos(turn) + dy * sin(turn)
        let y = -dx * sin(turn) + dy * cos(turn)
        return DXF.Point(x, y)
    }

    /// The reference drawing for `fits`: a circle, an arc, a point and a circle nothing matches.
    static func referenceDrawing(_ fits: [PDF.ArcFit], arcSpan: (Double, Double)? = nil)
        -> DXF.Drawing
    {
        var entities: [DXF.Entity] = []
        let circle = fits[0]
        entities.append(
            .circle(
                center: reference(of: circle.center), radius: circle.radius / Self.placement.scale,
                layer: "0", color: 7))
        let arc = fits[1]
        let span =
            arcSpan ?? (
                arc.startDeg - Self.placement.rotationDeg - 5,
                arc.endDeg - Self.placement.rotationDeg + 5
            )
        entities.append(
            .arc(
                center: reference(of: arc.center), radius: arc.radius / Self.placement.scale,
                startDeg: span.0, endDeg: span.1, layer: "0", color: 7))
        entities.append(.point(at: reference(of: fits[2].center), layer: "0", color: 7))
        entities.append(
            .circle(center: DXF.Point(5_000, 5_000), radius: 400, layer: "0", color: 7))
        return DXF.Drawing(entities: entities)
    }

    @Test("fits are matched to the reference's circle and arc through the placement")
    func matched() throws {
        let fitted = try Self.fitted()
        #expect(fitted.fits.count == 3)
        let reference = Self.referenceDrawing(fitted.fits)
        let result = PDF.compareArcs(fitted, with: reference, placedBy: Self.placement)
        #expect(result.matches.map(\.fit) == [0, 1])
        try #require(result.matches.count == 2)
        #expect(result.matches.map(\.reference) == [0, 1])
        for match in result.matches {
            // Millimetres on the paper: the curves are a few thousandths out of round.
            #expect(abs(match.radiusError) < 0.01 && match.centreError < 0.01)
        }
        #expect(result.matches[0].referenceIsCircle && result.matches[0].endpointError == nil)
        #expect(!result.matches[1].referenceIsCircle)
        // The reference arc runs 5 degrees past each end of the fit's, and the arc is 40 points
        // (14.1 mm) in radius: each end is 14.1 mm * 5 degrees = 1.23 mm from the fit's.
        if let ends = result.matches[1].endpointError {
            #expect(abs(ends - 1.23) < 0.05, "\(ends)")
        } else {
            Issue.record("no endpoint error for two arcs")
        }
        // The small circle is on a reference point, so it is neither matched nor unmatched.
        #expect(result.pointMarkers == [2] && result.unmatchedFits.isEmpty)
        // The circle nowhere on the paper has no fit.
        #expect(result.referenceCount == 3)
        #expect(result.unmatchedReference.count == 1)
        #expect(result.unmatchedReference.first?.index == 3)
        #expect(result.unmatchedReference.first?.spanDeg == nil)
        // The reference draws the circle and the arc, so most of each fit is on its geometry.
        try #require(result.support.count == 3)
        #expect(result.support[0] > 0.99 && result.support[1] > 0.99)
        // The small circle is only a point there.
        #expect(result.support[2] < 0.5)
    }

    @Test(
        "an arc whose angles do not overlap the reference's, or a circle off by more than the bound, is not matched"
    )
    func notMatched() throws {
        let fitted = try Self.fitted()
        let arc = fitted.fits[1]
        // The reference arc is on the same circle but covers other angles.
        let turn = Self.placement.rotationDeg
        var away = Self.referenceDrawing(
            fitted.fits, arcSpan: (arc.endDeg - turn + 20, arc.endDeg - turn + 120))
        // A point at the arc's centre does not make the arc a point marker: only circles are.
        away.entities.append(.point(at: Self.reference(of: arc.center), layer: "0", color: 7))
        let apart = PDF.compareArcs(fitted, with: away, placedBy: Self.placement)
        #expect(apart.matches.map(\.fit) == [0])
        #expect(apart.unmatchedFits == [1] && apart.pointMarkers == [2])
        // The same circle placed 0.3 mm (on the paper) too far over: matched within 0.5 mm, not
        // within 0.15.
        var moved = Self.referenceDrawing(fitted.fits)
        let circle = fitted.fits[0]
        let shifted = Self.reference(of: DXF.Point(circle.center.x + 0.3, circle.center.y))
        moved.entities[0] = .circle(
            center: shifted, radius: circle.radius / Self.placement.scale, layer: "0", color: 7)
        let near = PDF.compareArcs(
            fitted, with: moved, placedBy: Self.placement, within: 0.5)
        #expect(near.matches.contains { $0.fit == 0 && abs($0.centreError - 0.3) < 0.01 })
        let far = PDF.compareArcs(fitted, with: moved, placedBy: Self.placement, within: 0.15)
        #expect(!far.matches.contains { $0.fit == 0 })
        #expect(far.unmatchedFits.contains(0))
    }

    @Test("the placement's translation and rotation are the ones compare found")
    func placementOfComparison() throws {
        // A page with two texts and a reference with the same texts moved: compare finds the
        // placement, and `placement` carries the scale, the rotation and the translation.
        var content = "BT /F1 12 Tf 100 100 Td (alpha) Tj ET BT /F1 12 Tf 300 400 Td (beta) Tj ET"
        content += " 100 100 m 300 400 l S"
        var pdf = MiniPDF(content: content)
        pdf.resources = "<< /Font << /F1 \(MiniPDF.helvetica) >> >>"
        let page = try #require(try PDF.read(contentsOf: try pdf.file()).pages.first)
        let drawing = page.drawing()
        // The same drawing, moved by (50, -20) mm (a reference in other coordinates).
        var moved = drawing
        moved.entities = drawing.entities.map { entity in
            switch entity {
            case .text(let at, let height, let rotation, let string, let layer, let color):
                return .text(
                    at: DXF.Point(at.x + 50, at.y - 20), height: height, rotationDeg: rotation,
                    string: string, layer: layer, color: color)
            case .line(let a, let b, let layer, let color):
                return .line(
                    a: DXF.Point(a.x + 50, a.y - 20), b: DXF.Point(b.x + 50, b.y - 20),
                    layer: layer, color: color)
            default:
                return entity
            }
        }
        let comparison = try #require(PDF.compare(drawing, with: moved))
        let placement = comparison.placement
        #expect(abs(placement.scale - 1) < 1e-6 && abs(placement.rotationDeg) < 1e-6)
        #expect(abs(placement.translationX + 50) < 1e-3 && abs(placement.translationY - 20) < 1e-3)
    }
}
