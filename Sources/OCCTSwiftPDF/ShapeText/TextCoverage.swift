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
        var bounds: CGRect
        var text: String
    }

    private let entries: [Entry]

    init(_ texts: [PDF.TextRun]) {
        entries = texts.compactMap { run in
            guard let text = run.text, !text.isEmpty, run.quad.count == 4 else { return nil }
            let xs = run.quad.map(\.x)
            let ys = run.quad.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max()
            else { return nil }
            return Entry(bounds: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), text: text)
        }
    }

    /// The text of the runs that cover at least half of the region's box, in reading order, or
    /// `nil` where they do not.
    func text(over region: ShapeTextRegion) -> String? {
        let box = region.bounds
        let area = max(box.width * box.height, 1e-9)
        var covered = 0.0
        var over: [Entry] = []
        for entry in entries {
            let shared = box.intersection(entry.bounds)
            guard !shared.isNull, shared.width > 0, shared.height > 0 else { continue }
            covered += shared.width * shared.height
            over.append(entry)
        }
        guard covered >= 0.5 * area else { return nil }
        let d = region.direction
        let ordered = over.sorted {
            ($0.bounds.midX * d.x + $0.bounds.midY * d.y)
                < ($1.bounds.midX * d.x + $1.bounds.midY * d.y)
        }
        return ordered.map(\.text).joined(separator: " ")
    }
}
