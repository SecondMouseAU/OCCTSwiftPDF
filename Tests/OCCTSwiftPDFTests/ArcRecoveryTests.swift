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
        // Past that a polygon is what a writer makes of a circle: 15 sides are 24 degrees each,
        // the most a step may be.
        for sides in [15, 24] {
            let flattened = Self.recover(
                ArcShapes.polygon(centre: Self.centre, radius: 25, sides: sides))
            #expect(flattened.count == 1 && flattened[0].isCircle, "\(sides) sides")
        }
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
        // strays 0.025 mm from its best circle, two and a half times the tolerance.
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

    @Test("a circle drawn a little past its start is a circle, and one short of it is an arc")
    func overlapAndGap() throws {
        // Four curves sweeping 360.6 degrees: the end passes the start by 0.2 mm.
        let past = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 20, from: 10, sweep: 360.6, curves: 4))
        #expect(past.count == 1 && past[0].isCircle)
        // The same, 356 degrees: 1.4 mm short of closing.
        let short = Self.recover(
            ArcShapes.bezierArc(centre: Self.centre, radius: 20, from: 10, sweep: 356, curves: 4))
        #expect(short.count == 1 && !short[0].isCircle)
        #expect(abs(abs(short[0].sweep) * 180 / .pi - 356) < 0.1)
    }

    @Test("a smooth polyline of many chords is searched in a few fits a start, not one a length")
    func fineChordsAreCheap() {
        // An ellipse of 800 chords is round to 0.003 mm over some 45 of them from any start:
        // growing a run one chord at a time takes 36,000 fits, doubling and halving 9,000, and
        // starting from where the last start's run ended 2 a start.
        let chords = ArcShapes.ellipse(centre: Self.centre, a: 150, b: 147, segments: 800)
        let count = SearchCount()
        #expect(ArcRecovery.recover(chords, Self.options, count: count).isEmpty)
        #expect(count.fits < 4_000, "\(count.fits) fits")
    }

    @Test("arcs drawn clockwise join as the circle they make")
    func clockwiseJoin() throws {
        var runs: [[ArcElement]] = []
        for index in 0..<4 {
            runs.append(
                ArcShapes.bezierArc(
                    centre: Self.centre, radius: 20, from: 90 - Double(index) * 90, sweep: -90,
                    curves: 1))
        }
        let arcs = Self.arcs(runs)
        #expect(arcs.count == 4 && arcs.allSatisfy { $0.sweep < 0 })
        let joined = ArcJoining.join(arcs, keys: Array(repeating: "", count: 4), Self.options)
        let one = try #require(joined.first)
        #expect(joined.count == 1 && one.members.count == 4 && one.arc.isCircle)
        // Three of them, drawn from 90 down to -180, make the 270 degrees counterclockwise from 180.
        let three = ArcJoining.join(Array(arcs.prefix(3)), keys: ["", "", ""], Self.options)
        let arc = try #require(three.first)
        #expect(three.count == 1 && !arc.arc.isCircle)
        #expect(abs(arc.arc.sweep * 180 / .pi - 270) < 0.1)
        #expect(abs(arc.arc.firstDeg - 180) < 0.1)
    }

    // MARK: Options and limits

    @Test("a run that doubles back on its circle is cut where it turns")
    func backwards() {
        // 25 chords of 8 degrees forward, then 3 of 8 degrees back along the same circle.
        var chords = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 0, sweep: 200, segments: 25)
        let back = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 200, sweep: -24, segments: 3)
        chords.append(contentsOf: back)
        let found = Self.recover(chords)
        #expect(found.count == 1 && found.first?.range == 0..<25)
    }

    @Test("a circle drawn twice over is two circles, not one of 720 degrees")
    func twoLaps() {
        let lap = ArcShapes.flattened(centre: Self.centre, radius: 20, segments: 36)
        let found = Self.recover(lap + lap)
        #expect(found.count == 2 && found.allSatisfy(\.isCircle))
    }

    @Test("chords of unequal steps are an arc only if the option allows the spread")
    func stepRatio() {
        // Steps alternate 4 and 8 degrees: on one circle, but cut as no flattener cuts it.
        var chords: [ArcElement] = []
        var angle = 0.0
        for index in 0..<14 {
            let step = index % 2 == 0 ? 4.0 : 8.0
            chords.append(
                .line(
                    ArcShapes.point(Self.centre, 20, angle),
                    ArcShapes.point(Self.centre, 20, angle + step)))
            angle += step
        }
        #expect(Self.recover(chords).isEmpty)
        var loose = Self.options
        loose.maximumStepRatio = 2.5
        #expect(ArcRecovery.recover(chords, loose).count == 1)
    }

    @Test("a big circle of four curves is out of round by more than the absolute tolerance")
    func relativeTolerance() throws {
        // 0.03 percent of 100 mm is 0.03 mm, three times the 0.01 mm tolerance.
        let big = ArcShapes.bezierArc(centre: Self.centre, radius: 100, curves: 4)
        let found = Self.recover(big)
        let circle = try #require(found.first)
        #expect(found.count == 1 && circle.isCircle)
        #expect(circle.maxResidual > Self.options.tolerance)
        var strict = Self.options
        strict.relativeTolerance = 0
        #expect(ArcRecovery.recover(big, strict).isEmpty)
    }

    @Test("a circle smaller than the least radius, or an arc bigger than the most, is left alone")
    func radiusLimits() {
        let tiny = ArcShapes.bezierArc(centre: Self.centre, radius: 0.02, curves: 4)
        #expect(Self.recover(tiny).isEmpty)
        var small = Self.options
        small.minimumRadius = 0.01
        #expect(ArcRecovery.recover(tiny, small).count == 1)
        let huge = ArcShapes.bezierArc(
            centre: Self.centre, radius: 3_000, from: 0, sweep: 90, curves: 1)
        #expect(Self.recover(huge).isEmpty)
        var large = Self.options
        large.maximumRadius = 5_000
        #expect(ArcRecovery.recover(huge, large).count == 1)
    }

    @Test("a least of no chords or fewer does not hang or trap")
    func nonsenseOptions() {
        let chords = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 0, sweep: 120, segments: 12)
        for least in [0, -3] {
            var options = Self.options
            options.minimumLineSegments = least
            #expect(ArcRecovery.recover(chords, options).count == 1)
        }
    }

    @Test("two arcs of one circle with a gap between them are not joined")
    func gapBetweenArcs() {
        let first = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 0, sweep: 90, curves: 1)
        // 0.3 mm on from where the first ends (0.86 degrees at 20 mm): near, but not meeting.
        let second = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 90.86, sweep: 90, curves: 1)
        let arcs = Self.arcs([first, second])
        #expect(arcs.count == 2)
        #expect(ArcJoining.join(arcs, keys: ["", ""], Self.options).isEmpty)
        // Made to meet, the same two are one arc.
        let meeting = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 90, sweep: 90, curves: 1)
        #expect(
            ArcJoining.join(Self.arcs([first, meeting]), keys: ["", ""], Self.options).count == 1)
    }

    @Test("a chord that is not on the circle keeps it from being a circle of curves")
    func flatOnACircle() throws {
        // 340 degrees of curves and a 20 degree chord to close it, at 20 mm: the chord's middle
        // is 0.3 mm inside the circle, which its ends do not show.
        var elements = ArcShapes.bezierArc(
            centre: Self.centre, radius: 20, from: 10, sweep: 340, curves: 4)
        elements.append(.line(elements[3].end, elements[0].start))
        let found = Self.recover(elements)
        let arc = try #require(found.first)
        #expect(found.count == 1 && !arc.isCircle && arc.range == 0..<4)
        #expect(abs(abs(arc.sweep) * 180 / .pi - 340) < 0.1)
        // A closing line too short to leave the circle is part of it.
        var closed = ArcShapes.bezierArc(centre: Self.centre, radius: 20, curves: 4)
        closed.append(.line(closed[3].end, P(closed[3].end.x + 1e-4, closed[3].end.y)))
        let whole = try #require(Self.recover(closed).first)
        #expect(whole.isCircle && whole.range == 0..<5)
    }

    @Test("a vertex written twice does not stop chords being a circle")
    func repeatedVertex() throws {
        var chords = ArcShapes.flattened(centre: Self.centre, radius: 20, segments: 48)
        chords.insert(.line(chords[20].start, chords[20].start), at: 20)
        let circle = try #require(Self.recover(chords).first)
        #expect(circle.isCircle && circle.range == 0..<49)
    }

    @Test(
        "chords off the circle by more than the line tolerance are not an arc, unless it is raised")
    func lineTolerance() {
        // 36 chords of 10 degrees with the corners 0.006 mm in and out alternately.
        var chords: [ArcElement] = []
        for index in 0..<36 {
            let inner = index % 2 == 0 ? 20.0 : 20.012
            let next = index % 2 == 0 ? 20.012 : 20.0
            chords.append(
                .line(
                    ArcShapes.point(Self.centre, inner, Double(index) * 10),
                    ArcShapes.point(Self.centre, next, Double(index + 1) * 10)))
        }
        #expect(Self.recover(chords).isEmpty)
        var loose = Self.options
        loose.lineTolerance = 0.01
        #expect(ArcRecovery.recover(chords, loose).count == 1)
    }

    @Test("a circle of more than 4096 chords is found, and quickly")
    func manyChords() throws {
        let chords = ArcShapes.flattened(centre: Self.centre, radius: 300, segments: 6_000)
        let count = SearchCount()
        let found = ArcRecovery.recover(chords, Self.options, count: count)
        let circle = try #require(found.first)
        #expect(found.count == 1 && circle.isCircle && circle.range == 0..<6_000)
        #expect(count.fits < 100, "\(count.fits) fits")
    }

    @Test("a long run that fits but is only part of a curve is stepped over, not searched again")
    func longRunSteppedOver() {
        // 3,000 chords of 0.02 degrees along an ellipse that is round to 0.003 mm over far more
        // than the 300 elements tried here: from any start the run fits to the end of what is
        // tried and is carried on past, so it is no arc, and the search steps over it.
        let chords = ArcShapes.ellipse(
            centre: Self.centre, a: 300, b: 299.9, from: 0, sweep: 60, segments: 3_000)
        let count = SearchCount()
        #expect(ArcRecovery.recover(chords, Self.options, count: count, maximumRun: 300).isEmpty)
        // One search a start would be 3,000 searches of about a dozen fits each.
        #expect(count.fits < 400, "\(count.fits) fits")
    }

    @Test("chords of two arcs with different steps are not one circle when joined")
    func joinedStepsDiffer() {
        let coarse = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 0, sweep: 120, segments: 8)
        let fine = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 120, sweep: 120, segments: 16)
        let arcs = Self.arcs([coarse, fine])
        #expect(arcs.count == 2)
        #expect(ArcJoining.join(arcs, keys: ["", ""], Self.options).isEmpty)
        // The same step in both: joined.
        let same = ArcShapes.flattened(
            centre: Self.centre, radius: 20, from: 120, sweep: 120, segments: 8)
        #expect(
            ArcJoining.join(Self.arcs([coarse, same]), keys: ["", ""], Self.options).count == 1)
    }

    /// Chords of 12 degrees from `from`, each of `steps`, as a run.
    static func chords(from start: Double, steps: [Double]) -> [ArcElement] {
        var out: [ArcElement] = []
        var angle = start
        for step in steps {
            let a = ArcShapes.point(centre, 20, angle)
            let b = ArcShapes.point(centre, 20, angle + step)
            out.append(.line(a, b))
            angle += step
        }
        return out
    }

    @Test("an odd chord at either end of an arc is left out of it, not the whole arc")
    func oddChordsAtTheEnds() throws {
        var steps = [Double](repeating: 12, count: 8)
        // An odd chord at the end.
        let atEnd = Self.chords(from: 0, steps: steps + [4])
        #expect(Self.recover(atEnd).first?.range == 0..<8)
        // At the start, with the arc running to the end of the subpath.
        let atStart = Self.chords(from: 0, steps: [4] + steps)
        let start = try #require(Self.recover(atStart).first)
        #expect(start.range == 1..<9)
        // At both ends.
        steps.insert(4, at: 0)
        steps.append(4)
        let both = try #require(Self.recover(Self.chords(from: 0, steps: steps)).first)
        #expect(both.range == 1..<9)
    }

    @Test("arcs whose ends meet across a cell of the search are joined")
    func joinAcrossCells() {
        // The first ends at x = 0.4995, the second starts at x = 0.5035, 0.004 mm on and in the
        // next 0.5 mm cell.
        let first = ArcShapes.bezierArc(
            centre: P(0.4995, 0), radius: 20, from: 0, sweep: 90, curves: 1)
        let second = ArcShapes.bezierArc(
            centre: P(0.5035, 0), radius: 20, from: 90, sweep: 90, curves: 1)
        let arcs = Self.arcs([first, second])
        #expect(arcs.count == 2)
        #expect(ArcJoining.join(arcs, keys: ["", ""], Self.options).count == 1)
    }
}
