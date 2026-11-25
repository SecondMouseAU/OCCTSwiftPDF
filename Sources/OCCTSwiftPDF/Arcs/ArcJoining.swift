// ArcJoining.swift
// OCCTSwiftPDF
//
// Joins arcs that a writer split between subpaths or paths: DraftingCAD through Quartz draws a
// circle as two arcs in two strokes, so no run inside one subpath is the circle. Arcs on one circle
// that meet end to start are fitted again as one run.

import Foundation

enum ArcJoining {
    /// Arcs joined into one: the positions of the members (two or more, in order along the run)
    /// and the arc over all of them.
    struct Joined: Equatable {
        var members: [Int]
        var arc: RecoveredArc
    }

    /// The joins among `arcs`, where only arcs with the same `keys` (layer, colour and the like)
    /// are joined.
    ///
    /// Two arcs are neighbours when the first ends where the second starts, within the
    /// tolerance, and their circles agree within it. An arc with more than one neighbour at an end
    /// is left alone, since which continues it is not known. The joined run is fitted again over
    /// every point and must still be within the tolerance, go one way, and not go further than
    /// once round.
    static func join(_ arcs: [RecoveredArc], keys: [String], _ options: PDF.ArcFitting) -> [Joined]
    {
        precondition(arcs.count == keys.count)
        func ccwStart(_ arc: RecoveredArc) -> SIMD2<Double> {
            arc.sweep >= 0 ? arc.points[0] : arc.points[arc.points.count - 1]
        }
        func ccwEnd(_ arc: RecoveredArc) -> SIMD2<Double> {
            arc.sweep >= 0 ? arc.points[arc.points.count - 1] : arc.points[0]
        }
        func tolerance(_ arc: RecoveredArc) -> Double {
            ArcRecovery.tolerance(curves: arc.curves, radius: arc.circle.radius, options)
        }
        // Start points by key and cell, so each end looks only at the starts near it: a cell is
        // wider than the slack of any arc, and the ends look in the cells round their own.
        let cell = max(0.5, arcs.map { 2 * tolerance($0) }.max() ?? 0)
        func cellOf(_ p: SIMD2<Double>) -> [Int] {
            [Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down))]
        }
        var starts: [String: [Int]] = [:]
        for (index, arc) in arcs.enumerated() where !arc.isCircle && arc.points.count >= 2 {
            let c = cellOf(ccwStart(arc))
            starts["\(keys[index])|\(c[0])/\(c[1])", default: []].append(index)
        }
        var successors: [[Int]] = Array(repeating: [], count: arcs.count)
        var predecessors: [[Int]] = Array(repeating: [], count: arcs.count)
        for (index, arc) in arcs.enumerated() where !arc.isCircle && arc.points.count >= 2 {
            let end = ccwEnd(arc)
            let c = cellOf(end)
            let slack = 2 * tolerance(arc)
            for dx in -1...1 {
                for dy in -1...1 {
                    for other in starts["\(keys[index])|\(c[0] + dx)/\(c[1] + dy)"] ?? []
                    where other != index {
                        let o = arcs[other]
                        let circles =
                            ArcRecovery.distance(arc.circle.centre, o.circle.centre) <= slack
                            && abs(arc.circle.radius - o.circle.radius) <= slack
                        if circles && ArcRecovery.distance(end, ccwStart(o)) <= slack {
                            successors[index].append(other)
                            predecessors[other].append(index)
                        }
                    }
                }
            }
        }
        // Follow a link only where it is the one way on from the arc and the one way into the next.
        var next: [Int?] = Array(repeating: nil, count: arcs.count)
        for index in arcs.indices where successors[index].count == 1 {
            let other = successors[index][0]
            if predecessors[other].count == 1 { next[index] = other }
        }
        let followed = Set(next.compactMap { $0 })
        var chains: [[Int]] = []
        var seen = Set<Int>()
        func follow(from index: Int) {
            var chain = [index]
            seen.insert(index)
            var at = index
            while let following = next[at], !seen.contains(following) {
                chain.append(following)
                seen.insert(following)
                at = following
            }
            if chain.count >= 2 { chains.append(chain) }
        }
        for index in arcs.indices where next[index] != nil && !followed.contains(index) {
            follow(from: index)
        }
        // What is left follows itself round: a circle in two or more arcs.
        for index in arcs.indices where next[index] != nil && !seen.contains(index) {
            follow(from: index)
        }

        var joined: [Joined] = []
        for chain in chains {
            if let arc = refit(chain.map { arcs[$0] }, options) {
                joined.append(Joined(members: chain, arc: arc))
            }
        }
        return joined
    }

    /// The arcs, in the order they go round counterclockwise, as one run fitted over all their
    /// points, or `nil` when no circle fits them all.
    private static func refit(_ arcs: [RecoveredArc], _ options: PDF.ArcFitting) -> RecoveredArc? {
        var points: [SIMD2<Double>] = []
        for arc in arcs {
            let ordered = arc.sweep >= 0 ? arc.points : arc.points.reversed()
            points.append(contentsOf: points.isEmpty ? ordered : Array(ordered.dropFirst()))
        }
        guard let circle = Circle.fitting(points),
            circle.radius >= options.minimumRadius, circle.radius <= options.maximumRadius
        else { return nil }
        let curves = arcs.reduce(0) { $0 + $1.curves }
        let lines = arcs.reduce(0) { $0 + $1.lines }
        let tolerance = ArcRecovery.tolerance(curves: curves, radius: circle.radius, options)
        let middles = arcs.flatMap(\.chordMiddles)
        let (worst, squares) = ArcRecovery.residuals(of: points, and: middles, about: circle)
        guard worst <= tolerance else { return nil }
        let (total, steps) = ArcRecovery.walk(points, about: circle)
        let backwards = ArcRecovery.backwardsBound(tolerance: tolerance, radius: circle.radius)
        guard total > 0, !steps.contains(where: { $0 < -backwards }),
            total <= 2 * .pi + ArcRecovery.overdraw
        else { return nil }
        // Chords only: the joined run must be cut in steps like any other run of chords.
        var stepRatio = arcs.map(\.stepRatio).max() ?? 1
        if curves == 0 {
            let sizes = steps.map { abs($0) }.filter { $0 > 1e-12 }
            guard let largest = sizes.max(), let smallest = sizes.min(),
                largest <= options.maximumLineStepDeg * .pi / 180 + 1e-9
            else { return nil }
            stepRatio = largest / smallest
            guard stepRatio <= options.maximumStepRatio else { return nil }
        }
        let closes = ArcRecovery.closed(
            first: points[0], last: points[points.count - 1], sweep: total, tolerance)
        return RecoveredArc(
            range: 0..<0, circle: circle,
            startAngle: atan2(points[0].y - circle.centre.y, points[0].x - circle.centre.x),
            sweep: total, isCircle: closes, maxResidual: worst,
            rmsResidual: (squares / Double(points.count)).squareRoot(), curves: curves,
            lines: lines, stepRatio: stepRatio, points: points, chordMiddles: middles)
    }
}
