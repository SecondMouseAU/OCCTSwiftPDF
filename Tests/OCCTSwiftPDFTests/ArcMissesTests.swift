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

    @Test("a reference whole circle the page does not draw is missed with no support")
    func wholeCircle() throws {
        let drawn = ArcShapes.bezierArc(centre: Self.centre, radius: Self.radius, curves: 4)
        let page = try FittedDrawingTests.page(FittedDrawingTests.operators(drawn) + " S")
        func mm(_ p: P) -> DXF.Point { DXF.Point(p.x * Self.millimetres, p.y * Self.millimetres) }
        let reference = DXF.Drawing(entities: [
            .circle(
                center: mm(P(500, 500)), radius: Self.radius * Self.millimetres, layer: "0",
                color: 7)
        ])
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        #expect(found[0].isCircle && found[0].sweepDeg == 360 && found[0].support < 0.1)
        #expect(found[0].referenceContacts == PDF.EndContacts(met: 0, tangent: 0))
    }

    @Test("an arc across 0 degrees that the page draws as a short curve is covered")
    func wrappedCover() throws {
        // 20 degrees is under the curve floor, so the arc is missed, and it spans 350 to 10.
        // The page's curve starts 0.4 degrees before the reference's 350 and ends 0.4 after 10.
        let curve = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 349.6, sweep: 20.8, curves: 1)
        let page = try FittedDrawingTests.page(FittedDrawingTests.operators(curve) + " S")
        func mm(_ p: P) -> DXF.Point { DXF.Point(p.x * Self.millimetres, p.y * Self.millimetres) }
        let reference = DXF.Drawing(entities: [
            .arc(
                center: mm(Self.centre), radius: Self.radius * Self.millimetres, startDeg: 350,
                endDeg: 10, layer: "0", color: 7)
        ])
        let found = Self.missed(page, reference)
        try #require(found.count == 1)
        #expect(abs(found[0].sweepDeg - 20) < 0.01)
        #expect(found[0].covered > 0.9 && found[0].curves == 1)
    }

    @Test("a placement that scales, turns and moves the reference is undone")
    func placed() throws {
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: Self.radius, from: 10, sweep: 20, curves: 1)
        let content =
            FittedDrawingTests.operators(arc) + " S "
            + FittedDrawingTests.operators([Self.leaving(30, heading: Self.forward(30))]) + " S"
        let page = try FittedDrawingTests.page(content)
        // The reference at 1:100, turned a quarter, moved: its own coordinates of the paper's.
        let placement = ArcComparisonTests.placement
        func reference(of p: P) -> DXF.Point {
            ArcComparisonTests.reference(
                of: DXF.Point(p.x * Self.millimetres, p.y * Self.millimetres))
        }
        let end = ArcShapes.point(Self.centre, Self.radius, 30)
        let away = Self.leaving(30, heading: Self.forward(30))
        let drawing = DXF.Drawing(entities: [
            .arc(
                center: reference(of: Self.centre),
                radius: Self.radius * Self.millimetres / placement.scale,
                startDeg: 10 - placement.rotationDeg, endDeg: 30 - placement.rotationDeg,
                layer: "0", color: 7),
            .line(a: reference(of: end), b: reference(of: away.end), layer: "0", color: 7),
        ])
        let fitted = page.fittedDrawing()
        let comparison = PDF.compareArcs(fitted, with: drawing, placedBy: placement)
        let found = PDF.missedArcs(
            on: page, comparison: comparison, reference: drawing, placedBy: placement)
        try #require(found.count == 1)
        let miss = found[0]
        #expect(abs(miss.radius - Self.radius * Self.millimetres) < 0.01)
        #expect(abs(miss.sweepDeg - 20) < 0.01)
        // The line leaves the end smoothly in the reference as it does on the page; the start has
        // no line in the reference.
        #expect(miss.referenceContacts == PDF.EndContacts(met: 1, tangent: 1))
        #expect(miss.pdfContacts == PDF.EndContacts(met: 1, tangent: 1))
        #expect(miss.support > 0.9 && miss.covered > 0.9)
    }

    @Test("the ends of an arc and a spline, placed by a similarity, leave in the right direction")
    func ends() throws {
        let arc = DXF.Entity.arc(
            center: DXF.Point(0, 0), radius: 10, startDeg: 0, endDeg: 90, layer: "0", color: 7)
        let spline = DXF.Entity.spline(
            DXF.Spline(
                degree: 3,
                controlPoints: [
                    DXF.Point(0, 0), DXF.Point(1, 0), DXF.Point(2, 1), DXF.Point(3, 3),
                ]))
        let drawing = DXF.Drawing(entities: [arc, spline])
        func near(_ a: DXF.Point2, _ x: Double, _ y: Double) -> Bool {
            abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9
        }
        // Plain: the arc starts at (10, 0) heading up and ends at (0, 10) heading right; the
        // spline leaves (0, 0) along its first edge and (3, 3) back along its last.
        let plain = PDF.pieceEnds(drawing, transform: nil)
        try #require(plain.count == 4)
        #expect(near(plain[0].point, 10, 0) && near(plain[0].direction, 0, 1))
        #expect(near(plain[1].point, 0, 10) && near(plain[1].direction, 1, 0))
        #expect(near(plain[2].point, 0, 0) && near(plain[2].direction, 1, 0))
        #expect(near(plain[2].far, 3, 3))
        let back = 5.0.squareRoot()
        #expect(near(plain[3].point, 3, 3) && near(plain[3].direction, -1 / back, -2 / back))
        #expect(near(plain[3].far, 0, 0))
        // Twice the size, turned a quarter, moved by (5, 0).
        let placed = PDF.pieceEnds(
            drawing, transform: PDF.Similarity(scale: 2, rotation: Double.pi / 2, tx: 5, ty: 0))
        try #require(placed.count == 4)
        #expect(near(placed[0].point, 5, 20) && near(placed[0].direction, -1, 0))
        #expect(near(placed[1].point, -15, 0) && near(placed[1].direction, 0, 1))
        #expect(near(placed[2].point, 5, 0) && near(placed[2].direction, 0, 1))
    }

    @Test("an arc whose neighbours are another arc and a spline is met smoothly at both ends")
    func arcAndSplineNeighbours() throws {
        let r = Self.radius * Self.millimetres
        let c = DXF.Point2(Self.centre.x * Self.millimetres, Self.centre.y * Self.millimetres)
        func on(_ centre: DXF.Point2, _ radius: Double, _ degrees: Double) -> DXF.Point2 {
            let angle = degrees * Double.pi / 180
            return DXF.Point2(
                centre.x + radius * cos(angle), centre.y + radius * sin(angle))
        }
        // At the end (30 degrees): a circle of half the radius, tangent inside the first there,
        // with its arc leaving counterclockwise, the first's own direction.
        let end = on(c, r, 30)
        let inner = on(end, -r / 2, 30)
        let second = DXF.Entity.arc(
            center: DXF.Point(inner.x, inner.y), radius: r / 2, startDeg: 30, endDeg: 70,
            layer: "0", color: 7)
        // At the start (10 degrees): a spline whose first edge leaves along the tangent, away
        // from the arc.
        let start = on(c, r, 10)
        let heading = 10.0 * Double.pi / 180
        let next = DXF.Point(start.x + 5 * sin(heading), start.y - 5 * cos(heading))
        let spline = DXF.Entity.spline(
            DXF.Spline(
                degree: 3,
                controlPoints: [
                    DXF.Point(start.x, start.y), next, DXF.Point(next.x + 5, next.y - 5),
                    DXF.Point(next.x + 10, next.y - 20),
                ]))
        let drawing = DXF.Drawing(entities: [second, spline])
        let index = PDF.PieceEndIndex(PDF.pieceEnds(drawing, transform: nil))
        let both = PDF.endContacts(
            centre: c, radius: r, startDeg: 10, endDeg: 30, in: index, join: 0.2)
        #expect(both == PDF.EndContacts(met: 2, tangent: 2))
        // The same arc, with a spline that leaves the start 40 degrees off: met, not smooth.
        let turned = 50.0 * Double.pi / 180
        let slanted = DXF.Entity.spline(
            DXF.Spline(
                degree: 3,
                controlPoints: [
                    DXF.Point(start.x, start.y),
                    DXF.Point(start.x + 5 * sin(turned), start.y - 5 * cos(turned)),
                    DXF.Point(start.x + 9, start.y - 12), DXF.Point(start.x + 12, start.y - 30),
                ]))
        let bent = PDF.PieceEndIndex(
            PDF.pieceEnds(DXF.Drawing(entities: [second, slanted]), transform: nil))
        let corner = PDF.endContacts(
            centre: c, radius: r, startDeg: 10, endDeg: 30, in: bent, join: 0.2)
        #expect(corner == PDF.EndContacts(met: 2, tangent: 1))
    }

    @Test("coordinates too large to count cells in, and a reference arc as large, do not trap")
    func hugeValues() throws {
        #expect(PDF.PieceEndIndex.index(1e300, cell: 2) == nil)
        #expect(PDF.PieceEndIndex.index(.nan, cell: 2) == nil)
        #expect(PDF.PieceEndIndex.index(-3.5, cell: 2) == -2)
        let far = DXF.Point2(1e300, 1e300)
        let index = PDF.PieceEndIndex(
            [PDF.PieceEnd(point: far, direction: DXF.Point2(1, 0), far: far)])
        #expect(index.near(far, within: 0.2).isEmpty)

        let page = try FittedDrawingTests.page("10 10 m 100 10 l S")
        let reference = DXF.Drawing(entities: [
            .arc(
                center: DXF.Point(0, 0), radius: 1e12, startDeg: 0, endDeg: 90, layer: "0",
                color: 7),
            .circle(center: DXF.Point(1e300, 1e300), radius: 5, layer: "0", color: 7),
        ])
        let found = Self.missed(page, reference)
        #expect(found.count <= 2)
        for miss in found { #expect(miss.covered == 0 && miss.curves == 0 && miss.lines == 0) }
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
