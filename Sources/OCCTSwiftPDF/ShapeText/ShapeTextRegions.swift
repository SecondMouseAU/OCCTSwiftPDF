// ShapeTextRegions.swift
// OCCTSwiftPDF
//
// Finding the lines of shapes that might be text, from the geometry already read: small filled or
// stroked subpaths, grouped into glyph-sized pieces, gathered into blobs by nearness, and each blob
// cut into lines along the direction that gives it the longest ones.

import CoreGraphics
import Foundation

enum ShapeTextRegions {
    /// What the search found on a page.
    struct Found {
        var regions: [ShapeTextRegion] = []
        /// The pieces considered.
        var shapes = 0
        /// The pieces in blobs too large to look at.
        var shapesInDenseBlobs = 0
        /// The lines with fewer than the minimum number of glyphs.
        var tooSmall = 0
    }

    /// The most glyph-sized pieces in a blob that is looked at: more is a hatch or a symbol.
    static let maximumBlobGlyphs = 5_000

    /// Two glyphs are in one blob when the gap between their boxes is at most this multiple of
    /// the larger one's size.
    static let linkGap = 0.6

    static func find(in page: PDF.Page, options: PDF.ShapeTextOptions) -> Found {
        var found = Found()
        let pieces = ShapeTextPieces.pieces(in: page.paths, maximumSize: options.maximumShapeSize)
        found.shapes = pieces.count
        guard pieces.count >= options.minimumGlyphs else { return found }
        let glyphs = ShapeTextPieces.glyphs(from: pieces)
        for blob in blobs(of: glyphs) {
            guard blob.count <= maximumBlobGlyphs else {
                found.shapesInDenseBlobs += blob.reduce(0) { $0 + glyphs[$1].pieces.count }
                continue
            }
            guard blob.count >= options.minimumGlyphs else {
                found.tooSmall += 1
                continue
            }
            let (direction, lines) = bestLines(in: blob, glyphs: glyphs)
            for line in lines {
                guard line.count >= options.minimumGlyphs else {
                    found.tooSmall += 1
                    continue
                }
                found.regions.append(
                    region(line, direction: direction, glyphs: glyphs, pieces: pieces, page: page))
            }
        }
        return found
    }

