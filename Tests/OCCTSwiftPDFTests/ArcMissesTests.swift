import Foundation
import Testing

@testable import OCCTSwiftPDF

/// `PDF.missedArcs` and `PDF.fitContacts`: what the PDF drew along a reference arc no fit matched,
/// and what meets the ends of an arc, on pages and references written by hand.
@Suite("Arc misses")
struct ArcMissesTests {
    typealias P = ArcShapes.P

    /// Page units to millimetres on the paper.
    static let millimetres = 25.4 / 72

    /// The reference is already on the paper.
    static let placement = PDF.Placement(
        scale: 1, rotationDeg: 0, translationX: 0, translationY: 0)

    static let centre = P(200, 200)
    static let radius = 40.0

    /// A line that leaves the point of the circle at `degrees` in the direction `heading`, for
    /// `length` page units.
    static func leaving(_ degrees: Double, heading: Double, length: Double = 30) -> ArcElement {
        let from = ArcShapes.point(centre, radius, degrees)
        let turn = heading * Double.pi / 180
        return .line(from, P(from.x + length * cos(turn), from.y + length * sin(turn)))
    }

    /// The reference's arc and the lines that leave its ends, in millimetres.
    static func reference(
        from start: Double, sweep: Double, startHeading: Double, endHeading: Double
    ) -> DXF.Drawing {
        func point(_ p: P) -> DXF.Point { DXF.Point(p.x * millimetres, p.y * millimetres) }
        func line(_ element: ArcElement) -> DXF.Entity {
            .line(a: point(element.start), b: point(element.end), layer: "0", color: 7)
        }
        return DXF.Drawing(entities: [
            .arc(
                center: point(centre), radius: radius * millimetres, startDeg: start,
                endDeg: start + sweep, layer: "0", color: 7),
            line(leaving(start, heading: startHeading)),
            line(leaving(start + sweep, heading: endHeading)),
        ])
    }

    /// The tangent heading at `degrees` beyond the end of an arc that runs counterclockwise.
    static func forward(_ degrees: Double) -> Double { degrees + 90 }
    /// The heading before the start of the same arc.
    static func backward(_ degrees: Double) -> Double { degrees - 90 }

    static func missed(
        _ page: PDF.Page, _ reference: DXF.Drawing
    ) -> [PDF.MissedArc] {
        let fitted = page.fittedDrawing()
        let comparison = PDF.compareArcs(fitted, with: reference, placedBy: placement)
        return PDF.missedArcs(
            on: page, comparison: comparison, reference: reference, placedBy: placement)
    }

