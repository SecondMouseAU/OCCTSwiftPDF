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
