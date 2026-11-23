import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// `Page.fittedDrawing(_:)` on PDFs written by hand: what becomes a circle or an arc, with what
/// fit, and that `drawing()` is left as it was.
@Suite("Fitted drawing")
struct FittedDrawingTests {
    typealias P = ArcShapes.P

    static func number(_ value: Double) -> String { String(format: "%.6f", value) }

    /// The path operators for `elements`, in page units: a move to the first start, then each
    /// line or curve.
    static func operators(_ elements: [ArcElement]) -> String {
        guard let first = elements.first else { return "" }
        var out = "\(number(first.start.x)) \(number(first.start.y)) m"
        for element in elements {
            switch element {
            case .line(_, let b):
                out += " \(number(b.x)) \(number(b.y)) l"
            case .curve(_, let c1, let c2, let d):
                out += " \(number(c1.x)) \(number(c1.y)) \(number(c2.x)) \(number(c2.y))"
                out += " \(number(d.x)) \(number(d.y)) c"
            }
        }
        return out
    }

    static func page(_ content: String, rotate: Int = 0) throws -> PDF.Page {
        var pdf = MiniPDF(content: content)
        pdf.rotate = rotate
        let document = try PDF.read(contentsOf: try pdf.file())
        return try #require(document.pages.first)
    }

    /// The sentence a test reads: an entity as text, to compare drawings entity by entity.
    static func described(_ drawing: DXF.Drawing) -> [String] {
        drawing.entities.indices.map {
            "\(drawing.entities[$0]) \(drawing.identity(ofEntityAt: $0).id)"
        }
    }

    static let inch = 72.0
    static let centre = P(200, 200)

    // MARK: What is recovered

    @Test("a one-inch circle drawn as four curves is one circle of 25.4 mm, tagged FITTED")
    func inchCircle() throws {
        let elements = ArcShapes.bezierArc(centre: Self.centre, radius: Self.inch, curves: 4)
        let page = try Self.page(Self.operators(elements) + " S")
        let fitted = page.fittedDrawing()
        #expect(fitted.drawing.counts.circle == 1 && fitted.drawing.counts.spline == 0)
        #expect(fitted.drawing.entities.count == 1)
        let fit = try #require(fitted.fits.first)
        #expect(fit.shape == .circle && fit.input == .curves && fit.segments == 4)
        // SwiftDXF's Entity.fitted gives arcs of 25.29 mm for these four curves.
        #expect(abs(fit.radius - 25.4) < 0.01)
        #expect(fit.maxResidual < 0.01 && fit.rmsResidual <= fit.maxResidual)
        #expect(fit.sweepDeg == 360)
        let expected = CGPoint(x: 200, y: 200).applying(page.toPaper)
        #expect(abs(fit.center.x - expected.x) < 0.01 && abs(fit.center.y - expected.y) < 0.01)
        guard case .circle(let centre, let radius, _, _) = fitted.drawing.entities[0] else {
            Issue.record("not a circle")
            return
        }
        #expect(centre == fit.center && radius == fit.radius)
        let locator = fitted.drawing.identity(ofEntityAt: 0).id
        #expect(locator.hasPrefix("p1:op") && locator.hasSuffix(":0:FITTED"))
        #expect(PDF.ArcFit.provenance == "FITTED")
        #expect(fitted.fit(atEntity: 0)?.radius == fit.radius)
        #expect(fitted.curvesReplaced == 4 && fitted.linesReplaced == 0)
    }