    @Test("an arc of one short curve is missed, and the page's curve and tangent lines are seen")
    func curveWithTangentLines() throws {
        // 20 degrees of curve is under what an arc needs, so no fit stands for the reference arc.
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 20, curves: 1)
        let content =
            FittedDrawingTests.operators(arc) + " S "
            + FittedDrawingTests.operators([Self.leaving(10, heading: Self.backward(10))]) + " S "
            + FittedDrawingTests.operators([Self.leaving(30, heading: Self.forward(30))]) + " S"
        let page = try FittedDrawingTests.page(content)
        let reference = Self.reference(
            from: 10, sweep: 20, startHeading: Self.backward(10), endHeading: Self.forward(30))
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        let miss = found[0]
        #expect(miss.reference == 0 && !miss.isCircle)
        #expect(abs(miss.radius - Self.radius * Self.millimetres) < 0.01)
        #expect(abs(miss.sweepDeg - 20) < 0.01)
        // The reference has a line leaving each end in the arc's own direction, and so has the
        // page.
        #expect(miss.referenceContacts == PDF.EndContacts(met: 2, tangent: 2))
        #expect(miss.pdfContacts == PDF.EndContacts(met: 2, tangent: 2))
        // The page draws it as one curve that covers it.
        #expect(miss.support > 0.95 && miss.covered > 0.95)
        #expect(miss.curves == 1 && miss.lines == 0)
        #expect(abs(miss.widestPiece - 20) < 1)
    }

    @Test("a line that leaves at a corner meets the arc's end but not smoothly")
    func corner() throws {
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 20, curves: 1)
        // The line at the end leaves 40 degrees off the arc's direction.
        let content =
            FittedDrawingTests.operators(arc) + " S "
            + FittedDrawingTests.operators([Self.leaving(10, heading: Self.backward(10))]) + " S "
            + FittedDrawingTests.operators([Self.leaving(30, heading: Self.forward(30) + 40)])
            + " S"
        let page = try FittedDrawingTests.page(content)
        let reference = Self.reference(
            from: 10, sweep: 20, startHeading: Self.backward(10), endHeading: Self.forward(30) + 40)
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        #expect(found[0].pdfContacts == PDF.EndContacts(met: 2, tangent: 1))
        #expect(found[0].referenceContacts == PDF.EndContacts(met: 2, tangent: 1))
    }

    @Test("an arc drawn as chords, with the lines in the same polyline, counts its chords")
    func chordsInOnePolyline() throws {
        // Four chords over 20 degrees (fewer than a run of chords needs), with a line before and
        // after in one polyline: the line's end is the arc's, and it leaves smoothly.
        let chords = ArcShapes.flattened(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 20, segments: 4)
        var elements: [ArcElement] = [Self.leaving(10, heading: Self.backward(10))]
        // The leaving line runs away from the arc, so the polyline starts at its far end.
        if case .line(let a, let b) = elements[0] { elements = [.line(b, a)] }
        elements.append(contentsOf: chords)
        let after = Self.leaving(30, heading: Self.forward(30))
        elements.append(after)
        let page = try FittedDrawingTests.page(FittedDrawingTests.operators(elements) + " S")
        let reference = Self.reference(
            from: 10, sweep: 20, startHeading: Self.backward(10), endHeading: Self.forward(30))
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        let miss = found[0]
        #expect(miss.curves == 0 && miss.lines >= 4)
        #expect(miss.longestRun >= 4)
        #expect(miss.covered > 0.9)
        #expect(miss.pdfContacts.tangent == 2)
    }

    @Test("the chords of the arc itself are not its neighbours")
    func sameCircle() throws {
        let chords = ArcShapes.flattened(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 20, segments: 4)
        let page = try FittedDrawingTests.page(FittedDrawingTests.operators(chords) + " S")
        let reference = Self.reference(
            from: 10, sweep: 20, startHeading: Self.backward(10), endHeading: Self.forward(30))
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        #expect(found[0].pdfContacts == PDF.EndContacts(met: 0, tangent: 0))
        #expect(found[0].lines == 4 && found[0].longestRun == 4)
    }

    @Test("a reference arc the page does not draw has no support")
    func notDrawn() throws {
        let page = try FittedDrawingTests.page("10 10 m 100 10 l S")
        let reference = Self.reference(
            from: 10, sweep: 20, startHeading: Self.backward(10), endHeading: Self.forward(30))
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        #expect(found[0].support < 0.1 && found[0].covered == 0)
        #expect(found[0].pdfContacts == PDF.EndContacts(met: 0, tangent: 0))
    }

    @Test("a fit that is found is not missed")
    func found() throws {
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 90, curves: 1)
        let page = try FittedDrawingTests.page(FittedDrawingTests.operators(arc) + " S")
        let reference = Self.reference(
            from: 10, sweep: 90, startHeading: Self.backward(10), endHeading: Self.forward(100))
        // The two lines are not arcs or circles, so only the arc is a reference round.
        #expect(Self.missed(page, reference).isEmpty)
    }

    @Test("fitContacts sees the lines that leave each fitted arc, and a circle has none")
    func contacts() throws {
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 90, curves: 1)
        let circle = ArcShapes.bezierArc(centre: P(400, 400), radius: 20, curves: 4)
        let content =
            FittedDrawingTests.operators(arc) + " S "
            + FittedDrawingTests.operators([Self.leaving(10, heading: Self.backward(10))]) + " S "
            + FittedDrawingTests.operators([Self.leaving(100, heading: Self.forward(100))]) + " S "
            + FittedDrawingTests.operators(circle) + " S"
        let page = try FittedDrawingTests.page(content)
        let fitted = page.fittedDrawing()
        try #require(fitted.fits.count == 2)
        let contacts = PDF.fitContacts(fitted, on: page)
        let shapes = fitted.fits.map(\.shape)
        let arcAt = try #require(shapes.firstIndex(of: .arc))
        let circleAt = try #require(shapes.firstIndex(of: .circle))
        #expect(contacts[arcAt] == PDF.EndContacts(met: 2, tangent: 2))
        #expect(contacts[circleAt] == PDF.EndContacts(met: 0, tangent: 0))
    }
}
