// TextCoverage.swift
// OCCTSwiftPDF
//
// Where the page already has text: a line of shapes under a text run, visible or not, is not text
// that needs recovering.

import CoreGraphics
import Foundation

/// The boxes of a page's text runs that have characters.
struct TextCoverage {
    private struct Entry {
        /// The run's box, counterclockwise.
        var quad: [CGPoint]
        var bounds: CGRect
        /// The run's size across its direction.
        var height: Double
        var text: String
    }

    private let entries: [Entry]

    init(_ texts: [PDF.TextRun]) {
        entries = texts.compactMap { run in
            guard let text = run.text, !text.isEmpty, run.quad.count == 4 else { return nil }
            let quad = Self.area(run.quad) < 0 ? Array(run.quad.reversed()) : run.quad
            let xs = quad.map(\.x)
            let ys = quad.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max()
            else { return nil }
            let bounds = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let height = hypot(quad[3].x - quad[0].x, quad[3].y - quad[0].y)
            return Entry(quad: quad, bounds: bounds, height: Double(height), text: text)
        }
    }

    /// How big a run may be, as a multiple of the shapes' height, to be their text.
    ///
    /// A font size runs about 1.0 to 1.6 times the ink above the baseline.
    static let heights = 0.4...3.0

    /// The points of a region's box sampled for coverage, along it and across it.
    static let samples = (along: 12, across: 5)

    /// The text of the runs of about the region's size that cover at least half of its box, in
    /// reading order, or `nil` where they do not.
    ///
    /// The boxes are compared as they lie, turned or not, so a long line of text across the page
    /// does not cover the shapes that happen to be inside its bounding rectangle. The fraction
    /// covered is that of a grid of points in the region that lie inside some run's box, so runs
    /// that overlap one another are not counted twice.
    func text(over region: ShapeTextRegion) -> String? {
        // A run of about the size of the shapes: a big watermark over small shapes is not their
        // text, and nor is a small label inside a big one.
        let lowest = Self.heights.lowerBound * region.height
        let highest = Self.heights.upperBound * region.height
        let near = entries.filter {
            $0.bounds.intersects(region.bounds) && $0.height >= lowest && $0.height <= highest
        }
        guard !near.isEmpty else { return nil }
        var inside = 0
        var over = Set<Int>()
        for i in 0..<Self.samples.along {
            for j in 0..<Self.samples.across {
                let point = region.point(
                    a: region.length * (Double(i) + 0.5) / Double(Self.samples.along),
                    b: region.height * (Double(j) + 0.5) / Double(Self.samples.across))
                var covered = false
                for (index, entry) in near.enumerated() where Self.contains(entry.quad, point) {
                    over.insert(index)
                    covered = true
                }
                if covered { inside += 1 }
            }
        }
        guard Double(inside) >= 0.5 * Double(Self.samples.along * Self.samples.across) else {
            return nil
        }
        let d = region.direction
        let ordered = over.map { near[$0] }.sorted {
            let a = $0.bounds.midX * d.x + $0.bounds.midY * d.y
            let b = $1.bounds.midX * d.x + $1.bounds.midY * d.y
            return a < b
        }
        return ordered.map(\.text).joined(separator: " ")
    }

    /// The signed area of a polygon: positive when its corners run counterclockwise.
    static func area(_ polygon: [CGPoint]) -> Double {
        var twice = 0.0
        for (index, point) in polygon.enumerated() {
            let next = polygon[(index + 1) % polygon.count]
            twice += Double(point.x * next.y - next.x * point.y)
        }
        return twice / 2
    }

    /// Whether `point` is inside a convex polygon whose corners run counterclockwise.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        for (index, start) in polygon.enumerated() {
            let end = polygon[(index + 1) % polygon.count]
            let along = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let to = CGPoint(x: point.x - start.x, y: point.y - start.y)
            if Double(along.x * to.y - along.y * to.x) < 0 { return false }
        }
        return true
    }
}