    @Test("drawing() is left as it was: the same circle is still four splines")
    func defaultUnchanged() throws {
        let elements = ArcShapes.bezierArc(centre: Self.centre, radius: Self.inch, curves: 4)
        let page = try Self.page(Self.operators(elements) + " S")
        let drawing = page.drawing()
        #expect(drawing.counts.spline == 4 && drawing.counts.circle == 0 && drawing.counts.arc == 0)
        let locator = drawing.identity(ofEntityAt: 0).id
        #expect(
            locator.hasPrefix("p1:op") && locator.hasSuffix(":0") && !locator.contains("FITTED"))
    }

    @Test("with nothing to recover, fittedDrawing is exactly drawing()")
    func nothingRecovered() throws {
        // A rectangle, a zigzag, an ellipse (as four curves) and a line.
        var content = "10 10 100 50 re S "
        content += "300 300 m 320 340 l 340 300 l 360 340 l S "
        let ellipse = ArcShapes.ellipseCurves(centre: Self.centre, a: 90, b: 72)
        content += Self.operators(ellipse) + " S "
        content += "0 0 m 50 50 l S"
        let page = try Self.page(content)
        let fitted = page.fittedDrawing()
        #expect(fitted.fits.isEmpty)
        #expect(Self.described(fitted.drawing) == Self.described(page.drawing()))
        #expect(fitted.drawing.counts == page.drawing().counts)
        #expect(fitted.drawing.skipped == page.drawing().skipped)
    }

    @Test("an eccentric ellipse of four curves is not a circle or an arc")
    func ellipse() throws {
        let curves = ArcShapes.ellipseCurves(centre: Self.centre, a: 90, b: 72)
        let fitted = try Self.page(Self.operators(curves) + " S").fittedDrawing()
        #expect(fitted.fits.isEmpty)
        #expect(fitted.drawing.counts.spline == 4)
    }

    @Test("a circle of straight chords is one circle; a hexagon and a square are not")
    func flattened() throws {
        let chords = ArcShapes.flattened(centre: Self.centre, radius: 30, segments: 48)
        let circle = try Self.page(Self.operators(chords) + " h S").fittedDrawing()
        #expect(circle.fits.count == 1 && circle.fits[0].shape == .circle)
        #expect(circle.fits[0].input == .lines && circle.fits[0].segments == 48)
        #expect(abs(circle.fits[0].radius - 30 * 25.4 / 72) < 1e-4)
        #expect(circle.drawing.counts.polyline == 0 && circle.drawing.counts.line == 0)
        #expect(circle.linesReplaced == 48)
        for sides in [4, 6, 8] {
            let polygon = ArcShapes.polygon(centre: Self.centre, radius: 30, sides: sides)
            let drawn = try Self.page(Self.operators(polygon) + " h S").fittedDrawing()
            #expect(drawn.fits.isEmpty, "\(sides) sides")
            #expect(drawn.drawing.counts.polyline == 1, "\(sides) sides")
        }
    }

    @Test("an arc is an arc entity counterclockwise whichever way it was drawn")
    func direction() throws {
        let counter = ArcShapes.bezierArc(
            centre: Self.centre, radius: 60, from: 30, sweep: 90, curves: 1)
        let clockwise = ArcShapes.bezierArc(
            centre: Self.centre, radius: 60, from: 120, sweep: -90, curves: 1)
        for elements in [counter, clockwise] {
            let fitted = try Self.page(Self.operators(elements) + " S").fittedDrawing()
            let fit = try #require(fitted.fits.first)
            #expect(fit.shape == .arc && abs(fit.sweepDeg - 90) < 0.1)
            #expect(abs(fit.startDeg - 30) < 0.1 && abs(fit.endDeg - 120) < 0.1)
            guard case .arc(_, let radius, let start, let end, _, _) = fitted.drawing.entities[0]
            else {
                Issue.record("not an arc")
                return
            }
            #expect(abs(radius - 60 * 25.4 / 72) < 0.01)
            #expect(abs(start - 30) < 0.1 && abs(end - 120) < 0.1)
        }
    }

    @Test("a rounded rectangle is four lines and four arcs of the corner radius")
    func roundedRectangle() throws {
        // Corner radius 10 points, sides between the corners' arcs.
        let corners: [(P, Double)] = [
            (P(190, 110), 270), (P(290, 110), 0), (P(290, 210), 90), (P(190, 210), 180),
        ]
        var elements: [ArcElement] = []
        var arcs: [ArcElement] = []
        for (corner, from) in corners {
            arcs.append(
                contentsOf: ArcShapes.bezierArc(
                    centre: corner, radius: 10, from: from, sweep: 90, curves: 1))
        }
        for index in 0..<4 {
            elements.append(arcs[index])
            elements.append(.line(arcs[index].end, arcs[(index + 1) % 4].start))
        }
        let fitted = try Self.page(Self.operators(elements) + " h S").fittedDrawing()
        #expect(fitted.fits.count == 4)
        for fit in fitted.fits {
            #expect(fit.shape == .arc && abs(fit.radius - 10 * 25.4 / 72) < 0.01)
            #expect(abs(fit.sweepDeg - 90) < 0.1)
        }
        #expect(fitted.drawing.counts.arc == 4 && fitted.drawing.counts.line == 4)
        #expect(fitted.drawing.counts.circle == 0 && fitted.drawing.counts.spline == 0)
    }

    @Test("a page turned a quarter has the circle where the sheet shows it")
    func rotatedPage() throws {
        let elements = ArcShapes.bezierArc(centre: P(150, 300), radius: 40, curves: 4)
        let page = try Self.page(Self.operators(elements) + " S", rotate: 90)
        let fit = try #require(page.fittedDrawing().fits.first)
        let expected = CGPoint(x: 150, y: 300).applying(page.toPaper)
        #expect(abs(fit.center.x - expected.x) < 0.01 && abs(fit.center.y - expected.y) < 0.01)
        #expect(abs(fit.radius - 40 * 25.4 / 72) < 0.01)
    }

    @Test("a filled circle is left out, and a stroked one keeps its colour")
    func paintAndColour() throws {
        let elements = ArcShapes.bezierArc(centre: Self.centre, radius: 30, curves: 4)
        let path = Self.operators(elements)
        let page = try Self.page("\(path) f 1 0 0 RG \(path) S")
        let fitted = page.fittedDrawing()
        #expect(fitted.drawing.skipped["FILL"] == 1)
        #expect(fitted.fits.count == 1)
        guard case .circle(_, _, _, let colour) = fitted.drawing.entities[0] else {
            Issue.record("not a circle")
            return
        }
        #expect(colour == 1)
    }

    // MARK: Arcs split between strokes

    @Test("a circle drawn as two half circles in two strokes is one circle, with both sources")
    func splitCircle() throws {
        let upper = ArcShapes.bezierArc(
            centre: Self.centre, radius: 50, from: 0, sweep: 180, curves: 2)
        let lower = ArcShapes.bezierArc(
            centre: Self.centre, radius: 50, from: 180, sweep: 180, curves: 2)
        // DraftingCAD draws the halves with different pens.
        let content =
            "0.72 w \(Self.operators(upper)) S 0.24 w \(Self.operators(lower)) S"
        let fitted = try Self.page(content).fittedDrawing()
        #expect(fitted.drawing.entities.count == 1 && fitted.drawing.counts.circle == 1)
        #expect(fitted.drawing.counts.arc == 0)
        let fit = try #require(fitted.fits.first)
        #expect(fit.shape == .circle && fit.segments == 4 && fit.sources.count == 2)
        #expect(abs(fit.radius - 50 * 25.4 / 72) < 0.01)
        #expect(fit.entityIndex == 0)
        // The width is that of the stroke drawn first: 0.72 points.
        #expect(abs(fit.lineWidth - 0.72 * 25.4 / 72) < 1e-6)
        #expect(fitted.drawing.identity(ofEntityAt: 0).id.hasSuffix(":FITTED"))
    }

    @Test("two arcs that do not make one circle are not joined: another circle, another colour")
    func notJoined() throws {
        let upper = ArcShapes.bezierArc(
            centre: Self.centre, radius: 50, from: 0, sweep: 180, curves: 2)
        let lower = ArcShapes.bezierArc(
            centre: Self.centre, radius: 50, from: 180, sweep: 180, curves: 2)
        // The same two halves, the second in red.
        let colours = try Self.page(
            "\(Self.operators(upper)) S 1 0 0 RG \(Self.operators(lower)) S"
        ).fittedDrawing()
        #expect(colours.fits.count == 2 && colours.drawing.counts.arc == 2)
        // The second half on a circle 2 points bigger, so the ends do not meet.
        let bigger = ArcShapes.bezierArc(
            centre: Self.centre, radius: 52, from: 180, sweep: 180, curves: 2)
        let radii = try Self.page(
            "\(Self.operators(upper)) S \(Self.operators(bigger)) S"
        ).fittedDrawing()
        #expect(radii.fits.count == 2 && radii.drawing.counts.arc == 2)
    }

    @Test("a half circle of curves and a half circle of chords make one circle")
    func mixedHalves() throws {
        let curves = ArcShapes.bezierArc(
            centre: Self.centre, radius: 50, from: 0, sweep: 180, curves: 2)
        let chords = ArcShapes.flattened(
            centre: Self.centre, radius: 50, from: 180, sweep: 180, segments: 24)
        let fitted = try Self.page(
            "\(Self.operators(curves)) S \(Self.operators(chords)) S"
        ).fittedDrawing()
        // Both halves fit one circle, but a run of curves and a run of lines are held to
        // different tolerances, and both are within the larger.
        #expect(fitted.drawing.entities.count == 1)
        #expect(fitted.fits.first?.shape == .circle && fitted.fits.first?.input == .mixed)
    }

    @Test("a circle of twelve curves in twelve strokes is one circle, though each piece is short")
    func twelveStrokes() throws {
        var content = ""
        let pieces = ArcShapes.bezierArc(centre: Self.centre, radius: 50, curves: 12)
        for piece in pieces { content += Self.operators([piece]) + " S " }
        let fitted = try Self.page(content).fittedDrawing()
        #expect(fitted.drawing.entities.count == 1 && fitted.drawing.counts.circle == 1)
        #expect(fitted.fits.first?.sources.count == 12)
        // Each piece alone sweeps 30 degrees, which is under what an arc needs, and one piece
        // with no neighbour is left as the spline it was.
        let alone = try Self.page(Self.operators([pieces[0]]) + " S").fittedDrawing()
        #expect(alone.fits.isEmpty && alone.drawing.counts.spline == 1)
        let two = try Self.page(
            Self.operators([pieces[0]]) + " S " + Self.operators([pieces[1]]) + " S"
        ).fittedDrawing()
        // Two pieces make 60 degrees: one arc.
        #expect(two.fits.count == 1 && abs(two.fits[0].sweepDeg - 60) < 0.1)
    }

    @Test("a fit says where its entity is among the others, and the others keep their places")
    func entityIndex() throws {
        let circle = ArcShapes.bezierArc(centre: Self.centre, radius: 40, curves: 4)
        let content =
            "10 10 m 90 90 l S 5 5 20 20 re S " + Self.operators(circle) + " S 0 0 m 9 9 l S"
        let fitted = try Self.page(content).fittedDrawing()
        let fit = try #require(fitted.fits.first)
        #expect(fitted.fits.count == 1 && fit.entityIndex == 2)
        #expect(fitted.fit(atEntity: 2)?.radius == fit.radius)
        #expect(fitted.fit(atEntity: 0) == nil && fitted.fit(atEntity: 3) == nil)
        guard case .circle = fitted.drawing.entities[2] else {
            Issue.record("entity 2 is not the circle")
            return
        }
        // A line, a rectangle, the circle, a line.
        #expect(fitted.drawing.entities.count == 4 && fitted.drawing.counts.circle == 1)
        #expect(fitted.drawing.identities.count == 4)
    }

    @Test("the pieces of a path after a recovered circle are numbered from where it left off")
    func pieceNumbers() throws {
        let circle = ArcShapes.bezierArc(centre: Self.centre, radius: 40, curves: 4)
        // One path: the circle's four curves, then a line.
        let content = Self.operators(circle) + " 5 5 m 60 60 l S"
        let page = try Self.page(content)
        let plain = page.drawing()
        let fitted = page.fittedDrawing().drawing
        #expect(plain.entities.count == 5 && fitted.entities.count == 2)
        #expect(plain.identity(ofEntityAt: 4).id.hasSuffix(":4"))
        #expect(fitted.identity(ofEntityAt: 0).id.hasSuffix(":0:FITTED"))
        #expect(fitted.identity(ofEntityAt: 1).id.hasSuffix(":1"))
    }
}