    /// The glyphs grouped by nearness, each group in order of its first glyph.
    static func blobs(of glyphs: [ShapeGlyph]) -> [[Int]] {
        let grid = BoxGrid(
            boxes: glyphs.map(\.box), cell: ShapeTextPieces.cell(for: glyphs.map(\.size)))
        var sets = DisjointSets(count: glyphs.count)
        for (index, glyph) in glyphs.enumerated() {
            let reach = linkGap * glyph.size
            grid.forEach(near: glyph.box.insetBy(dx: -reach, dy: -reach)) { other in
                let b = glyphs[other]
                // The larger of a pair finds it; the smaller is found.
                guard other != index, b.size < glyph.size || (b.size == glyph.size && other > index)
                else { return }
                if gap(glyph.box, b.box) <= reach { sets.union(index, other) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in glyphs.indices { groups[sets.find(index), default: []].append(index) }
        return groups.keys.sorted().map { groups[$0] ?? [] }
    }

    /// The distance between two rectangles, zero where they touch or overlap.
    static func gap(_ a: CGRect, _ b: CGRect) -> Double {
        let dx = max(0, a.minX - b.maxX, b.minX - a.maxX)
        let dy = max(0, a.minY - b.maxY, b.minY - a.maxY)
        return hypot(dx, dy)
    }

    /// The reading direction that cuts the blob into the longest lines, and those lines.
    ///
    /// The candidates are along the page's x axis, along its y axis, and (where the blob is
    /// clearly elongated and not along either) its principal axis. A line scores the square of
    /// its glyph count, so one long line beats the same glyphs cut into short ones; where two
    /// directions score alike, the one whose lines are thinner (a line along its own direction is
    /// as thin as its glyphs are tall) wins.
    static func bestLines(in blob: [Int], glyphs: [ShapeGlyph]) -> (CGPoint, [[Int]]) {
        var candidates = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        if let axis = principalAxis(blob, glyphs: glyphs) { candidates.append(axis) }
        var best = (direction: candidates[0], lines: [[Int]](), score: -1, thickness: 0.0)
        for direction in candidates {
            let lines = lines(in: blob, glyphs: glyphs, direction: direction)
            let score = lines.reduce(0) { $0 + ($1.count >= 2 ? $1.count * $1.count : 0) }
            let thickness = lines.reduce(0.0) {
                $0 + thickness(of: $1, glyphs: glyphs, direction: direction)
            }
            if score > best.score || (score == best.score && thickness < best.thickness - 1e-6) {
                best = (direction, lines, score, thickness)
            }
        }
        return (best.direction, best.lines)
    }

    /// The extent of a line's glyph boxes across `direction`.
    static func thickness(of line: [Int], glyphs: [ShapeGlyph], direction d: CGPoint) -> Double {
        var low = Double.infinity
        var high = -Double.infinity
        for index in line {
            let box = glyphs[index].box
            for corner in [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
            ] {
                let v = -corner.x * d.y + corner.y * d.x
                low = min(low, v)
                high = max(high, v)
            }
        }
        return high - low
    }

    /// The principal axis of the glyphs' centres as a unit vector with a positive x (or, along
    /// the y axis, a positive y), when the blob is clearly elongated and the axis is not within 3
    /// degrees of the page's own.
    static func principalAxis(_ blob: [Int], glyphs: [ShapeGlyph]) -> CGPoint? {
        guard blob.count >= 3 else { return nil }
        let centres = blob.map { CGPoint(x: glyphs[$0].box.midX, y: glyphs[$0].box.midY) }
        let n = Double(centres.count)
        let mx = centres.reduce(0.0) { $0 + $1.x } / n
        let my = centres.reduce(0.0) { $0 + $1.y } / n
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for c in centres {
            sxx += (c.x - mx) * (c.x - mx)
            syy += (c.y - my) * (c.y - my)
            sxy += (c.x - mx) * (c.y - my)
        }
        let trace = sxx + syy
        let half = (sxx - syy) / 2
        let spread = (half * half + sxy * sxy).squareRoot()
        let major = trace / 2 + spread
        let minor = trace / 2 - spread
        guard major > 0, minor < major / 4 else { return nil }
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        if angle <= -.pi / 2 { angle += .pi }
        let degrees = angle * 180 / .pi
        let fromAxis = min(abs(degrees), abs(abs(degrees) - 90), abs(abs(degrees) - 180))
        guard fromAxis > 3 else { return nil }
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    /// The blob cut into lines along `direction`.
    ///
    /// Glyphs whose extents across it overlap are one line, which is cut again where the gap along
    /// it is wider than one glyph. Each line is in order along the direction, and the lines are in
    /// order across it.
    static func lines(in blob: [Int], glyphs: [ShapeGlyph], direction d: CGPoint) -> [[Int]] {
        struct Placed {
            var index: Int
            var u: ClosedRange<Double>
            var v: ClosedRange<Double>
            /// The middle of its extent across the direction.
            var centre: Double { (v.lowerBound + v.upperBound) / 2 }
        }
        let n = CGPoint(x: -d.y, y: d.x)
        let placed: [Placed] = blob.map { index in
            let box = glyphs[index].box
            let corners = [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
            ]
            let us = corners.map { $0.x * d.x + $0.y * d.y }
            let vs = corners.map { $0.x * n.x + $0.y * n.y }
            return Placed(
                index: index, u: (us.min() ?? 0)...(us.max() ?? 0),
                v: (vs.min() ?? 0)...(vs.max() ?? 0))
        }
        let sizes = placed.map { glyphs[$0.index].size }.sorted()
        let median = sizes[sizes.count / 2]

        // Across: sorted by the centre across, a glyph joins the last line (or the one before)
        // whose extent across it overlaps by at least 30 percent of the smaller of the two.
        var lines: [(v: ClosedRange<Double>, members: [Placed])] = []
        let acrossOrder = placed.sorted { a, b in
            a.centre != b.centre ? a.centre < b.centre : a.index < b.index
        }
        for glyph in acrossOrder {
            var joined = false
            for slot in lines.indices.suffix(2).reversed() {
                let line = lines[slot].v
                let overlap =
                    min(line.upperBound, glyph.v.upperBound)
                    - max(line.lowerBound, glyph.v.lowerBound)
                let smaller = min(
                    line.upperBound - line.lowerBound, glyph.v.upperBound - glyph.v.lowerBound)
                if overlap >= 0.3 * max(smaller, 1e-9) {
                    lines[slot].v =
                        min(
                            line.lowerBound, glyph.v.lowerBound)...max(
                            line.upperBound, glyph.v.upperBound)
                    lines[slot].members.append(glyph)
                    joined = true
                    break
                }
            }
            if !joined { lines.append((glyph.v, [glyph])) }
        }

        // Along: in order, cut where the gap is wider than one median glyph.
        var out: [[Int]] = []
        for line in lines.sorted(by: { $0.v.lowerBound < $1.v.lowerBound }) {
            var run: [Int] = []
            var reach = -Double.infinity
            for glyph in line.members.sorted(by: { $0.u.lowerBound < $1.u.lowerBound }) {
                if !run.isEmpty && glyph.u.lowerBound - reach > median {
                    out.append(run)
                    run = []
                    reach = -.infinity
                }
                run.append(glyph.index)
                reach = max(reach, glyph.u.upperBound)
            }
            if !run.isEmpty { out.append(run) }
        }
        return out
    }

    /// The region a line of glyphs makes: its ink box along `direction`, measured over the points
    /// of its pieces (so a line at an angle is not widened by its glyphs' own bounding boxes).
    static func region(
        _ line: [Int], direction d: CGPoint, glyphs: [ShapeGlyph], pieces: [ShapePiece],
        page: PDF.Page
    ) -> ShapeTextRegion {
        let n = CGPoint(x: -d.y, y: d.x)
        var u = (low: Double.infinity, high: -Double.infinity)
        var v = (low: Double.infinity, high: -Double.infinity)
        var paths: [Int] = []
        var stroked = 0
        for index in line {
            let glyph = glyphs[index]
            if !glyph.filled { stroked += 1 }
            for pieceIndex in glyph.pieces {
                let piece = pieces[pieceIndex]
                if !paths.contains(piece.path) { paths.append(piece.path) }
                let path = page.paths[piece.path]
                let widen = path.paint == .fill ? 0 : path.lineWidth / 2
                for point in points(of: path.subpaths[piece.subpath]) {
                    let pu = point.x * d.x + point.y * d.y
                    let pv = point.x * n.x + point.y * n.y
                    u = (min(u.low, pu - widen), max(u.high, pu + widen))
                    v = (min(v.low, pv - widen), max(v.high, pv + widen))
                }
            }
        }
        paths.sort()
        let angle = atan2(d.y, d.x) * 180 / .pi
        return ShapeTextRegion(
            direction: d,
            origin: CGPoint(x: d.x * u.low + n.x * v.low, y: d.y * u.low + n.y * v.low),
            length: u.high - u.low, height: v.high - v.low, glyphs: line.count,
            mostlyStroked: stroked * 2 > line.count, canReverse: abs(abs(angle) - 90) < 45,
            paths: paths)
    }

    /// Every point of a subpath, control points included.
    static func points(of subpath: PDF.Subpath) -> [CGPoint] {
        var out = [subpath.start]
        for segment in subpath.segments {
            switch segment {
            case .line(let to): out.append(to)
            case .curve(let c1, let c2, let to): out += [c1, c2, to]
            }
        }
        return out
    }
}
