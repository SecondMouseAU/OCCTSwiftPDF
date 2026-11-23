// Page+ArcPlan.swift
// OCCTSwiftPDF
//
// Where a page's circles and arcs are: the runs of curves and of short lines in its paths that one
// circle fits, across subpaths and strokes, before anything is put in the drawing.

import Foundation

extension PDF.Page {
    /// Where one recovered circle or arc was drawn.
    struct ArcPlan {
        /// A circle or arc and the stroke or strokes it replaces.
        struct Placed {
            var arc: RecoveredArc
            /// The operators that drew it, in order along the run, each once.
            var sources: [PDF.Source]
            /// The width of the stroke drawn first, in millimetres on the paper.
            var lineWidth: Double
            /// The segments (lines and curves) it replaces.
            var segments: Int
        }

        var arcs: [Placed] = []
        /// For each path, each subpath and each segment of it: the arc that takes the segment, or
        /// `-1`.
        var owner: [[[Int32]]] = []
    }

    /// The circles and arcs of this page's stroked paths.
    ///
    /// Each subpath is searched for runs one circle fits; arcs that meet on one circle, in one
    /// subpath or several, are joined and fitted again over the whole; then arcs with curves that
    /// still sweep less than the minimum are dropped.
    func arcPlan(_ options: PDF.ArcFitting) -> ArcPlan {
        struct Candidate {
            var arc: RecoveredArc
            var path: Int
            var subpath: Int
            var style: String
        }
        let transform = toPaper
        func paper(_ p: CGPoint) -> SIMD2<Double> {
            let q = p.applying(transform)
            return SIMD2(q.x, q.y)
        }
        // Pieces of a circle can each be short; the minimum applies to the whole.
        let curveSweepDeg = min(options.minimumSweepDeg, 10)
        var candidates: [Candidate] = []
        for (pathIndex, path) in paths.enumerated() where path.paint != .fill {
            let style = "\(path.layer ?? "0")|\(Self.aci(path.strokeColour))"
            for (subpathIndex, subpath) in path.subpaths.enumerated()
            where !isPageBorder(subpath) {
                var elements: [ArcElement] = []
                var from = paper(subpath.start)
                for segment in subpath.segments {
                    switch segment {
                    case .line(let to):
                        elements.append(.line(from, paper(to)))
                    case .curve(let c1, let c2, let to):
                        elements.append(.curve(from, paper(c1), paper(c2), paper(to)))
                    }
                    from = elements[elements.count - 1].end
                }
                for arc in ArcRecovery.recover(elements, options, curveSweepDeg: curveSweepDeg) {
                    candidates.append(
                        Candidate(arc: arc, path: pathIndex, subpath: subpathIndex, style: style))
                }
            }
        }

        // Join what meets on one circle; what does not stays as it was found.
        let joins = ArcJoining.join(candidates.map(\.arc), keys: candidates.map(\.style), options)
        var joinedMembers = Set<Int>()
        var runs: [(arc: RecoveredArc, members: [Int])] = []
        for join in joins {
            runs.append((join.arc, join.members))
            joinedMembers.formUnion(join.members)
        }
        for index in candidates.indices where !joinedMembers.contains(index) {
            runs.append((candidates[index].arc, [index]))
        }

        var plan = ArcPlan()
        plan.owner = paths.map { path in
            path.subpaths.map { [Int32](repeating: -1, count: $0.segments.count) }
        }
        let minimum = options.minimumSweepDeg * .pi / 180 - 1e-9
        for run in runs {
            if run.arc.curves > 0 && abs(run.arc.sweep) < minimum { continue }
            var sources: [PDF.Source] = []
            var segments = 0
            for member in run.members {
                let source = paths[candidates[member].path].source
                if !sources.contains(source) { sources.append(source) }
                segments += candidates[member].arc.range.count
            }
            let id = Int32(plan.arcs.count)
            for member in run.members {
                let candidate = candidates[member]
                for index in candidate.arc.range {
                    plan.owner[candidate.path][candidate.subpath][index] = id
                }
            }
            // The width is that of the stroke drawn first, which is also where the entity goes.
            let firstDrawn = run.members.min {
                (candidates[$0].path, candidates[$0].subpath)
                    < (candidates[$1].path, candidates[$1].subpath)
            }
            let width = firstDrawn.map { paths[candidates[$0].path].lineWidth } ?? 0
            plan.arcs.append(
                ArcPlan.Placed(
                    arc: run.arc, sources: sources, lineWidth: width * 25.4 / 72,
                    segments: segments))
        }
        return plan
    }
}
