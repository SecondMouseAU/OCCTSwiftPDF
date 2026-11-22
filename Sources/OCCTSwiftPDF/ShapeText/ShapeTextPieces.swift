// ShapeTextPieces.swift
// OCCTSwiftPDF
//
// The small painted subpaths of a page, grouped into glyph-sized pieces, with the grid and the
// disjoint sets the grouping needs.

import CoreGraphics
import Foundation

/// One small painted subpath: a candidate piece of a glyph.
struct ShapePiece {
    /// The index into `Page.paths`.
    var path: Int
    /// The index into that path's `subpaths`.
    var subpath: Int
    /// Its box in page coordinates, widened by half the line width where it is stroked.
    var box: CGRect
    /// Painted with a fill (an outline), not only stroked.
    var filled: Bool
    var size: Double { max(box.width, box.height) }
}

/// Pieces that make up one glyph: a letter's outer and inner outlines (the hole of an "O" is
/// inside its outline's box), or just one piece.
struct ShapeGlyph {
    var pieces: [Int]
    var box: CGRect
    var filled: Bool
    var size: Double { max(box.width, box.height) }
}

/// A union-find over `0..<count`.
struct DisjointSets {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var walk = index
        while parent[walk] != root {
            let next = parent[walk]
            parent[walk] = root
            walk = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
}

/// Boxes bucketed by the cells they touch, for the boxes near a rectangle.
final class BoxGrid {
    private let cell: Double
    private var buckets: [Int64: [Int]] = [:]
    private var stamp: [UInt32]
    private var query: UInt32 = 0

    init(boxes: [CGRect], cell: Double) {
        self.cell = cell
        stamp = Array(repeating: 0, count: boxes.count)
        for (index, box) in boxes.enumerated() {
            for x in range(box.minX, box.maxX) {
                for y in range(box.minY, box.maxY) {
                    buckets[Self.key(x, y), default: []].append(index)
                }
            }
        }
    }

    private static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 ^ (y & 0xFFFF_FFFF) }

    private func range(_ low: Double, _ high: Double) -> ClosedRange<Int64> {
        Int64((low / cell).rounded(.down))...Int64((high / cell).rounded(.down))
    }

    /// Calls `body` once for each box that touches a cell `rect` touches, which can be a box
    /// that does not itself reach `rect`.
    func forEach(near rect: CGRect, _ body: (Int) -> Void) {
        query &+= 1
        for x in range(rect.minX, rect.maxX) {
            for y in range(rect.minY, rect.maxY) {
                for index in buckets[Self.key(x, y)] ?? [] where stamp[index] != query {
                    stamp[index] = query
                    body(index)
                }
            }
        }
    }
}

enum ShapeTextPieces {
    /// The smallest side, in page units, of a shape that may be part of a glyph.
    static let minimumSize = 0.2

    /// A subpath's box, with its control points, or `nil` for one with no segments.
    static func bounds(_ subpath: PDF.Subpath) -> CGRect? {
        guard !subpath.segments.isEmpty else { return nil }
        var box = CGRect(origin: subpath.start, size: .zero)
        func add(_ point: CGPoint) {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        for segment in subpath.segments {
            switch segment {
            case .line(let to): add(to)
            case .curve(let c1, let c2, let to):
                add(c1)
                add(c2)
                add(to)
            }
        }
        return box
    }

    /// Every subpath of a painted path whose longest side is at most `maximumSize`.
    static func pieces(in paths: [PDF.Path], maximumSize: Double) -> [ShapePiece] {
        var out: [ShapePiece] = []
        for (index, path) in paths.enumerated() {
            let widen = path.paint == .fill ? 0 : path.lineWidth / 2
            for (subpathIndex, subpath) in path.subpaths.enumerated() {
                guard let raw = bounds(subpath) else { continue }
                let box = raw.insetBy(dx: -widen, dy: -widen)
                let size = max(box.width, box.height)
                guard size <= maximumSize, size >= minimumSize else { continue }
                out.append(
                    ShapePiece(
                        path: index, subpath: subpathIndex, box: box, filled: path.paint != .stroke)
                )
            }
        }
        return out
    }

    /// The grid's cell: twice the median piece size, from 2 to 16 page units.
    static func cell(for sizes: [Double]) -> Double {
        guard !sizes.isEmpty else { return 8 }
        let median = sizes.sorted()[sizes.count / 2]
        return min(16, max(2, 2 * median))
    }

    /// Pieces grouped into glyphs: a filled piece inside the box of a filled piece up to eight
    /// times its area (the hole of an "O", "e" or "8") joins it.
    static func glyphs(from pieces: [ShapePiece]) -> [ShapeGlyph] {
        let grid = BoxGrid(boxes: pieces.map(\.box), cell: cell(for: pieces.map(\.size)))
        var sets = DisjointSets(count: pieces.count)
        for (outer, piece) in pieces.enumerated() where piece.filled {
            let slack = 0.02 * piece.size
            let reach = piece.box.insetBy(dx: -slack, dy: -slack)
            let area = max(piece.box.width * piece.box.height, 1e-9)
            grid.forEach(near: piece.box) { inner in
                let other = pieces[inner]
                guard inner != outer, other.filled, other.size >= 0.2 * piece.size,
                    other.size < piece.size, reach.contains(other.box)
                else { return }
                let innerArea = max(other.box.width * other.box.height, 1e-9)
                if area <= 8 * innerArea { sets.union(outer, inner) }
            }
        }
        var members: [Int: [Int]] = [:]
        for index in pieces.indices { members[sets.find(index), default: []].append(index) }
        return members.keys.sorted().map { root in
            let indices = members[root] ?? []
            let box = indices.dropFirst().reduce(pieces[indices[0]].box) {
                $0.union(pieces[$1].box)
            }
            return ShapeGlyph(
                pieces: indices, box: box, filled: indices.contains { pieces[$0].filled })
        }
    }
}
