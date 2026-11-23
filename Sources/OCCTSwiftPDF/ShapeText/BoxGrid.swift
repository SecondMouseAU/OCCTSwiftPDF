// BoxGrid.swift
// OCCTSwiftPDF
//
// Boxes bucketed by position, for the boxes near a rectangle.

import CoreGraphics
import Foundation

/// Boxes bucketed by the cells they touch, for the boxes near a rectangle.
final class BoxGrid {
    private let cell: Double
    private var buckets: [Int64: [Int]] = [:]
    private var stamp: [UInt32]
    private var query: UInt32 = 0
    private let limit: Int
    /// The cells boxes were put in and the boxes looked at in queries, so far.
    private(set) var work = 0
    /// More work than the limit was done, and the grid is no longer complete or searched.
    var exceeded: Bool { work > limit }

    /// A grid of `boxes` in cells of side `cell`, which stops (see ``exceeded``) after `limit`
    /// units of work: many large boxes over small cells, or many boxes over one another, make
    /// the work grow faster than the boxes do.
    init(boxes: [CGRect], cell: Double, limit: Int = Int.max) {
        self.cell = cell
        self.limit = limit
        stamp = Array(repeating: 0, count: boxes.count)
        for (index, box) in boxes.enumerated() {
            let columns = range(box.minX, box.maxX)
            let rows = range(box.minY, box.maxY)
            work += columns.count * rows.count
            if exceeded { return }
            for x in columns {
                for y in rows { buckets[Self.key(x, y), default: []].append(index) }
            }
        }
    }

    private static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 ^ (y & 0xFFFF_FFFF) }

    /// The cells from `low` to `high`; a coordinate that is not finite, or is a billion cells out,
    /// is taken to be on the grid's edge, so a hostile file cannot trap the conversion.
    private func range(_ low: Double, _ high: Double) -> ClosedRange<Int64> {
        func index(_ value: Double) -> Int64 {
            let cells = value / cell
            return cells.isFinite ? Int64(max(-1e9, min(1e9, cells.rounded(.down)))) : 0
        }
        return index(low)...index(high)
    }

    /// Calls `body` once for each box that touches a cell `rect` touches, which can be a box
    /// that does not itself reach `rect`.
    func forEach(near rect: CGRect, _ body: (Int) -> Void) {
        guard !exceeded else { return }
        query &+= 1
        for x in range(rect.minX, rect.maxX) {
            for y in range(rect.minY, rect.maxY) {
                let bucket = buckets[Self.key(x, y)] ?? []
                work += bucket.count + 1
                if exceeded { return }
                for index in bucket where stamp[index] != query {
                    stamp[index] = query
                    body(index)
                }
            }
        }
    }
}
