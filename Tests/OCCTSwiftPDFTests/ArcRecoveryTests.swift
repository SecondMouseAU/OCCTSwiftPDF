import CoreGraphics
import Foundation
import Testing

@testable import OCCTSwiftPDF

/// Circles and arcs recovered from runs of curves and of short lines.
@Suite("Arc recovery")
struct ArcRecoveryTests {
    typealias P = ArcShapes.P
    static let options = PDF.ArcFitting()
    static let centre = P(100, 80)

    static func recover(_ elements: [ArcElement]) -> [RecoveredArc] {
        ArcRecovery.recover(elements, options)
    }

    // MARK: What is taken

    @Test("a circle drawn as four Bezier curves is one circle with the radius over the whole run")
    func fourCurveCircle() throws {
        let found = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 25.4, curves: 4))
        let arc = try #require(found.first)
        #expect(found.count == 1 && arc.isCircle && arc.range == 0..<4)
        // SwiftDXF's per-curve fit gives 25.29 here. Four curves are 0.03 percent out of round.
        #expect(abs(arc.circle.radius - 25.4) < 0.005)
        #expect(abs(arc.circle.centre.x - 100) < 1e-3 && abs(arc.circle.centre.y - 80) < 1e-3)
        #expect(arc.maxResidual < 0.01)
    }

    @Test("a circle drawn as eight curves, or as a hundred chords, is one circle")
    func otherCircles() throws {
        let eight = Self.recover(ArcShapes.bezierArc(centre: Self.centre, radius: 7, curves: 8))
        #expect(eight.count == 1 && eight[0].isCircle && abs(eight[0].circle.radius - 7) < 1e-3)
        let chords = Self.recover(
            ArcShapes.flattened(centre: Self.centre, radius: 12.5, segments: 100))
        #expect(chords.count == 1 && chords[0].isCircle)
        // The chords' ends are on the circle exactly.
        #expect(abs(chords[0].circle.radius - 12.5) < 1e-9)
    }

    @Test("a circle that starts anywhere, and one that goes clockwise, is still one circle")
    func startAndDirection() throws {
        let off = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 30, from: 37, sweep: 360, curves: 4))
        #expect(off.count == 1 && off[0].isCircle)
        let clockwise = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 30, from: 90, sweep: -360, curves: 4))
        #expect(clockwise.count == 1 && clockwise[0].isCircle && clockwise[0].sweep < 0)
    }

    @Test("a quarter arc of one curve, and of chords, is an arc with its ends")
    func partialArcs() throws {
        let curve = try #require(
            Self.recover(
                ArcShapes.bezierArc(
                    centre: Self.centre, radius: 20, from: 30, sweep: 90, curves: 1)
            ).first)
        #expect(!curve.isCircle && abs(curve.circle.radius - 20) < 0.005)
        #expect(abs(curve.firstDeg - 30) < 0.05 && abs(curve.lastDeg - 120) < 0.05)
        let chords = try #require(
            Self.recover(
                ArcShapes.flattened(
                    centre: Self.centre, radius: 20, from: 200, sweep: 120, segments: 12)
            ).first)
        #expect(!chords.isCircle && chords.range == 0..<12)
        #expect(abs(chords.circle.radius - 20) < 1e-9)
        #expect(abs(chords.firstDeg - 200) < 1e-6 && abs(chords.lastDeg - 320) < 1e-6)
    }

    @Test("an arc drawn clockwise has a negative sweep")
    func clockwise() throws {
        let arc = try #require(
            Self.recover(
                ArcShapes.flattened(
                    centre: Self.centre, radius: 20, from: 120, sweep: -90, segments: 9)
            ).first)
        #expect(arc.sweep < 0)
        #expect(abs(arc.firstDeg - 120) < 1e-6 && abs(arc.lastDeg - 30) < 1e-6)
    }

    @Test("lines then an arc then lines: only the arc is taken")
    func arcBetweenLines() throws {
        var elements: [ArcElement] = []
        let arc = ArcShapes.bezierArc(
            centre: Self.centre, radius: 10, from: 270, sweep: 90, curves: 1)
        let start = arc[0].start
        let end = arc[0].end
        elements.append(.line(P(start.x - 40, start.y), start))
        elements.append(contentsOf: arc)
        elements.append(.line(end, P(end.x, end.y + 40)))
        let found = Self.recover(elements)
        #expect(found.count == 1)
        #expect(found.first?.range == 1..<2)
    }

    @Test("a slot is two arcs, each of two curves, between two lines")
    func slot() throws {
        // A 40 by 10 slot: end arcs of radius 5 about (0, 0) and (40, 0).
        let left = P(0, 0)
        let right = P(40, 0)
        var elements: [ArcElement] = []
        elements.append(.line(P(0, -5), P(40, -5)))
        elements.append(
            contentsOf: ArcShapes.bezierArc(
                centre: right, radius: 5, from: -90, sweep: 180, curves: 2))
        elements.append(.line(P(40, 5), P(0, 5)))
        elements.append(
            contentsOf: ArcShapes.bezierArc(
                centre: left, radius: 5, from: 90, sweep: 180, curves: 2))
        let found = Self.recover(elements)
        #expect(found.count == 2)
        #expect(found.map(\.range) == [1..<3, 4..<6])
        for arc in found {
            #expect(!arc.isCircle && abs(arc.circle.radius - 5) < 1e-3)
            #expect(abs(abs(arc.sweep) * 180 / .pi - 180) < 0.1)
        }
    }

    // MARK: What is not taken

    @Test("polygons are not circles, up to the steps a flattened circle has")
    func polygons() {
        for sides in [3, 4, 5, 6, 8, 10, 12, 14] {
            let found = Self.recover(
                ArcShapes.polygon(centre: Self.centre, radius: 25, sides: sides))
            #expect(found.isEmpty, "\(sides) sides")
        }
        // Past that a polygon is what a writer makes of a circle.
        let flattened = Self.recover(ArcShapes.polygon(centre: Self.centre, radius: 25, sides: 24))
        #expect(flattened.count == 1 && flattened[0].isCircle)
    }

    @Test("an ellipse, flattened finely, is not cut into arcs: its pieces are round only locally")
    func ellipses() {
        for ratio in [0.5, 0.8, 0.9, 0.95, 0.98] {
            for segments in [36, 90, 180] {
                let chords = Self.recover(
                    ArcShapes.ellipse(
                        centre: Self.centre, a: 30, b: 30 * ratio, segments: segments))
                #expect(chords.isEmpty, "ratio \(ratio), \(segments) segments")
            }
        }
    }

    @Test("a spiral flattened into chords is not cut into arcs")
    func spiral() {
        // A turn and a half of a spiral whose radius grows 2 mm a turn, in 5 degree steps.
        var elements: [ArcElement] = []
        var previous = P(30, 0)
        for step in 1...108 {
            let angle = Double(step) * 5
            let radius = 30 + 2 * angle / 360
            let next = ArcShapes.point(P(0, 0), radius, angle)
            elements.append(.line(previous, next))
            previous = next
        }
        #expect(Self.recover(elements).isEmpty)
    }

    @Test("an arc with tangent lines either side is taken, though its ends turn")
    func tangentLines() throws {
        let arc = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 270, sweep: 90, segments: 12)
        var elements: [ArcElement] = []
        elements.append(.line(P(arc[0].start.x - 30, arc[0].start.y), arc[0].start))
        elements.append(contentsOf: arc)
        let end = arc[11].end
        elements.append(.line(end, P(end.x, end.y + 30)))
        let found = Self.recover(elements)
        #expect(found.count == 1)
        #expect(found.first?.range == 1..<13)
    }

    @Test("straight lines, and a gentle curve of many points, are not arcs")
    func gentle() {
        var line: [ArcElement] = []
        for k in 0..<30 {
            line.append(.line(P(Double(k), 0), P(Double(k + 1), 0)))
        }
        #expect(Self.recover(line).isEmpty)
        // A parabola, y = x^2 / 400, sampled every millimetre over 40 mm: bending, but not on
        // one circle to within the tolerance.
        var curve: [ArcElement] = []
        for k in 0..<40 {
            let x0 = Double(k)
            let x1 = Double(k + 1)
            curve.append(.line(P(x0, x0 * x0 / 400), P(x1, x1 * x1 / 400)))
        }
        #expect(Self.recover(curve).isEmpty)
    }

    @Test("a short arc, and a few chords, are left alone")
    func tooLittle() {
        // 10 degrees: too little sweep to say what the radius is.
        let short = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 40, from: 0, sweep: 10, curves: 1))
        #expect(short.isEmpty)
        // Seven chords of 8.5 degrees, between straight runs: any few points lie on a circle,
        // so a run of lines needs eight or more segments to be tested.
        var line: [ArcElement] = []
        let arc = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 0, sweep: 60, segments: 7)
        for k in 0..<6 {
            let x: Double = 120 + Double(k) * 2
            line.append(.line(P(x, -50), P(x + 2, -50)))
        }
        line.append(.line(P(132, -50), arc[0].start))
        line.append(contentsOf: arc)
        line.append(.line(arc[6].end, P(arc[6].end.x - 3, arc[6].end.y + 10)))
        #expect(Self.recover(line).isEmpty)
        let eight = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 0, sweep: 68, segments: 8)
        #expect(Self.recover(eight).count == 1)
    }

    @Test("a rounded rectangle is four lines and four arcs, never one circle")
    func roundedRectangle() throws {
        let radius = 4.0
        var elements: [ArcElement] = []
        let corners: [(P, Double)] = [
            (P(90, 10), 270), (P(90, 50), 0), (P(10, 50), 90), (P(10, 10), 180),
        ]
        for (corner, from) in corners {
            elements.append(
                contentsOf: ArcShapes.bezierArc(
                    centre: corner, radius: radius, from: from, sweep: 90, curves: 1))
        }
        // Each corner's arc is joined to the next by a straight side.
        var rounded: [ArcElement] = []
        for index in 0..<4 {
            rounded.append(elements[index])
            let next = elements[(index + 1) % 4]
            rounded.append(.line(elements[index].end, next.start))
        }
        let found = Self.recover(rounded)
        #expect(found.count == 4)
        for arc in found {
            #expect(abs(arc.circle.radius - radius) < 1e-3 && !arc.isCircle)
            #expect(arc.range.count == 1)
        }
    }

    @Test("a curve that bends both ways is not an arc")
    func sCurve() {
        let curve = ArcElement.curve(P(0, 0), P(20, 30), P(30, -30), P(50, 0))
        #expect(Self.recover([curve]).isEmpty)
    }

    @Test("an eccentric Bezier arc is not an arc")
    func eccentricity() {
        // A quarter of an ellipse as one curve, the axes 1.2 to 1 and then 1.02 to 1: the second
        // is 0.4 mm off round, ten times the tolerance.
        let k = 0.5522847498
        for a in [24.0, 20.4] {
            let quarter = ArcElement.curve(
                P(a, 0), P(a, 20 * k), P(a * k, 20), P(0, 20))
            #expect(Self.recover([quarter]).isEmpty, "a = \(a)")
        }
    }

    // MARK: Joining

    /// The arc recovered from each run, as a writer that gave each its own stroke would have it.
    static func arcs(_ runs: [[ArcElement]]) -> [RecoveredArc] {
        runs.compactMap { recover($0).first }
    }

    @Test("four quarter arcs that meet make one circle, fitted over all four")
    func quartersJoin() throws {
        var runs: [[ArcElement]] = []
        for index in 0..<4 {
            runs.append(
                ArcShapes.bezierArc(
                    centre: Self.centre, radius: 20, from: Double(index) * 90, sweep: 90,
                    curves: 1))
        }
        let arcs = Self.arcs(runs)
        #expect(arcs.count == 4)
        let joined = ArcJoining.join(arcs, keys: Array(repeating: "", count: 4), Self.options)
        let one = try #require(joined.first)
        #expect(joined.count == 1 && one.members.count == 4 && one.arc.isCircle)
        #expect(abs(one.arc.circle.radius - 20) < 0.005)
        #expect(abs(one.arc.sweep - 2 * .pi) < 0.01)
    }

    @Test(
        "arcs in a different style, or on a different circle, or going back on themselves, stay apart"
    )
    func notJoined() {
        let first = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 0, sweep: 90, curves: 1)
        let second = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 90, sweep: 90, curves: 1)
        let arcs = Self.arcs([first, second])
        #expect(ArcJoining.join(arcs, keys: ["red", "blue"], Self.options).isEmpty)
        #expect(ArcJoining.join(arcs, keys: ["red", "red"], Self.options).count == 1)
        let wider = ArcShapes.bezierArc(
            centre: Self.centre, radius: 21, from: 90, sweep: 90, curves: 1)
        #expect(ArcJoining.join(Self.arcs([first, wider]), keys: ["", ""], Self.options).isEmpty)
        // The same radius, meeting end to start, but bending the other way: an S, not one circle.
        let above = P(Self.centre.x, Self.centre.y + 40)
        let reverse = ArcShapes.bezierArc(
            centre: above, radius: 20, from: 270, sweep: 90, curves: 1)
        let ess = Self.arcs([first, reverse])
        #expect(ess.count == 2)
        #expect(ArcJoining.join(ess, keys: ["", ""], Self.options).isEmpty)
        // An arc and its mirror image on the other side of the join: both start at the join.
        let back = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 90, sweep: -90, curves: 1)
        let overlapping = Self.arcs([first, back])
        #expect(ArcJoining.join(overlapping, keys: ["", ""], Self.options).isEmpty)
    }

    @Test("an arc two arcs could continue is joined to neither")
    func ambiguous() {
        let first = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 0, sweep: 90, curves: 1)
        let second = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 90, sweep: 90, curves: 1)
        // The same arc drawn twice.
        let arcs = Self.arcs([first, second, second])
        #expect(ArcJoining.join(arcs, keys: ["", "", ""], Self.options).isEmpty)
    }
}
